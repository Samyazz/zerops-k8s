import json
import os
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]


def yaml_documents(path: Path):
    with path.open(encoding="utf-8") as stream:
        return [document for document in yaml.safe_load_all(stream) if document]


class ClusterProfileManifestsTest(unittest.TestCase):
    def setUp(self):
        self.profiles = {
            name: json.loads((ROOT / "profiles" / f"{name}.json").read_text())
            for name in ("full", "production", "staging")
        }

    def test_feature_gate_render_is_exact(self):
        expected = {
            "full": {
                "gateway": "istio",
                "gateway-replicas": "2",
                "storage": "longhorn",
                "storage-replicas": "3",
                "platform-observability": "false",
                "dedicated-observability": "true",
                "dashboard": "true",
                "demo": "full",
            },
            "production": {
                "gateway": "traefik",
                "gateway-replicas": "2",
                "storage": "longhorn",
                "storage-replicas": "2",
                "platform-observability": "true",
                "dedicated-observability": "false",
                "dashboard": "false",
                "demo": "production",
            },
            "staging": {
                "gateway": "traefik",
                "gateway-replicas": "1",
                "storage": "none",
                "storage-replicas": "0",
                "platform-observability": "true",
                "dedicated-observability": "false",
                "dashboard": "false",
                "demo": "staging",
            },
        }
        for profile, subset in expected.items():
            result = subprocess.run(
                [str(ROOT / "scripts" / "cluster-bootstrap.sh"), "--print-feature-gates"],
                cwd=ROOT,
                env={**os.environ, "K8S_PROFILE": profile},
                check=True,
                text=True,
                capture_output=True,
            )
            gates = dict(line.split("=", 1) for line in result.stdout.splitlines())
            self.assertEqual(gates["profile"], profile)
            self.assertEqual(gates["cni"], "calico")
            self.assertEqual(gates["metrics-server-replicas"], str(self.profiles[profile]["addons"]["metricsServerReplicas"]))
            for key, value in subset.items():
                self.assertEqual(gates[key], value)

    def test_production_demo_has_ha_and_resource_controls(self):
        documents = yaml_documents(ROOT / "kubernetes/profiles/production/demo.yaml")
        by_kind = {document["kind"]: document for document in documents}
        deployment = by_kind["Deployment"]
        self.assertEqual(deployment["spec"]["replicas"], 2)
        self.assertEqual(
            deployment["spec"]["template"]["spec"]["topologySpreadConstraints"][0]["whenUnsatisfiable"],
            "DoNotSchedule",
        )
        self.assertEqual(
            deployment["spec"]["template"]["spec"]["topologySpreadConstraints"][0]["nodeTaintsPolicy"],
            "Honor",
        )
        resources = deployment["spec"]["template"]["spec"]["containers"][0]["resources"]
        self.assertEqual(resources["requests"], {"cpu": "25m", "memory": "32Mi"})
        self.assertEqual(resources["limits"], {"cpu": "250m", "memory": "128Mi"})
        self.assertIn("PodDisruptionBudget", by_kind)
        self.assertIn("HorizontalPodAutoscaler", by_kind)
        self.assertEqual(by_kind["HorizontalPodAutoscaler"]["spec"]["minReplicas"], 2)
        self.assertEqual(by_kind["HorizontalPodAutoscaler"]["spec"]["maxReplicas"], 6)
        self.assertEqual(
            by_kind["ResourceQuota"]["spec"]["hard"],
            {
                "requests.cpu": "2", "requests.memory": "2Gi",
                "limits.cpu": "4", "limits.memory": "4Gi", "pods": "30",
            },
        )

    def test_staging_demo_is_intentionally_minimal(self):
        documents = yaml_documents(ROOT / "kubernetes/profiles/staging/demo.yaml")
        by_kind = {document["kind"]: document for document in documents}
        self.assertEqual(by_kind["Deployment"]["spec"]["replicas"], 1)
        self.assertNotIn("PodDisruptionBudget", by_kind)
        self.assertNotIn("HorizontalPodAutoscaler", by_kind)
        self.assertEqual(
            by_kind["ResourceQuota"]["spec"]["hard"],
            {
                "requests.cpu": "1", "requests.memory": "1Gi",
                "limits.cpu": "2", "limits.memory": "2Gi", "pods": "15",
            },
        )

    def test_traefik_is_digest_pinned_and_bounded(self):
        versions = dict(
            line.split("=", 1)
            for line in (ROOT / "versions.env").read_text().splitlines()
            if line and not line.startswith("#")
        )
        for profile, replicas in (("production", 2), ("staging", 1)):
            values = yaml.safe_load((ROOT / f"kubernetes/profiles/{profile}/traefik-values.yaml").read_text())
            self.assertEqual(values["deployment"]["replicas"], replicas)
            self.assertEqual(values["image"]["tag"], f"v{versions['TRAEFIK_VERSION']}")
            self.assertEqual(values["image"]["digest"], versions["TRAEFIK_IMAGE_DIGEST"])
            self.assertEqual(values["ports"]["web"]["nodePort"], 32080)
            self.assertEqual(values["resources"]["requests"], {"cpu": "100m", "memory": "128Mi"})
            self.assertEqual(values["resources"]["limits"], {"cpu": "1", "memory": "512Mi"})
            self.assertTrue(values["providers"]["kubernetesGateway"]["enabled"])
            self.assertFalse(values["providers"]["kubernetesIngress"]["enabled"])
            if profile == "production":
                spread = values["topologySpreadConstraints"][0]
                self.assertEqual(spread["topologyKey"], "kubernetes.io/hostname")
                self.assertEqual(spread["whenUnsatisfiable"], "DoNotSchedule")

    def test_metrics_server_and_longhorn_match_profile_contracts(self):
        for profile, replicas in (("production", 2), ("staging", 1)):
            values = yaml.safe_load((ROOT / f"kubernetes/profiles/{profile}/metrics-server-values.yaml").read_text())
            self.assertEqual(values["replicas"], replicas)
            self.assertEqual(values["resources"]["requests"], {"cpu": "50m", "memory": "100Mi"})
            self.assertEqual(values["resources"]["limits"], {"cpu": "250m", "memory": "256Mi"})
            if profile == "production":
                spread = values["topologySpreadConstraints"][0]
                self.assertEqual(spread["topologyKey"], "kubernetes.io/hostname")
                self.assertEqual(spread["whenUnsatisfiable"], "DoNotSchedule")
        longhorn = yaml.safe_load((ROOT / "kubernetes/profiles/production/longhorn-values.yaml").read_text())
        self.assertEqual(longhorn["persistence"]["defaultClassReplicaCount"], 2)
        self.assertEqual(longhorn["longhornUI"]["replicas"], 0)
        self.assertEqual(longhorn["longhornManager"]["resources"]["requests"]["cpu"], "100m")
        csi_resources = json.loads(longhorn["defaultSettings"]["systemManagedCSIComponentsResourceLimits"])
        self.assertEqual(
            set(csi_resources),
            {
                "csi-attacher", "csi-provisioner", "csi-resizer", "csi-snapshotter",
                "longhorn-csi-plugin", "node-driver-registrar", "longhorn-liveness-probe",
            },
        )
        for resources in csi_resources.values():
            self.assertTrue(resources["requests"]["cpu"])
            self.assertTrue(resources["requests"]["memory"])
            self.assertTrue(resources["limits"]["cpu"])
            self.assertTrue(resources["limits"]["memory"])

    def test_longhorn_prerequisite_probe_reasserts_kernel_modules(self):
        daemonset = yaml.safe_load((ROOT / "kubernetes/longhorn-node-prerequisites.yaml").read_text())
        container = daemonset["spec"]["template"]["spec"]["containers"][0]
        readiness_script = container["readinessProbe"]["exec"]["command"][2]
        self.assertIn('modprobe "$module"', readiness_script)
        for module in ("iscsi_tcp", "nfs", "dm_crypt"):
            self.assertIn(module, readiness_script)

    def test_gateway_and_security_are_mesh_independent(self):
        gateway = yaml_documents(ROOT / "kubernetes/profiles/common/gateway.yaml")
        self.assertEqual({document["kind"] for document in gateway}, {"Gateway", "HTTPRoute"})
        self.assertEqual(gateway[0]["spec"]["gatewayClassName"], "traefik")
        security = yaml_documents(ROOT / "kubernetes/profiles/common/security.yaml")
        rendered = json.dumps(security)
        self.assertNotIn("istio", rendered.lower())
        self.assertNotIn("cert-manager", rendered.lower())
        self.assertIn("traefik-system", rendered)

    def test_evidence_redactor_covers_secrets_and_personal_data(self):
        sensitive = (
            "Authorization: Bearer token-value Cookie: session=cookie-value "
            "Set-Cookie: sid=set-cookie-value token=plain-token "
            "person@example.invalid 203.0.113.47\n"
        )
        result = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh")],
            input=sensitive,
            text=True,
            capture_output=True,
            check=True,
        )
        for leaked in (
            "token-value", "cookie-value", "set-cookie-value", "plain-token",
            "person@example.invalid", "203.0.113.47",
        ):
            self.assertNotIn(leaked, result.stdout)
        self.assertGreaterEqual(result.stdout.count("[REDACTED]"), 4)
        self.assertIn("[REDACTED_EMAIL]", result.stdout)
        self.assertIn("[REDACTED_IP]", result.stdout)


if __name__ == "__main__":
    unittest.main()
