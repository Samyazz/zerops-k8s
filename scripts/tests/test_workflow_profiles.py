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

    def test_failed_clean_creation_has_an_owned_outer_service_purge(self):
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        cleanup = (ROOT / "scripts" / "cleanup-failed-run.sh").read_text(encoding="utf-8")
        reconcile = (ROOT / "scripts" / "reconcile-profile-services.sh").read_text(encoding="utf-8")
        self.assertLess(
            deploy.index('set_cluster_tag attempt "$GITHUB_RUN_ID"'),
            deploy.index('"$ROOT_DIR/scripts/reconcile-profile-services.sh" apply'),
        )
        self.assertIn('"$ROOT_DIR/scripts/reconcile-profile-services.sh" purge', cleanup)
        self.assertIn('"$attempt" == "$GITHUB_RUN_ID"', cleanup)
        self.assertIn('"$state" == destroyed || "$state" == deploying', cleanup)
        self.assertIn('set_cluster_state cleanup-failed', cleanup)
        self.assertIn('set_cluster_state destroyed', cleanup)
        self.assertIn('mode" == purge', reconcile)
        self.assertIn('partial recipe-owned services remain after cleanup', reconcile)

    def test_next_deploy_purges_an_abandoned_clean_creation_before_retry(self):
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        stale = deploy.index('"$project_state" == deploying')
        purge = deploy.index('"$ROOT_DIR/scripts/reconcile-profile-services.sh" purge', stale)
        attempt = deploy.index('set_cluster_tag attempt "$GITHUB_RUN_ID"')
        self.assertLess(stale, purge)
        self.assertLess(purge, attempt)
        self.assertIn('"$project_owner_run" != "$GITHUB_RUN_ID"', deploy)

    def test_actions_deploys_the_exact_clean_revision(self):
        deploy = (ROOT / "scripts" / "build-and-deploy.sh").read_text(encoding="utf-8")
        self.assertIn('"${GITHUB_ACTIONS:-false}" == true', deploy)
        self.assertIn('source_args=(--workspace-state clean)', deploy)
        self.assertIn("prepare_node_agent_artifact", deploy)
        self.assertIn('zcli service deploy "$service"', deploy)
        self.assertIn('--working-dir "$NODE_AGENT_ARTIFACT_DIR"', deploy)

    def test_network_probes_use_the_distroless_agnhost_binary(self):
        for name in ("acceptance.sh", "acceptance-profile.sh"):
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertIn("/agnhost connect --timeout=10s", text)
                self.assertNotIn("exec \"$source_pod\" -- wget", text)
                self.assertNotIn("exec \"${proof_pods[0]}\" -- wget", text)

    def test_distroless_etcd_encryption_probe_does_not_require_a_shell(self):
        acceptance = (ROOT / "scripts" / "acceptance-profile.sh").read_text(encoding="utf-8")
        self.assertIn("-- etcdctl \\\n", acceptance)
        self.assertNotIn("-- sh -ec \\\n", acceptance)

    def test_explicit_destroy_removes_all_recipe_owned_outer_services(self):
        workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")
        destroy = workflow.index("./scripts/destroy-cluster.sh")
        purge = workflow.index("./scripts/reconcile-profile-services.sh purge", destroy)
        self.assertLess(destroy, purge)

    def test_restore_drill_uses_the_selected_profile_contract(self):
        restore = (ROOT / "scripts" / "restore-drill.sh").read_text(encoding="utf-8")
        self.assertIn('expected_nodes=$(printf', restore)
        self.assertIn("profile_json '.addons.storageReplicas'", restore)
        self.assertIn("numberOfReplicas: $storage_replicas", restore)
        self.assertNotIn(".nodes | length >= 6", restore)
        self.assertNotIn("numberOfReplicas: 3", restore)

    def test_production_upgrade_rolls_workers_before_single_control_plane(self):
        upgrade = (ROOT / "scripts" / "upgrade-cluster.sh").read_text(encoding="utf-8")
        production = upgrade.index('[[ "$K8S_PROFILE" == production ]]')
        workers_first = upgrade.index('upgrade_order=("${workers[@]}" "${CONTROL_PLANES[@]}")')
        self.assertLess(production, workers_first)

    def test_maintenance_acceptance_can_skip_duplicate_disruptions(self):
        acceptance = (ROOT / "scripts" / "acceptance-profile.sh").read_text(encoding="utf-8")
        guard = acceptance.index('${SKIP_DISRUPTION_TESTS:-false}')
        disruption = acceptance.index('run_node_recovery_tests', guard)
        self.assertLess(guard, disruption)

    def test_staging_rollout_breaks_the_single_worker_typha_dependency_cycle(self):
        rollout = (ROOT / "scripts" / "redeploy-node-agents.sh").read_text(encoding="utf-8")
        self.assertIn('"$K8S_PROFILE" == staging', rollout)
        self.assertIn('uncordoning the single staging worker so Calico Typha can recover', rollout)
        uncordon = rollout.index('uncordoning the single staging worker')
        ready_wait = rollout.index('kubectl wait "node/$service" --for=condition=Ready', uncordon)
        self.assertLess(uncordon, ready_wait)

    def test_maintenance_never_redeploys_stateful_outer_node_runtimes(self):
        maintenance = (ROOT / "scripts" / "rolling-update.sh").read_text(encoding="utf-8")
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        self.assertIn('PUSH_AGENT_CODE=false "$ROOT_DIR/scripts/redeploy-node-agents.sh"', maintenance)
        self.assertNotIn('PUSH_AGENT_CODE=true "$ROOT_DIR/scripts/redeploy-node-agents.sh"', maintenance)
        self.assertIn("identity_before=", maintenance)
        self.assertIn("identity_after=", maintenance)
        self.assertIn("rolling maintenance changed the Kubernetes cluster or node identities", maintenance)
        reconcile = deploy.index('if [[ "$RECONCILE_EXISTING" == true ]]')
        preserve = deploy.index("preserving existing outer node runtimes", reconcile)
        fresh = deploy.index('"$ROOT_DIR/scripts/build-and-deploy.sh"', preserve)
        self.assertLess(preserve, fresh)

    def test_resize_preserves_permanent_cluster_and_node_identities(self):
        resize = (ROOT / "scripts" / "resize-cluster.sh").read_text(encoding="utf-8")
        self.assertIn("identity_before=", resize)
        self.assertIn("identity_after=", resize)
        self.assertIn("permanent node identities", resize)
        self.assertIn("evidence/resize/identity.json", resize)
        self.assertIn('wait_cluster_api "$node Zerops resize restart"', resize)
        self.assertIn("until kubectl --request-timeout=10s get --raw=/readyz", resize)

    def test_resize_rechecks_api_after_persisting_cluster_settings(self):
        resize = (ROOT / "scripts" / "resize-cluster.sh").read_text(encoding="utf-8")
        settings = resize.index('set_cluster_tag worker-disk "$worker_disk"')
        final_api_gate = resize.index(
            "wait_cluster_api 'the completed resize and Zerops setting updates'"
        )
        final_node_gate = resize.index("kubectl wait --for=condition=Ready nodes --all")
        self.assertLess(settings, final_api_gate)
        self.assertLess(final_api_gate, final_node_gate)
        self.assertIn("kubectl --request-timeout=10s get --raw=/readyz", resize)

    def test_worker_removal_retries_longhorn_webhook_mutations(self):
        resize = (ROOT / "scripts" / "resize-cluster.sh").read_text(encoding="utf-8")
        self.assertIn("retry_longhorn_node_mutation()", resize)
        self.assertIn("Longhorn admission webhook did not recover", resize)
        self.assertIn(
            'retry_longhorn_node_mutation patch "nodes.longhorn.io/$node"', resize
        )
        self.assertIn(
            'retry_longhorn_node_mutation delete "nodes.longhorn.io/$node"', resize
        )

    def test_upgrade_never_redeploys_stateful_outer_node_runtimes(self):
        upgrade = (ROOT / "scripts" / "upgrade-cluster.sh").read_text(encoding="utf-8")
        self.assertNotIn('PUSH_AGENT_CODE=true "$ROOT_DIR/scripts/redeploy-node-agents.sh"', upgrade)
        self.assertIn("installed node agent predates the state-preserving upgrade endpoint", upgrade)

    def test_fresh_object_storage_environment_is_loaded_before_agent_delivery(self):
        library = (ROOT / "scripts" / "lib.sh").read_text(encoding="utf-8")
        delivery = (ROOT / "scripts" / "build-and-deploy.sh").read_text(encoding="utf-8")
        self.assertIn("load_backup_env()", library)
        self.assertIn('--service "$BACKUP_HOSTNAME"', library)
        self.assertIn("export K8S_IMAGE_STORAGE_ENDPOINT=$apiUrl", library)
        self.assertIn("load_backup_env", delivery)

    def test_failed_fresh_creation_purges_even_from_cleanup_failed(self):
        cleanup = (ROOT / "scripts" / "cleanup-failed-run.sh").read_text(encoding="utf-8")
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        destroy = workflow_text("destroy.yml")
        self.assertIn('"$state" == cleanup-failed', cleanup)
        self.assertIn("deployment failed before agent delivery", deploy)
        self.assertIn("purging recipe-owned outer services directly", destroy)

    def test_compact_profiles_collect_platform_logs_and_resource_statistics(self):
        acceptance = (ROOT / "scripts" / "acceptance-profile.sh").read_text(encoding="utf-8")
        self.assertIn("collect_platform_log_evidence", acceptance)
        self.assertIn("collect_platform_stats_evidence", acceptance)
        self.assertIn("/stats-history/group-by-search", acceptance)
        self.assertIn('limit:20,timeZone:"UTC"', acceptance)
        self.assertNotIn('limit:1000,from:$from,till:$till', acceptance)
        self.assertIn("zerops-runtime-statistics.json", acceptance)
        self.assertIn("zerops-backup-storage.json", acceptance)

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

    def test_every_artifact_is_sanitized_immediately_before_upload(self):
        evidence_workflows = [name for name in PROFILE_WORKFLOWS if name != "deploy.yml"]
        for name in evidence_workflows:
            text = workflow_text(name)
            with self.subTest(workflow=name):
                sanitizer = text.rfind('./scripts/sanitize-evidence-tree.sh "$RUNNER_TEMP/evidence"')
                upload = text.rfind("uses: actions/upload-artifact@")
                self.assertGreater(sanitizer, -1)
                self.assertGreater(upload, sanitizer)

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
