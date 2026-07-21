import json
import os
from pathlib import Path
import re
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
PROFILES = ["full", "production", "staging"]
PROFILE_WORKFLOWS = [
    "backup.yml",
    "deploy.yml",
    "destroy.yml",
    "maintenance.yml",
    "resize.yml",
    "restore-drill.yml",
    "reusable-deploy.yml",
    "upgrade.yml",
]


def workflow_text(name):
    return (WORKFLOW_DIR / name).read_text(encoding="utf-8")


def workflow(name):
    with (WORKFLOW_DIR / name).open(encoding="utf-8") as handle:
        return yaml.load(handle, Loader=yaml.BaseLoader)


class WorkflowProfileContractTests(unittest.TestCase):
    def test_every_operation_has_a_full_default_profile_input(self):
        for name in PROFILE_WORKFLOWS:
            with self.subTest(workflow=name):
                data = workflow(name)
                trigger = "workflow_call" if name == "reusable-deploy.yml" else "workflow_dispatch"
                profile = data["on"][trigger]["inputs"]["profile"]
                self.assertEqual(profile["default"], "full")
                if trigger == "workflow_dispatch":
                    self.assertEqual(profile["type"], "choice")
                    self.assertEqual(profile["options"], PROFILES)
                else:
                    self.assertEqual(profile["type"], "string")

    def test_profile_is_passed_to_every_mutating_job(self):
        for name in PROFILE_WORKFLOWS:
            text = workflow_text(name)
            with self.subTest(workflow=name):
                if name == "deploy.yml":
                    self.assertIn("profile: ${{ inputs.profile }}", text)
                else:
                    self.assertIn("K8S_PROFILE:", text)
        reusable = workflow_text("reusable-deploy.yml")
        self.assertEqual(reusable.count("K8S_PROFILE: ${{ inputs.profile }}"), 2)

    def test_profile_validation_precedes_tools_authentication_and_mutation(self):
        direct = [name for name in PROFILE_WORKFLOWS if name != "deploy.yml"]
        for name in direct:
            data = workflow(name)
            for job_name, job in data["jobs"].items():
                steps = job.get("steps", [])
                mutating = [
                    index
                    for index, step in enumerate(steps)
                    if re.search(r"Install|Authenticate|Clean infrastructure|Destroy the", step.get("name", ""))
                ]
                if not mutating:
                    continue
                validators = [
                    index
                    for index, step in enumerate(steps)
                    if "Validate" in step.get("name", "") and "profile" in step.get("name", "").lower()
                ]
                with self.subTest(workflow=name, job=job_name):
                    if job_name == "cleanup":
                        # The reusable deploy job validated the same immutable input before
                        # cleanup becomes eligible; cleanup only handles that failed run.
                        continue
                    self.assertTrue(validators)
                    self.assertLess(min(validators), min(mutating))

    def test_staging_unsupported_operations_have_explicit_capability_gates(self):
        backup = workflow_text("backup.yml")
        restore = workflow_text("restore-drill.yml")
        resize = workflow_text("resize.yml")
        self.assertIn("profile_capability backup", backup)
        self.assertIn("profile_capability restore", restore)
        self.assertIn("profile_capability horizontalResize", resize)
        self.assertIn("staging:1", resize)
        self.assertIn("production:2", resize)
        self.assertIn("production:3", resize)
        self.assertIn("full:3", resize)
        self.assertIn("full:4", resize)
        for text in (backup, restore, resize):
            self.assertIn("no changes were made", text)

    def test_runtime_capability_gate_rejects_staging_without_side_effects(self):
        for capability in ("backup", "restore", "horizontalResize"):
            command = (
                "source scripts/lib.sh; "
                f"profile_capability {capability} || "
                f"die 'profile staging does not support {capability}; no changes were made'"
            )
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=ROOT,
                text=True,
                capture_output=True,
                env={**os.environ, "K8S_PROFILE": "staging"},
            )
            with self.subTest(capability=capability):
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no changes were made", result.stderr)
        for profile in ("full", "production"):
            for capability in ("backup", "restore", "horizontalResize"):
                result = subprocess.run(
                    ["bash", "-c", f"source scripts/lib.sh; profile_capability {capability}"],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    env={**os.environ, "K8S_PROFILE": profile},
                )
                with self.subTest(profile=profile, capability=capability):
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_manual_jobs_are_owner_only_and_no_push_trigger_exists(self):
        for name in PROFILE_WORKFLOWS:
            data = workflow(name)
            with self.subTest(workflow=name):
                self.assertNotIn("push", data["on"])
                self.assertNotIn("pull_request", data["on"])
                owner_guarded = any(
                    "github.actor == github.repository_owner" in job.get("if", "")
                    for job in data["jobs"].values()
                )
                self.assertTrue(owner_guarded)

    def test_only_pinned_github_or_local_actions_are_used(self):
        uses_pattern = re.compile(r"^\s*uses:\s*(\S+)", re.MULTILINE)
        sha_pattern = re.compile(r"^actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
        for name in PROFILE_WORKFLOWS:
            with self.subTest(workflow=name):
                for target in uses_pattern.findall(workflow_text(name)):
                    if target.startswith("./"):
                        continue
                    self.assertRegex(target, sha_pattern)

    def test_concurrency_is_repository_wide(self):
        for name in PROFILE_WORKFLOWS:
            if name == "deploy.yml":
                # The caller delegates the operation to reusable-deploy, which owns
                # the lock. Duplicating the same group on caller and callee can queue
                # the called workflow behind its own caller.
                self.assertIn("uses: ./.github/workflows/reusable-deploy.yml", workflow_text(name))
                continue
            data = workflow(name)
            with self.subTest(workflow=name):
                self.assertEqual(data["concurrency"]["group"], "zerops-k8s-${{ github.repository }}")
                self.assertEqual(data["concurrency"]["cancel-in-progress"], "false")

    def test_evidence_is_profile_named_and_retained_one_day(self):
        evidence_workflows = [
            "backup.yml",
            "destroy.yml",
            "maintenance.yml",
            "resize.yml",
            "restore-drill.yml",
            "reusable-deploy.yml",
            "upgrade.yml",
        ]
        for name in evidence_workflows:
            data = workflow(name)
            upload_steps = [
                step
                for job in data["jobs"].values()
                for step in job.get("steps", [])
                if str(step.get("uses", "")).startswith("actions/upload-artifact@")
            ]
            with self.subTest(workflow=name):
                self.assertTrue(upload_steps)
                for step in upload_steps:
                    self.assertEqual(step["with"]["retention-days"], "1")
                    self.assertIn("profile", step["with"]["name"].lower())
                self.assertIn("profile-contract.json", workflow_text(name))

    def test_redactor_removes_required_sensitive_classes(self):
        sample = (
            "Authorization: Bearer abc.def.ghi\n"
            "Cookie: session=secret-cookie\n"
            "Set-Cookie: auth=another-secret\n"
            "token=token-value password: pass-value secret='secret-value'\n"
            "owner@example.invalid connected from 203.0.113.42\n"
        )
        result = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh")],
            cwd=ROOT,
            input=sample,
            text=True,
            capture_output=True,
            check=True,
            env=os.environ,
        )
        for sensitive in (
            "abc.def.ghi",
            "secret-cookie",
            "another-secret",
            "token-value",
            "pass-value",
            "secret-value",
            "owner@example.invalid",
            "203.0.113.42",
        ):
            self.assertNotIn(sensitive, result.stdout)
        self.assertIn("[REDACTED]", result.stdout)
        self.assertIn("[REDACTED_EMAIL]", result.stdout)
        self.assertIn("[REDACTED_IP]", result.stdout)

    def test_profile_documentation_covers_workflows_endpoints_and_imports(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        guide = (ROOT / "docs" / "profiles.md").read_text(encoding="utf-8")
        for name in PROFILE_WORKFLOWS:
            self.assertIn(name, guide)
        for profile in PROFILES:
            with (ROOT / "profiles" / f"{profile}.json").open(encoding="utf-8") as handle:
                descriptor = json.load(handle)
            endpoint = descriptor["topology"]["controlPlaneEndpoint"]
            self.assertIn(endpoint, readme)
            self.assertIn(endpoint, guide)
            import_name = "import.yaml" if profile == "full" else f"import.{profile}.yaml"
            raw = f"https://raw.githubusercontent.com/Samyazz/zerops-k8s/main/{import_name}"
            self.assertIn(raw, readme)
            self.assertIn(raw, guide)
        self.assertRegex(readme, r"production` is not control-plane HA")
        self.assertIn("not three clusters intended to coexist in one project", guide)


if __name__ == "__main__":
    unittest.main()
