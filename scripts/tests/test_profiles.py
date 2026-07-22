import json
import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROFILE_DIR = ROOT / "profiles"

EXPECTED = {
    "full": {
        "control_planes": ["k8scp1", "k8scp2", "k8scp3"],
        "workers": ["k8sworker1", "k8sworker2", "k8sworker3"],
        "endpoint": "_dsr.k8sedge.zerops:6443",
        "services": [
            "k8scp1", "k8scp2", "k8scp3", "k8sworker1", "k8sworker2",
            "k8sworker3", "k8sedge", "k8sbackups", "grafanadb",
            "prometheusbackups", "grafana", "prometheus", "elkstorage",
            "kibana", "logstash", "apmserver",
        ],
        "gateway": "istio",
        "storage": "longhorn",
        "storage_replicas": 3,
        "acceptance": "full-conformance",
    },
    "production": {
        "control_planes": ["k8scp1"],
        "workers": ["k8sworker1", "k8sworker2"],
        "endpoint": "_dsr.k8sedge.zerops:6443",
        "services": ["k8scp1", "k8sworker1", "k8sworker2", "k8sedge", "k8sbackups"],
        "gateway": "traefik",
        "storage": "longhorn",
        "storage_replicas": 2,
        "acceptance": "sonobuoy-quick",
    },
    "staging": {
        "control_planes": ["k8scp1"],
        "workers": ["k8sworker1"],
        "endpoint": "_dsr.k8sedge.zerops:6443",
        "services": ["k8scp1", "k8sworker1", "k8sedge"],
        "gateway": "traefik",
        "storage": "none",
        "storage_replicas": 0,
        "acceptance": "smoke",
    },
}


def load_profile(name):
    with (PROFILE_DIR / f"{name}.json").open(encoding="utf-8") as handle:
        return json.load(handle)


def import_path(profile):
    return ROOT / ("import.yaml" if profile == "full" else f"import.{profile}.yaml")


def import_services(profile):
    text = import_path(profile).read_text(encoding="utf-8")
    return re.findall(r"^  - hostname: ([a-z0-9]+)$", text, re.MULTILINE)


def blocks(text, key):
    matches = list(re.finditer(rf"^  - {re.escape(key)}: ([a-z0-9-]+)$", text, re.MULTILINE))
    result = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        result[match.group(1)] = text[match.start():end]
    return result


