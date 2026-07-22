import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "edge" / "render-haproxy-config.sh"


class HAProxyEdgeTests(unittest.TestCase):
    def render(self, **environment):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "haproxy.cfg"
            subprocess.run(
                [str(RENDER)],
                cwd=ROOT,
                env={**os.environ, "HAPROXY_CONFIG_PATH": str(output), **environment},
                check=True,
                text=True,
                capture_output=True,
            )
            return output.read_text(encoding="utf-8")

    def test_full_routes_use_native_health_checks(self):
        config = self.render()
        self.assertIn("https://_dsr.k8sedge.zerops:6443", config)
        self.assertIn("option httpchk GET /readyz HTTP/1.1", config)
        self.assertIn("check-ssl verify none", config)
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
                            **environment,
                        },
                        text=True,
                        capture_output=True,
                    )
                    self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
