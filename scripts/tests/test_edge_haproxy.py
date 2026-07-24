import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "edge" / "render-haproxy-config.sh"
VRRP_RENDER = ROOT / "edge" / "render-keepalived-config.sh"
SUPERVISOR = ROOT / "edge" / "run-vrrp-edge.sh"


class HAProxyEdgeTests(unittest.TestCase):
    def render(self, **environment):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "haproxy.cfg"
            subprocess.run(
                [str(RENDER)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HAPROXY_CONFIG_PATH": str(output),
                    "K8S_VRRP_VIP": "10.0.71.222",
                    **environment,
                },
                check=True,
                text=True,
                capture_output=True,
            )
            return output.read_text(encoding="utf-8")

    def test_full_routes_use_native_health_checks(self):
        config = self.render()
        self.assertIn("10.0.71.222/32", config)
        self.assertIn("option httpchk GET /readyz HTTP/1.1", config)
        self.assertIn("check-ssl verify none", config)
        self.assertIn("resolvers zerops_dns", config)
        self.assertIn("resolve-prefer ipv4 init-addr libc,none", config)
        self.assertIn("k8scp1.zerops:6443", config)
        self.assertIn("k8sworker1.zerops:32080", config)
        self.assertEqual(config.count("server cp"), 3)
        self.assertEqual(config.count("server worker"), 3)
        self.assertEqual(config.count("server headlamp"), 3)
        self.assertIn("monitor-uri /healthz", config)

    def test_compact_route_set_disables_headlamp(self):
        config = self.render(
            K8S_EDGE_API_BACKENDS="k8scp1:6443",
            K8S_EDGE_INGRESS_BACKENDS="k8sworker1:32080",
            K8S_EDGE_HEADLAMP_ENABLED="false",
        )
        self.assertEqual(config.count("server cp"), 1)
        self.assertEqual(config.count("server worker"), 1)
        self.assertNotIn("frontend headlamp", config)

    def test_config_injection_and_disabled_api_are_rejected(self):
        for environment in (
            {"K8S_EDGE_API_BACKENDS": "k8scp1:6443\nfrontend injected"},
            {"K8S_EDGE_DNS_SERVER": "10.0.0.1\nfrontend injected"},
            {"K8S_EDGE_API_ENABLED": "false"},
        ):
            with self.subTest(environment=environment):
                with tempfile.TemporaryDirectory() as temporary:
                    result = subprocess.run(
                        [str(RENDER)],
                        cwd=ROOT,
                        env={
                            **os.environ,
                            "HAPROXY_CONFIG_PATH": str(Path(temporary) / "haproxy.cfg"),
                            "K8S_VRRP_VIP": "10.0.71.222",
                            **environment,
                        },
                        text=True,
                        capture_output=True,
                    )
                    self.assertNotEqual(result.returncode, 0)

    def test_supervisor_records_the_foreground_haproxy_pid_it_owns(self):
        supervisor = SUPERVISOR.read_text(encoding="utf-8")
        launch = supervisor.index('haproxy -db -f "$haproxy_config" &')
        capture = supervisor.index("haproxy_pid=$!", launch)
        record = supervisor.index(
            'printf \'%s\\n\' "$haproxy_pid" >"$haproxy_pid_file"', capture
        )
        check = supervisor.index('"$script_dir/check-haproxy.sh"', record)

        self.assertLess(launch, capture)
        self.assertLess(capture, record)
        self.assertLess(record, check)
        self.assertNotIn('-p "$haproxy_pid_file"', supervisor)


class KeepalivedEdgeTests(unittest.TestCase):
    def render(self, **environment):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "keepalived.conf"
            subprocess.run(
                [str(VRRP_RENDER)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "KEEPALIVED_CONFIG_PATH": str(output),
                    "K8S_VRRP_STATE_PATH": str(Path(temporary) / "vrrp-vip"),
                    "K8S_VRRP_INTERFACE": "eth0",
                    "K8S_VRRP_LOCAL_CIDR": "10.0.68.29/22",
                    **environment,
                },
                check=True,
                text=True,
                capture_output=True,
            )
            return output.read_text(encoding="utf-8")

    def test_multicast_vrrp_uses_dynamic_local_identity(self):
        config = self.render()
        self.assertIn("router_id K8S_EDGE_10_0_68_29", config)
        self.assertIn("interface eth0", config)
        self.assertIn("virtual_router_id 222", config)
        self.assertIn("priority 100", config)
        self.assertIn("10.0.71.222/32 dev eth0", config)
        self.assertIn("state BACKUP", config)
        self.assertIn("nopreempt", config)
        self.assertIn("check_haproxy", config)
        self.assertNotIn("unicast_peer", config)
        self.assertNotIn("10.0.68.30", config)

    def test_current_container_address_is_rediscovered(self):
        config = self.render(K8S_VRRP_LOCAL_CIDR="10.0.72.47/22")
        self.assertIn("router_id K8S_EDGE_10_0_72_47", config)
        self.assertIn("10.0.75.222/32 dev eth0", config)
        self.assertNotIn("10.0.68.29", config)

    def test_vip_must_be_a_usable_address_in_the_container_subnet(self):
        for vip in ("10.1.0.222", "10.0.68.29", "not-an-ip"):
            with self.subTest(vip=vip), tempfile.TemporaryDirectory() as temporary:
                result = subprocess.run(
                    [str(VRRP_RENDER)],
                    cwd=ROOT,
                    env={
                        **os.environ,
                        "KEEPALIVED_CONFIG_PATH": str(Path(temporary) / "keepalived.conf"),
                        "K8S_VRRP_STATE_PATH": str(Path(temporary) / "vrrp-vip"),
                        "K8S_VRRP_INTERFACE": "eth0",
                        "K8S_VRRP_LOCAL_CIDR": "10.0.68.29/22",
                        "K8S_VRRP_VIP": vip,
                    },
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