class ProfileContractTests(unittest.TestCase):
    def test_external_recipe_builds_are_commit_pinned(self):
        references = []
        for path in (
            ROOT / "import.yaml",
            ROOT / "infrastructure" / "observability.import.yaml",
        ):
            references.extend(
                line.split("buildFromGit:", 1)[1].strip()
                for line in path.read_text(encoding="utf-8").splitlines()
                if "buildFromGit:" in line
            )
        self.assertTrue(references)
        for reference in references:
            with self.subTest(reference=reference):
                self.assertRegex(reference, r"^https://github\.com/[^@]+@[0-9a-f]{40}$")

    def test_descriptor_schema_and_enums(self):
        top_level = {
            "schemaVersion", "name", "default", "project", "topology",
            "nodeImage", "addons", "capabilities", "acceptance", "services",
        }
        topology_keys = {
            "controlPlanes", "workers", "optionalWorkers", "controlPlaneEndpoint",
            "edge", "backup",
        }
        addon_keys = {
            "cni", "gateway", "gatewayReplicas", "serviceMesh", "storage",
            "storageReplicas", "metricsServerReplicas", "certManager", "dashboard",
            "observability", "demo", "security",
        }
        capability_keys = {
            "backup", "restore", "horizontalResize", "storageHealth",
            "controlPlaneFailover", "workerDisruption",
        }
        for name in EXPECTED:
            with self.subTest(profile=name):
                profile = load_profile(name)
                self.assertEqual(set(profile), top_level)
                self.assertEqual(set(profile["topology"]), topology_keys)
                self.assertEqual(set(profile["addons"]), addon_keys)
                self.assertEqual(set(profile["capabilities"]), capability_keys)
                self.assertIn(profile["project"]["corePackage"], {"LIGHT", "SERIOUS"})
                self.assertIn(profile["nodeImage"]["mode"], {"local", "object-storage"})
                self.assertIn(profile["addons"]["gateway"], {"istio", "traefik"})
                self.assertIn(profile["addons"]["storage"], {"none", "longhorn"})
                self.assertIn(profile["addons"]["observability"], {"platform", "advanced"})
                self.assertIn(profile["acceptance"]["level"], {"smoke", "sonobuoy-quick", "full-conformance"})
                self.assertTrue(all(isinstance(value, bool) for value in profile["capabilities"].values()))
                self.assertTrue(profile["topology"]["controlPlanes"])
                self.assertTrue(profile["topology"]["workers"])

    def test_descriptors_resolve_exact_contracts(self):
        for name, expected in EXPECTED.items():
            with self.subTest(profile=name):
                profile = load_profile(name)
                self.assertEqual(profile["schemaVersion"], 1)
                self.assertEqual(profile["name"], name)
                self.assertEqual(profile["topology"]["controlPlanes"], expected["control_planes"])
                self.assertEqual(profile["topology"]["workers"], expected["workers"])
                self.assertEqual(profile["topology"]["controlPlaneEndpoint"], expected["endpoint"])
                self.assertEqual([service["hostname"] for service in profile["services"]], expected["services"])
                self.assertEqual(profile["addons"]["gateway"], expected["gateway"])
                self.assertEqual(profile["addons"]["storage"], expected["storage"])
                self.assertEqual(profile["addons"]["storageReplicas"], expected["storage_replicas"])
                self.assertEqual(profile["acceptance"]["level"], expected["acceptance"])

    def test_only_full_is_default(self):
        self.assertEqual(
            [name for name in EXPECTED if load_profile(name)["default"]],
            ["full"],
        )

    def test_service_names_are_unique_and_cover_nodes(self):
        for name in EXPECTED:
            with self.subTest(profile=name):
                profile = load_profile(name)
                services = [service["hostname"] for service in profile["services"]]
                self.assertEqual(len(services), len(set(services)))
                nodes = profile["topology"]["controlPlanes"] + profile["topology"]["workers"]
                self.assertTrue(set(nodes).issubset(services))

    def test_import_inventory_and_profile_tag_are_exact(self):
        for name, expected in EXPECTED.items():
            with self.subTest(profile=name):
                text = import_path(name).read_text(encoding="utf-8")
                self.assertEqual(import_services(name), expected["services"])
                self.assertIn(f"K8S_PROFILE: {name}", text)
                self.assertIn(f"- zerops-k8s-profile-{name}", text)
                self.assertIn(
                    f"corePackage: {load_profile(name)['project']['corePackage']}",
                    text,
                )

    def test_profile_endpoint_backup_and_edge_contracts(self):
        for name in EXPECTED:
            with self.subTest(profile=name):
                profile = load_profile(name)
                text = import_path(name).read_text(encoding="utf-8")
                self.assertIn(
                    f"K8S_CONTROL_PLANE_ENDPOINT: {profile['topology']['controlPlaneEndpoint']}",
                    text,
                )
                backup = profile["topology"]["backup"]
                edge = profile["topology"]["edge"]
                services = import_services(name)
                if backup["enabled"]:
                    self.assertIn(backup["hostname"], services)
                    self.assertIn(f"objectStorageSize: {backup['quotaGb']}", text)
                else:
                    self.assertNotIn("objectStorageSize:", text)
                if edge["enabled"]:
                    self.assertIn(edge["hostname"], services)
                else:
                    self.assertNotIn("k8sedge", services)

    def test_new_profile_resource_contracts(self):
        cases = {
            "production": {
                "k8scp1": ("DEDICATED", "4", "8", "20"),
                "k8sworker1": ("DEDICATED", "4", "8", "50"),
                "k8sworker2": ("DEDICATED", "4", "8", "50"),
            },
            "staging": {
                "k8scp1": ("SHARED", "2", "4", "20"),
                "k8sworker1": ("SHARED", "2", "4", "20"),
            },
        }
        for profile_name, expected_services in cases.items():
            text = import_path(profile_name).read_text(encoding="utf-8")
            service_blocks = blocks(text, "hostname")
            for service, (mode, cpu, ram, disk) in expected_services.items():
                with self.subTest(profile=profile_name, service=service):
                    block = service_blocks[service]
                    alias = re.search(r"verticalAutoscaling: \*([A-Za-z0-9]+)", block)
                    if alias:
                        anchor = re.search(
                            rf"verticalAutoscaling: &{re.escape(alias.group(1))}\n"
                            r"(?P<body>(?:      .+\n)+)",
                            text,
                        )
                        self.assertIsNotNone(anchor)
                        block += anchor.group("body")
                    self.assertIn(f"cpuMode: {mode}", block)
                    self.assertIn(f"minCpu: {cpu}", block)
                    self.assertIn(f"maxCpu: {cpu}", block)
                    self.assertIn(f"minRam: {ram}", block)
                    self.assertIn(f"maxRam: {ram}", block)
                    self.assertIn(f"minDisk: {disk}", block)
                    self.assertIn(f"maxDisk: {disk}", block)

    def test_every_import_mirrors_descriptor_service_resources(self):
        for profile_name in EXPECTED:
            profile = load_profile(profile_name)
            text = import_path(profile_name).read_text(encoding="utf-8")
            service_blocks = blocks(text, "hostname")
            for service in profile["services"]:
                name = service["hostname"]
                with self.subTest(profile=profile_name, service=name):
                    block = service_blocks[name]
                    self.assertIn(f"type: {service['type']}", block)
                    for field in ("minContainers", "maxContainers"):
                        if field in service:
                            self.assertRegex(block, rf"(?m)^    {field}: {service[field]}$")
                    resources = service.get("resources")
                    if resources:
                        self.assertIn(f"cpuMode: {resources['cpuMode']}", block)
                        if "cpu" in resources:
                            self.assertIn(f"minCpu: {resources['cpu']}", block)
                            self.assertIn(f"maxCpu: {resources['cpu']}", block)
                            self.assertIn(f"startCpuCoreCount: {resources['cpu']}", block)
                            self.assertIn(f"minRam: {resources['ramGb']}", block)
                            self.assertIn(f"maxRam: {resources['ramGb']}", block)
                            self.assertIn(f"minDisk: {resources['diskGb']}", block)
                            self.assertIn(f"maxDisk: {resources['diskGb']}", block)
                        else:
                            self.assertIn(f"minCpu: {resources['minCpu']}", block)
                            self.assertIn(f"maxCpu: {resources['maxCpu']}", block)
                            self.assertIn(f"minRam: {resources['minRamGb']}", block)
                            self.assertIn(f"maxRam: {resources['maxRamGb']}", block)
                            self.assertIn(f"minDisk: {resources['minDiskGb']}", block)
                            self.assertIn(f"maxDisk: {resources['maxDiskGb']}", block)
                    if "objectStorageSizeGb" in service:
                        self.assertIn(f"objectStorageSize: {service['objectStorageSizeGb']}", block)

    def test_production_edge_and_backup_are_redundant_and_private(self):
        profile = load_profile("production")
        text = import_path("production").read_text(encoding="utf-8")
        service_blocks = blocks(text, "hostname")
        edge = service_blocks[profile["topology"]["edge"]["hostname"]]
        backup = service_blocks[profile["topology"]["backup"]["hostname"]]
        self.assertEqual(profile["topology"]["edge"]["containers"], 2)
        self.assertIn("minContainers: 2", edge)
        self.assertIn("maxContainers: 2", edge)
        self.assertIn("enableSubdomainAccess: true", edge)
        self.assertIn("objectStoragePolicy: private", backup)

    def test_new_imports_defer_cluster_secrets_to_the_workflow(self):
        library = (ROOT / "scripts/lib.sh").read_text(encoding="utf-8")
        deploy = (ROOT / "scripts/deploy.sh").read_text(encoding="utf-8")
        for name in ("production", "staging"):
            text = import_path(name).read_text(encoding="utf-8")
            with self.subTest(profile=name):
                self.assertNotIn("K8S_AGENT_TOKEN:", text)
                self.assertNotIn("K8S_BOOTSTRAP_TOKEN:", text)
                self.assertNotIn("K8S_CERTIFICATE_KEY:", text)
                self.assertNotIn("K8S_ENCRYPTION_KEY:", text)
                self.assertNotRegex(text, r"github_pat_|gh[pousr]_[A-Za-z0-9]{20,}")
        for key in (
            "K8S_AGENT_TOKEN",
            "K8S_BOOTSTRAP_TOKEN",
            "K8S_CERTIFICATE_KEY",
            "K8S_ENCRYPTION_KEY",
        ):
            self.assertIn(f'store_project_secret "$key"', library)
        self.assertIn("rotate_project_cluster_secrets", deploy)
        self.assertIn("ensure_project_cluster_secrets", deploy)
        self.assertIn("api_request_file POST /project/search", library)
        self.assertIn('{name:"clientId",operator:"eq",value:$client_id}', library)
        self.assertIn('path="/project-env/${env_id}"', library)
        self.assertIn("method=PUT", library)
        self.assertIn("sed -i '/^K8S_PROFILE=/d'", library)
        self.assertIn('store_project_env "$1" "$2" true', library)
        self.assertIn('store_project_env "$1" "$2" false', library)

    def test_import_setups_exist_and_only_reference_present_services(self):
        zerops_text = (ROOT / "zerops.yaml").read_text(encoding="utf-8")
        setup_blocks = blocks(zerops_text, "setup")
        for name in ("production", "staging"):
            profile = load_profile(name)
            present = {service["hostname"] for service in profile["services"]}
            for service in profile["services"]:
                setup = service.get("setup")
                if not setup:
                    continue
                with self.subTest(profile=name, setup=setup):
                    self.assertIn(setup, setup_blocks)
                    references = set(re.findall(r"\$\{([a-z0-9]+)_[A-Za-z0-9]+\}", setup_blocks[setup]))
                    self.assertTrue(references.issubset(present), references - present)

        production = load_profile("production")
        for worker in production["topology"]["optionalWorkers"]:
            setup = f"worker{worker.removeprefix('k8sworker')}-production"
            with self.subTest(profile="production", optional_setup=setup):
                self.assertIn(setup, setup_blocks)
                self.assertIn(f"K8S_NODE_NAME: {worker}", setup_blocks[setup])

    def test_staging_keeps_only_the_required_edge_and_no_s3_reference(self):
        profile = load_profile("staging")
        self.assertTrue(profile["topology"]["edge"]["enabled"])
        self.assertEqual(profile["topology"]["edge"]["containers"], 2)
        self.assertFalse(profile["topology"]["backup"]["enabled"])
        self.assertEqual(profile["nodeImage"]["mode"], "local")
        import_text = import_path("staging").read_text(encoding="utf-8")
        setup_text = (ROOT / "zerops.yaml").read_text(encoding="utf-8")
        setup_blocks = blocks(setup_text, "setup")
        selected = "\n".join(
            setup_blocks[name]
            for name in ("controlplane1-staging", "worker1-staging", "edge-staging")
        )
        for forbidden in ("k8sbackups_", "s3-fetch", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
            self.assertNotIn(forbidden, import_text)
            self.assertNotIn(forbidden, selected)
        self.assertIn("docker build --pull", selected)
        self.assertIn("docker image inspect --format '{{.Id}}'", selected)
        self.assertIn('test "$image_version" = "$K8S_VERSION"', selected)

    def test_every_profile_uses_redundant_dsr_haproxy_edge(self):
        setup_text = (ROOT / "zerops.yaml").read_text(encoding="utf-8")
        setup_blocks = blocks(setup_text, "setup")
        self.assertIn("sudo apk add --no-cache 'haproxy~3.2'", setup_text)
        self.assertIn("apt-get install -y --no-install-recommends haproxy", setup_text)
        for name in EXPECTED:
            with self.subTest(profile=name):
                profile = load_profile(name)
                edge = profile["topology"]["edge"]
                self.assertTrue(edge["enabled"])
                self.assertEqual(edge["hostname"], "k8sedge")
                self.assertEqual(edge["containers"], 2)
                self.assertEqual(profile["topology"]["controlPlaneEndpoint"], "_dsr.k8sedge.zerops:6443")
                service = next(item for item in profile["services"] if item["hostname"] == "k8sedge")
                block = setup_blocks[service["setup"]]
                self.assertRegex(block, r"- (?:&installHAProxy \||\*installHAProxy)")
                self.assertIn("K8S_DSR_HOSTNAME: _dsr.k8sedge.zerops", block)
                self.assertIn("start: ./edge/run-haproxy.sh", block)
                self.assertNotIn("K8S_MODE: edge", block)
                self.assertNotIn("go build", block)

    def test_lib_defaults_to_full_and_preserves_node_order(self):
        command = (
            'source scripts/lib.sh; '
            'printf "%s|%s|%s|%s\\n" "$K8S_PROFILE" "${CONTROL_PLANES[*]}" '
            '"${WORKERS[*]}" "$CONTROL_PLANE_ENDPOINT"'
        )
        result = subprocess.run(
            ["bash", "-c", command], cwd=ROOT, text=True, capture_output=True, check=True,
            env={key: value for key, value in os.environ.items() if key != "K8S_PROFILE"},
        )
        self.assertEqual(
            result.stdout.strip(),
            "full|k8scp1 k8scp2 k8scp3|k8sworker1 k8sworker2 k8sworker3|_dsr.k8sedge.zerops:6443",
        )

    def test_lib_resolves_all_profile_node_orders(self):
        for name, expected in EXPECTED.items():
            with self.subTest(profile=name):
                command = 'source scripts/lib.sh; printf "%s|%s" "${CONTROL_PLANES[*]}" "${WORKERS[*]}"'
                result = subprocess.run(
                    ["bash", "-c", command], cwd=ROOT, text=True, capture_output=True, check=True,
                    env={**os.environ, "K8S_PROFILE": name},
                )
                self.assertEqual(
                    result.stdout,
                    f"{' '.join(expected['control_planes'])}|{' '.join(expected['workers'])}",
                )

    def test_lib_rejects_unknown_profile(self):
        result = subprocess.run(
            ["bash", "-c", "source scripts/lib.sh"], cwd=ROOT, text=True, capture_output=True,
            env={**os.environ, "K8S_PROFILE": "not-a-profile"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown K8S_PROFILE", result.stderr)

    def test_capability_helper(self):
        result = subprocess.run(
            ["bash", "-c", "source scripts/lib.sh; profile_capability backup"],
            cwd=ROOT, env={**os.environ, "K8S_PROFILE": "staging"},
        )
        self.assertNotEqual(result.returncode, 0)
        result = subprocess.run(
            ["bash", "-c", "source scripts/lib.sh; profile_capability backup"],
            cwd=ROOT, env={**os.environ, "K8S_PROFILE": "production"},
        )
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
