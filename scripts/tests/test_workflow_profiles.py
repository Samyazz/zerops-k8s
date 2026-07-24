import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
PROFILES = ["full", "production", "staging"]
RECIPE_RELEASE_REF = dict(
    line.split("=", 1)
    for line in (ROOT / "release.env").read_text(encoding="utf-8").splitlines()
    if line and not line.startswith("#")
)["RECIPE_RELEASE_REF"]
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


def write_mock_platform(directory, inventory):
    inventory_path = directory / "inventory.json"
    calls_path = directory / "zcli-calls.txt"
    inventory_path.write_text(json.dumps({"list": inventory}), encoding="utf-8")
    calls_path.write_text("", encoding="utf-8")
    curl = directory / "curl"
    curl.write_text(
        """#!/usr/bin/env bash
set -Eeuo pipefail
output=
while (( $# > 0 )); do
  if [[ $1 == --output ]]; then shift; output=$1; fi
  shift
done
[[ -n $output ]]
cp "$MOCK_INVENTORY" "$output"
printf 200
""",
        encoding="utf-8",
    )
    zcli = directory / "zcli"
    zcli.write_text(
        """#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >>"$MOCK_ZCLI_CALLS"
printf '\n' >>"$MOCK_ZCLI_CALLS"
if [[ ${1:-} == service && ${2:-} == delete && -n ${3:-} ]]; then
  temporary=$(mktemp)
  jq --arg name "$3" '.list |= map(select(.name != $name))' "$MOCK_INVENTORY" >"$temporary"
  mv "$temporary" "$MOCK_INVENTORY"
  exit 0
fi
exit 97
""",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    zcli.chmod(0o755)
    return inventory_path, calls_path


def profile_services(name):
    with (ROOT / "profiles" / f"{name}.json").open(encoding="utf-8") as handle:
        return [service["hostname"] for service in json.load(handle)["services"]]


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

    def test_full_conformance_cannot_be_disabled_for_full_profile(self):
        for name in ("reusable-deploy.yml", "upgrade.yml"):
            text = workflow_text(name)
            with self.subTest(workflow=name):
                gate = text.index('"$K8S_PROFILE" != full || "$RUN_FULL_CONFORMANCE" == true')
                mutation = min(
                    position for marker in ("Install pinned", "Authenticate to Zerops")
                    if (position := text.find(marker)) >= 0
                )
                self.assertLess(gate, mutation)
                self.assertIn("profile full requires the CNCF certified-conformance suite", text)

    def test_live_operation_profile_matches_tag_before_vpn_mutation(self):
        for name in (
            "backup.yml",
            "destroy.yml",
            "maintenance.yml",
            "resize.yml",
            "restore-drill.yml",
            "upgrade.yml",
        ):
            text = workflow_text(name)
            with self.subTest(workflow=name):
                assertion = text.index("live_profile=$(cluster_tag_value profile)")
                mutation = text.index("zcli vpn up")
                self.assertLess(assertion, mutation)
                self.assertIn("does not match live profile", text)
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

    def test_all_profile_pair_plans_are_deterministic_and_ownership_scoped(self):
        unrelated = ["zcp", "customerdb"]
        planner = ROOT / "scripts" / "reconcile-profile-services.sh"
        for source in PROFILES:
            source_services = profile_services(source)
            source_inventory = [
                {"name": name, "status": "ACTIVE"}
                for name in [*source_services, *unrelated]
            ]
            for target in PROFILES:
                with self.subTest(source=source, target=target):
                    outputs = []
                    calls = []
                    for _ in range(2):
                        with tempfile.TemporaryDirectory() as temporary:
                            mock_dir = Path(temporary)
                            inventory_path, calls_path = write_mock_platform(mock_dir, source_inventory)
                            result = subprocess.run(
                                [str(planner), "plan"],
                                cwd=ROOT,
                                text=True,
                                capture_output=True,
                                env={
                                    **os.environ,
                                    "PATH": f"{mock_dir}:{os.environ['PATH']}",
                                    "K8S_PROFILE": target,
                                    "ZEROPS_TOKEN": "test-token",
                                    "ZEROPS_PROJECT_ID": "test-project",
                                    "MOCK_INVENTORY": str(inventory_path),
                                    "MOCK_ZCLI_CALLS": str(calls_path),
                                },
                            )
                            self.assertEqual(result.returncode, 0, result.stderr)
                            outputs.append(result.stdout)
                            calls.append(calls_path.read_text(encoding="utf-8"))
                    self.assertEqual(outputs[0], outputs[1])
                    self.assertEqual(calls, ["", ""], "plan mode invoked mutating zcli")
                    for name in unrelated:
                        self.assertNotIn(name, outputs[0])
                    deleted = set(re.findall(r"target profile [^:]+: ([a-z0-9]+)", outputs[0]))
                    expected_deleted = set(source_services) - set(profile_services(target))
                    self.assertEqual(deleted, expected_deleted)
                    missing_match = re.search(r"is missing services: (.+)$", outputs[0], re.MULTILINE)
                    missing = set(missing_match.group(1).split()) if missing_match else set()
                    expected_missing = set(profile_services(target)) - set(source_services)
                    self.assertEqual(missing, expected_missing)

    def test_recipe_owned_purge_is_idempotent_and_preserves_unrelated_services(self):
        purge = ROOT / "scripts" / "reconcile-profile-services.sh"
        unrelated = ["zcp", "customerdb"]
        source_services = profile_services("production")
        inventory = [
            {"name": name, "status": "ACTIVE"}
            for name in [*source_services, *unrelated]
        ]
        with tempfile.TemporaryDirectory() as temporary:
            mock_dir = Path(temporary)
            inventory_path, calls_path = write_mock_platform(mock_dir, inventory)
            environment = {
                **os.environ,
                "PATH": f"{mock_dir}:{os.environ['PATH']}",
                "K8S_PROFILE": "production",
                "ZEROPS_TOKEN": "test-token",
                "ZEROPS_PROJECT_ID": "test-project",
                "MOCK_INVENTORY": str(inventory_path),
                "MOCK_ZCLI_CALLS": str(calls_path),
            }
            first = subprocess.run(
                [str(purge), "purge"], cwd=ROOT, text=True, capture_output=True, env=environment,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            first_calls = calls_path.read_text(encoding="utf-8").splitlines()
            second = subprocess.run(
                [str(purge), "purge"], cwd=ROOT, text=True, capture_output=True, env=environment,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            second_calls = calls_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(second_calls, first_calls, "second purge was not a no-op")
            remaining = json.loads(inventory_path.read_text(encoding="utf-8"))["list"]
            self.assertEqual([item["name"] for item in remaining], unrelated)
            self.assertEqual(
                {re.match(r"service delete ([^ ]+)", call).group(1) for call in first_calls},
                set(source_services),
            )

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
        guide = (ROOT / "docs" / "upgrades.md").read_text(encoding="utf-8")
        production = upgrade.index('[[ "$K8S_PROFILE" == production ]]')
        workers_first = upgrade.index('upgrade_order=("${workers[@]}" "${CONTROL_PLANES[@]}")')
        self.assertLess(production, workers_first)
        self.assertIn("| `production` | Workers serially, then sole `k8scp1` |", guide)

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

    def test_legacy_edge_migration_is_backup_protected_and_clean(self):
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ -z "${K8S_VRRP_VIP:-}" ]]', deploy)
        self.assertIn("edge_migration_required=true", deploy)
        self.assertIn("backup-protected clean cluster replacement", deploy)
        self.assertIn('"$ROOT_DIR/scripts/prepare-profile-switch.sh" "$project_profile"', deploy)
        self.assertIn("RECREATE_TARGET_RUNTIME_SERVICES=true", deploy)

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

    def test_every_live_operation_streams_output_through_the_redactor(self):
        mutation = re.compile(
            r"zcli login|\./scripts/(?:backup-cluster|cancel-process|cleanup-failed-run|"
            r"deploy|destroy-cluster|recover-node-agents|reconcile-profile-services|"
            r"resize-cluster|restore-drill|rolling-update|upgrade-cluster)\.sh"
        )
        for name in (entry for entry in PROFILE_WORKFLOWS if entry != "deploy.yml"):
            data = workflow(name)
            for job_name, job in data["jobs"].items():
                for step in job.get("steps", []):
                    command = step.get("run", "")
                    if not mutation.search(command):
                        continue
                    with self.subTest(workflow=name, job=job_name, step=step.get("name")):
                        self.assertIn(
                            "2>&1 | ./scripts/redact-evidence.sh",
                            command,
                            "live operation output would reach the public Actions log unredacted",
                        )

    def test_secrets_are_step_scoped_and_every_secret_bearing_step_is_redacted(self):
        for name in (entry for entry in PROFILE_WORKFLOWS if entry != "deploy.yml"):
            data = workflow(name)
            for job_name, job in data["jobs"].items():
                with self.subTest(workflow=name, job=job_name):
                    self.assertFalse(
                        any("secrets." in value for value in job.get("env", {}).values()),
                        "job-scoped secrets expose credentials to unrelated steps",
                    )
                for step in job.get("steps", []):
                    secret_values = [
                        value
                        for value in step.get("env", {}).values()
                        if "secrets." in value
                    ]
                    if not secret_values:
                        continue
                    command = step.get("run", "")
                    with self.subTest(workflow=name, job=job_name, step=step.get("name")):
                        self.assertIn("2>&1 | ./scripts/redact-evidence.sh", command)

    def test_streaming_redaction_preserves_operation_failure(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                "set -Eeuo pipefail; "
                "{ printf 'source=10.20.30.40\\n'; exit 23; } "
                "2>&1 | ./scripts/redact-evidence.sh",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            env=os.environ,
        )
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("10.20.30.40", result.stdout)
        self.assertIn("[REDACTED_IP]", result.stdout)

    def test_redacted_json_arrays_remain_valid_and_hide_every_value(self):
        fixtures = [
            {"Authorization": ["Bearer array-authorization-secret"]},
            {"Cookie": ["session=array-cookie-secret"]},
            {"secret": ["array generic secret value"]},
            {"ELASTIC_APM_SECRET_TOKEN": ["array-apm-token-value"]},
            {
                "Authorization": [
                    "Bearer first-authorization-secret",
                    "Basic second-authorization-secret",
                ]
            },
            {
                "Cookie": [
                    "first-cookie=first-cookie-secret",
                    "second-cookie=second-cookie-secret",
                ]
            },
            {"secret": ["first-generic-secret", "second-generic-secret"]},
            {
                "Authorization": 'Digest username="digest-user", '
                'nonce="digest-nonce"'
            },
            {"Cookie": 'quoted="cookie-secret"; other=next'},
            {"password": 'part-one"part-two-secret'},
            {"password": None},
            {"access_token": 123456789},
            {"api-key": False},
        ]
        result = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh")],
            cwd=ROOT,
            input="".join(
                json.dumps(fixture, separators=separators) + "\n"
                for fixture in fixtures
                for separators in (None, (",", ":"))
            ),
            text=True,
            capture_output=True,
            check=True,
            env=os.environ,
        )
        rendered = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(rendered), len(fixtures) * 2)
        for index, document in enumerate(rendered):
            value = next(iter(document.values()))
            original = next(iter(fixtures[index // 2].values()))
            expected = (
                ["[REDACTED]"] * len(original)
                if isinstance(original, list)
                else "[REDACTED]"
            )
            self.assertEqual(value, expected)
        for leaked in (
            "array-authorization-secret",
            "array-cookie-secret",
            "array generic secret value",
            "array-apm-token-value",
            "digest-user",
            "digest-nonce",
            "cookie-secret",
            "part-two-secret",
            "first-authorization-secret",
            "second-authorization-secret",
            "first-cookie-secret",
            "second-cookie-secret",
            "first-generic-secret",
            "second-generic-secret",
            "123456789",
        ):
            self.assertNotIn(leaked, result.stdout)

    def test_streaming_cleanup_preserves_signal_status_and_runs_once(self):
        for signal, expected in (("INT", 130), ("TERM", 143)):
            command = f"""
                set -Eeuo pipefail
                {{
                  finish() {{
                    status=$?
                    trap - EXIT INT TERM
                    printf 'cleanup:%s\\n' "$status"
                    exit "$status"
                  }}
                  trap finish EXIT
                  trap 'exit 130' INT
                  trap 'exit 143' TERM
                  kill -{signal} "$BASHPID"
                }} 2>&1 | ./scripts/redact-evidence.sh
            """
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=ROOT,
                text=True,
                capture_output=True,
                env=os.environ,
            )
            with self.subTest(signal=signal):
                self.assertEqual(result.returncode, expected)
                self.assertEqual(result.stdout.count(f"cleanup:{expected}"), 1)

    def test_structured_redaction_covers_header_aliases_and_secret_shapes(self):
        provider_token_key = "_".join(("github", "pat", "x" * 32))
        sensitive_values = {
            "Proxy-Authorization": "Bearer proxy-authorization-value",
            "proxy_authorization": "Basic proxy-underscore-value",
            "http.request.header.authorization": "Bearer otel-auth-value",
            "http.request.header.cookie": "session=otel-cookie-value",
            "authorizationHeader": "Bearer camel-auth-value",
            "proxyAuthorization": "Bearer camel-proxy-value",
            "cookieHeader": "session=camel-cookie-value",
            "setCookieHeader": "session=camel-set-cookie-value",
            "K8S_CERTIFICATE_KEY": "certificate-key-value",
            "K8S_ENCRYPTION_KEY": "encryption-key-value",
            "K8S_RECOVERY_AGE_IDENTITY": "age-identity-value",
            "K8S_ADMIN_KUBECONFIG_B64_RUN_123": "kubeconfig-value",
            "SSH_PRIVATE_KEY": "private-key-value",
            "databaseCredential": "credential-value",
            "Client Secret": "spaced-client-secret-value",
            "Access Token": "spaced-access-token-value",
            "Database Password": "spaced-database-password-value",
            "Private Key": "spaced-private-key-value",
            "Encryption Key": "spaced-encryption-key-value",
            "Age Identity": "spaced-age-identity-value",
            "Kube Config": "spaced-kubeconfig-value",
            "Client Certificate Data": "spaced-client-certificate-value",
            "Client Key Data": "spaced-client-key-value",
            "API Key Value": "spaced-api-key-suffix-value",
            "Access Key ID Value": "spaced-access-key-suffix-value",
        }
        fixture = {
            **sensitive_values,
            "client_secret": {
                provider_token_key: "secret-leaf",
                "copies": ["copy-one", None, False],
            },
        }
        result = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh")],
            cwd=ROOT,
            input=json.dumps(fixture) + "\n",
            text=True,
            capture_output=True,
            check=True,
            env=os.environ,
        )
        rendered = json.loads(result.stdout)
        for key in sensitive_values:
            self.assertEqual(rendered[key], "[REDACTED]")
        self.assertNotIn(provider_token_key, json.dumps(rendered))
        self.assertEqual(
            rendered["client_secret"],
            {
                "[REDACTED_TOKEN]": "[REDACTED]",
                "copies": ["[REDACTED]", "[REDACTED]", "[REDACTED]"],
            },
        )
        for leaked in (*sensitive_values.values(), provider_token_key, "secret-leaf"):
            self.assertNotIn(leaked, result.stdout)

    def test_document_redaction_handles_pretty_json_and_rejects_secret_objects(self):
        pretty = {
            "headers": {
                "Authorization": [
                    "Bearer pretty-first-value",
                    "Basic pretty-second-value",
                ],
                "Cookie": [
                    "session=pretty-cookie-one",
                    "csrf=pretty-cookie-two",
                ],
            },
            "client_secret": {
                "primary": "pretty-nested-secret",
                "copies": [None, 7, False],
            },
        }
        result = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh"), "--document"],
            cwd=ROOT,
            input=json.dumps(pretty, indent=2) + "\n",
            text=True,
            capture_output=True,
            check=True,
            env=os.environ,
        )
        rendered = json.loads(result.stdout)
        self.assertEqual(
            rendered["headers"]["Authorization"],
            ["[REDACTED]", "[REDACTED]"],
        )
        self.assertEqual(
            rendered["headers"]["Cookie"],
            ["[REDACTED]", "[REDACTED]"],
        )
        self.assertEqual(
            rendered["client_secret"],
            {
                "primary": "[REDACTED]",
                "copies": ["[REDACTED]", "[REDACTED]", "[REDACTED]"],
            },
        )
        for leaked in (
            "pretty-first-value",
            "pretty-second-value",
            "pretty-cookie-one",
            "pretty-cookie-two",
            "pretty-nested-secret",
        ):
            self.assertNotIn(leaked, result.stdout)

        streamed = subprocess.run(
            [str(ROOT / "scripts" / "redact-evidence.sh")],
            cwd=ROOT,
            input=json.dumps(pretty, indent=2) + "\n",
            text=True,
            capture_output=True,
            check=True,
            env=os.environ,
        )
        streamed_json = json.loads(streamed.stdout)
        self.assertEqual(
            streamed_json["headers"]["Authorization"],
            "[REDACTED]",
        )
        self.assertEqual(streamed_json["client_secret"], "[REDACTED]")
        for leaked in (
            "pretty-first-value",
            "pretty-second-value",
            "pretty-cookie-one",
            "pretty-cookie-two",
            "pretty-nested-secret",
        ):
            self.assertNotIn(leaked, streamed.stdout)

        for secret_stream in (
            (
                "apiVersion: v1\n"
                "data:\n"
                "  arbitrary: streaming-yaml-before-kind\n"
                "kind: 'Secret'\n"
                "---\n"
                "kind: ConfigMap\n"
                "data:\n"
                "  safe: retained-after-secret\n"
            ),
            json.dumps(
                {
                    "apiVersion": "v1",
                    "data": {"arbitrary": "streaming-json-before-kind"},
                    "kind": "Secret",
                },
                indent=2,
            )
            + "\n",
        ):
            secret_result = subprocess.run(
                [str(ROOT / "scripts" / "redact-evidence.sh")],
                cwd=ROOT,
                input=secret_stream,
                text=True,
                capture_output=True,
                check=True,
                env=os.environ,
            )
            self.assertIn(
                "[REDACTED_KUBERNETES_SECRET]",
                secret_result.stdout,
            )
            self.assertNotIn("streaming-yaml-secret", secret_result.stdout)
            self.assertNotIn("streaming-json-secret", secret_result.stdout)
            self.assertNotIn("streaming-yaml-before-kind", secret_result.stdout)
            self.assertNotIn("streaming-json-before-kind", secret_result.stdout)
            if secret_stream.lstrip().startswith("{"):
                json.loads(secret_result.stdout)

        yaml_fixture = {
            "password": ["yaml-first-password", "yaml-second-password"],
            "client_secret": {
                "primary": "yaml-primary-secret",
                "copies": ["yaml-copy-secret", None],
            },
            "K8S_ENCRYPTION_KEY": "yaml multi word encryption value",
            "safe": "retained",
        }
        with tempfile.TemporaryDirectory() as tmp:
            yaml_path = Path(tmp) / "credentials.yaml"
            yaml_path.write_text(
                yaml.safe_dump(yaml_fixture, sort_keys=False),
                encoding="utf-8",
            )
            sanitized = subprocess.run(
                [str(ROOT / "scripts" / "sanitize-evidence-tree.sh"), tmp],
                cwd=ROOT,
                text=True,
                capture_output=True,
                env=os.environ,
            )
            self.assertEqual(sanitized.returncode, 0, sanitized.stderr)
            rendered_yaml = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
            self.assertEqual(
                rendered_yaml,
                {
                    "password": ["[REDACTED]", "[REDACTED]"],
                    "client_secret": {
                        "primary": "[REDACTED]",
                        "copies": ["[REDACTED]", "[REDACTED]"],
                    },
                    "K8S_ENCRYPTION_KEY": "[REDACTED]",
                    "safe": "retained",
                },
            )

        text_fixture = (
            "password:\n"
            "  - text-first-password\n"
            "  - text-second-password\n"
            "client_secret:\n"
            "  primary: text-nested-secret\n"
            "K8S_ENCRYPTION_KEY: text multi word encryption value\n"
            "password: |2\n"
            "  block-indent-secret\n"
            "client_secret: |-2\n"
            "  block-chomp-indent-secret\n"
            "K8S_ENCRYPTION_KEY: |2-\n"
            "  block-indent-chomp-secret\n"
            "password: >4\n"
            "    folded-indent-secret\n"
            "client_secret: >+3\n"
            "   folded-chomp-indent-secret\n"
            "K8S_ENCRYPTION_KEY: >3+\n"
            "   folded-indent-chomp-secret\n"
            "password: |2 # block header comment\n"
            "  commented-block-secret\n"
            "client_secret: # nested mapping comment\n"
            "  primary: comment-nested-secret\n"
            "password: first-plain-secret\n"
            "  continued-plain-secret\n"
            'client_secret: "first-quoted-secret\n'
            '  continued-quoted-secret"\n'
            "- password: |2\n"
            "    sequence-block-secret\n"
            "- client_secret:\n"
            "    primary: sequence-map-secret\n"
            "safe-boundary: retained\n"
            "outer:\n"
            "  - password: >-\n"
            "      nested-sequence-secret\n"
            "- - password: |2\n"
            "      double-sequence-secret\n"
            "  - - client_secret:\n"
            "        primary: triple-sequence-secret\n"
            "? password\n"
            ": explicit-complex-key-secret\n"
            '? "password"\n'
            ": |\n"
            "  quoted-complex-key-secret\n"
            "? 'client_secret'\n"
            ": |\n"
            "  singlequoted-complex-key-secret\n"
            "Client Secret: |\n"
            "  spaced-multiline-secret\n"
            "Access Token:\n"
            "  nested-spaced-token\n"
            "- Database Password: >-\n"
            "    nested-spaced-password\n"
            "safe text remains\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            text_path = Path(tmp) / "credentials.txt"
            text_path.write_text(text_fixture, encoding="utf-8")
            sanitized = subprocess.run(
                [str(ROOT / "scripts" / "sanitize-evidence-tree.sh"), tmp],
                cwd=ROOT,
                text=True,
                capture_output=True,
                env=os.environ,
            )
            self.assertEqual(sanitized.returncode, 0, sanitized.stderr)
            rendered_text = text_path.read_text(encoding="utf-8")
            for leaked in (
                "text-first-password",
                "text-second-password",
                "text-nested-secret",
                "text multi word encryption value",
                "block-indent-secret",
                "block-chomp-indent-secret",
                "block-indent-chomp-secret",
                "folded-indent-secret",
                "folded-chomp-indent-secret",
                "folded-indent-chomp-secret",
                "commented-block-secret",
                "comment-nested-secret",
                "first-plain-secret",
                "continued-plain-secret",
                "first-quoted-secret",
                "continued-quoted-secret",
                "sequence-block-secret",
                "sequence-map-secret",
                "nested-sequence-secret",
                "double-sequence-secret",
                "triple-sequence-secret",
                "explicit-complex-key-secret",
                "quoted-complex-key-secret",
                "singlequoted-complex-key-secret",
                "spaced-multiline-secret",
                "nested-spaced-token",
                "nested-spaced-password",
            ):
                self.assertNotIn(leaked, rendered_text)
            self.assertIn("safe text remains", rendered_text)

        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp).parent / "zerops-k8s-symlink-target.txt"
            outside.write_text("symlink-secret-value", encoding="utf-8")
            try:
                (Path(tmp) / "evidence-link").symlink_to(outside)
                rejected = subprocess.run(
                    [str(ROOT / "scripts" / "sanitize-evidence-tree.sh"), tmp],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    env=os.environ,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("refusing non-regular evidence entry", rejected.stderr)
                self.assertNotIn("symlink-secret-value", rejected.stderr)
            finally:
                outside.unlink(missing_ok=True)

        with tempfile.TemporaryDirectory() as tmp:
            malformed = Path(tmp) / "malformed.yaml"
            malformed.write_text(
                "password: !vault |\n"
                "  malformed-custom-yaml-secret\n"
                "  second-malformed-secret\n",
                encoding="utf-8",
            )
            rejected = subprocess.run(
                [str(ROOT / "scripts" / "sanitize-evidence-tree.sh"), tmp],
                cwd=ROOT,
                text=True,
                capture_output=True,
                env=os.environ,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("refusing invalid or unsupported YAML evidence", rejected.stderr)
            self.assertNotIn("malformed-custom-yaml-secret", rejected.stderr)
            self.assertNotIn("second-malformed-secret", rejected.stderr)

        for filename, payload in (
            (
                "secret.json",
                json.dumps(
                    {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "data": {"arbitrary": "bm90LXJlYWwtc2VjcmV0"},
                    }
                ),
            ),
            (
                "secret-list.json",
                json.dumps(
                    {
                        "apiVersion": "v1",
                        "kind": "SecretList",
                        "items": [{"data": {"arbitrary": "list-secret-value"}}],
                    }
                ),
            ),
            (
                "secret.ndjson",
                '{"kind":"ConfigMap","data":{"safe":"value"}}\n'
                '{"kind":"Secret","data":{"arbitrary":"ndjson-secret-value"}}\n',
            ),
            (
                "secret.yaml",
                "apiVersion: v1\nkind: Secret\ndata:\n  arbitrary: placeholder\n",
            ),
            (
                "secret-list.yaml",
                "apiVersion: v1\nkind: SecretList\nitems: []\n",
            ),
            (
                "secret.txt",
                "apiVersion: v1\n"
                "kind: Secret\n"
                "data:\n"
                "  arbitrary: text-secret-object-value\n",
            ),
        ):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / filename
                path.write_text(payload, encoding="utf-8")
                rejected = subprocess.run(
                    [str(ROOT / "scripts" / "sanitize-evidence-tree.sh"), tmp],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    env=os.environ,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("refusing Kubernetes Secret evidence", rejected.stderr)
                self.assertNotIn("bm90LXJlYWwtc2VjcmV0", rejected.stderr)
                self.assertNotIn("ndjson-secret-value", rejected.stderr)
                self.assertNotIn("list-secret-value", rejected.stderr)
                self.assertNotIn("text-secret-object-value", rejected.stderr)

    def test_no_cleanup_trap_handles_exit_and_signals_with_one_handler(self):
        for path in [
            *ROOT.glob("scripts/*.sh"),
            *ROOT.glob("edge/*.sh"),
            *WORKFLOW_DIR.glob("*.yml"),
        ]:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotRegex(
                    text,
                    r"trap\s+(?!-)[^\n]*\bEXIT\s+INT\s+TERM\b",
                )

    def test_deploy_discards_encrypted_recovery_archives_before_sanitizing(self):
        text = workflow_text("reusable-deploy.yml")
        discard = text.index("-name '*.age' -delete")
        sanitizer = text.index('./scripts/sanitize-evidence-tree.sh "$RUNNER_TEMP/evidence"', discard)
        upload = text.index("uses: actions/upload-artifact@", sanitizer)
        self.assertLess(discard, sanitizer)
        self.assertLess(sanitizer, upload)

    def test_artifact_upload_requires_successful_sanitization(self):
        expected_gate = "${{ always() && steps.sanitize_evidence.outcome == 'success' }}"
        for name in (entry for entry in PROFILE_WORKFLOWS if entry != "deploy.yml"):
            data = workflow(name)
            for job_name, job in data["jobs"].items():
                steps = job.get("steps", [])
                uploads = [
                    (index, step)
                    for index, step in enumerate(steps)
                    if step.get("uses", "").startswith("actions/upload-artifact@")
                ]
                for upload_index, upload in uploads:
                    sanitizers = [
                        (index, step)
                        for index, step in enumerate(steps[:upload_index])
                        if "sanitize-evidence-tree.sh" in step.get("run", "")
                    ]
                    with self.subTest(
                        workflow=name,
                        job=job_name,
                        upload=upload.get("name"),
                    ):
                        self.assertTrue(sanitizers)
                        sanitizer_index, sanitizer = sanitizers[-1]
                        self.assertLess(sanitizer_index, upload_index)
                        self.assertEqual(sanitizer.get("id"), "sanitize_evidence")
                        self.assertEqual(sanitizer.get("if"), "always()")
                        self.assertEqual(upload.get("if"), expected_gate)

    def test_redactor_removes_required_sensitive_classes(self):
        aws_access_id = "AK" + "IAIOSFODNN7EXAMPLE"
        github_token = "github" + "_pat_1234567890abcdefghijklmnop"
        classic_github_token = "gh" + "p_1234567890abcdefghijklmnopqrstuv"
        age_identity = "AGE-" + "SECRET-KEY-1EXAMPLELONGIDENTITY"
        private_key_begin = "-----BEGIN " + "PRIVATE KEY-----"
        private_key_end = "-----END " + "PRIVATE KEY-----"
        kube_key_field = "-".join(("client", "key", "data"))
        kube_certificate_field = "-".join(("client", "certificate", "data"))
        sample = (
            "Authorization: Bearer abc.def.ghi\n"
            "Authorization: Basic dXNlcjpwYXNzd29yZA==\n"
            'headers={"Authorization":["Bearer array-token-value"]}\n'
            "Authorization: AWS4-HMAC-SHA256 Credential=aws4-example/20260722/eu/s3/aws4_request, SignedHeaders=host, Signature=aws4-signature\n"
            'Authorization: Digest username="digest-user", nonce="digest-nonce", response="digest-response"\n'
            'headers={"Authorization":["Custom custom-secret with-spaces"]}\n'
            "Cookie: session=secret-cookie; csrf=second-cookie-secret\n"
            "Set-Cookie: auth=another-secret\n"
            'headers={"Cookie":"signed=quoted-cookie-secret; theme=dark"}\n'
            "token=token-value password: pass-value secret='secret-value'\n"
            "ZEROPS_TOKEN=zerops-secret-value\n"
            'ELASTICSEARCH_PASSWORD="multi word password value"\n'
            "ELASTIC_APM_SECRET_TOKEN=elastic-apm-token-value\n"
            "SECRET_TOKEN=generic-secret-token-value\n"
            "access_token=access-token-value\n"
            "refresh_token=refresh-token-value\n"
            "client_secret=client-secret-value\n"
            "api_key=api-key-value\n"
            "[app] password: prefixed multi word password value\n"
            "level=error client_secret=prefixed multi word client secret\n"
            "[node] K8S_ENCRYPTION_KEY: prefixed multi word encryption key\n"
            "[app] Client Secret: prefixed spaced client secret\n"
            "level=error Access Token: prefixed spaced access token\n"
            "[app] Database Password: |\n"
            "  prefixed-spaced-block-password\n"
            "service_accessKeyId=service-access-key-value\n"
            "S3_ACCESS_KEY=s3-access-key-value\n"
            "K8S_SIGNING_KEY=signing-key-value\n"
            "TLS_KEY=tls-key-value\n"
            f"AWS_ACCESS_KEY_ID={aws_access_id}\n"
            "AWS_SECRET_ACCESS_KEY=aws-secret-value\n"
            f"{kube_key_field}: Y2xpZW50LXByaXZhdGUta2V5\n"
            f"{kube_certificate_field}: Y2xpZW50LWNlcnRpZmljYXRl\n"
            f"{github_token}\n"
            f"{classic_github_token}\n"
            f"{age_identity}\n"
            f"{private_key_begin}\n"
            "cHJpdmF0ZS1rZXktbWF0ZXJpYWw=\n"
            f"{private_key_end}\n"
            "owner@example.invalid connected from 203.0.113.42, 2001:db8::42, "
            "::1, and 2001:0db8:85a3:0000:0000:8a2e:0370:7334\n"
            'timestamp="2026-07-22T07:58:28.607822Z"\n'
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
            "dXNlcjpwYXNzd29yZA==",
            "array-token-value",
            "aws4-example",
            "aws4-signature",
            "digest-user",
            "digest-nonce",
            "digest-response",
            "custom-secret",
            "with-spaces",
            "secret-cookie",
            "second-cookie-secret",
            "another-secret",
            "quoted-cookie-secret",
            "token-value",
            "pass-value",
            "secret-value",
            "zerops-secret-value",
            "multi word password value",
            "elastic-apm-token-value",
            "generic-secret-token-value",
            "access-token-value",
            "refresh-token-value",
            "client-secret-value",
            "api-key-value",
            "prefixed multi word password value",
            "prefixed multi word client secret",
            "prefixed multi word encryption key",
            "prefixed spaced client secret",
            "prefixed spaced access token",
            "prefixed-spaced-block-password",
            "service-access-key-value",
            "s3-access-key-value",
            "signing-key-value",
            "tls-key-value",
            aws_access_id,
            "aws-secret-value",
            "Y2xpZW50LXByaXZhdGUta2V5",
            "Y2xpZW50LWNlcnRpZmljYXRl",
            github_token,
            classic_github_token,
            age_identity,
            "cHJpdmF0ZS1rZXktbWF0ZXJpYWw=",
            "owner@example.invalid",
            "203.0.113.42",
            "2001:db8::42",
            "::1",
            "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
        ):
            self.assertNotIn(sensitive, result.stdout)
        self.assertIn("[REDACTED]", result.stdout)
        self.assertIn("[REDACTED_EMAIL]", result.stdout)
        self.assertIn("[REDACTED_IP]", result.stdout)
        self.assertIn("[REDACTED_PRIVATE_KEY]", result.stdout)
        self.assertIn('timestamp="2026-07-22T07:58:28.607822Z"', result.stdout)

    def test_profile_documentation_covers_workflows_endpoints_and_imports(self):
        self.assertRegex(RECIPE_RELEASE_REF, r"\A[0-9a-f]{40}\Z")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        guide = (ROOT / "docs" / "profiles.md").read_text(encoding="utf-8")
        for name in PROFILE_WORKFLOWS:
            self.assertIn(name, guide)
        for profile in PROFILES:
            with (ROOT / "profiles" / f"{profile}.json").open(encoding="utf-8") as handle:
                descriptor = json.load(handle)
            endpoint = descriptor["topology"]["controlPlaneEndpoint"]
            self.assertEqual(endpoint, {"mode": "vrrp", "port": 6443})
            self.assertIn("last `/24`", readme)
            self.assertIn("last `/24`", guide)
            self.assertIn(".222", readme)
            self.assertIn(".222", guide)
            import_name = "import.yaml" if profile == "full" else f"import.{profile}.yaml"
            raw = (
                "https://raw.githubusercontent.com/Samyazz/zerops-k8s/"
                f"{RECIPE_RELEASE_REF}/{import_name}"
            )
            self.assertIn(raw, readme)
            self.assertIn(raw, guide)
        self.assertNotIn("raw.githubusercontent.com/Samyazz/zerops-k8s/main/", readme)
        self.assertNotIn("raw.githubusercontent.com/Samyazz/zerops-k8s/main/", guide)
        self.assertIn("immutable", readme)
        self.assertIn("immutable", guide)
        self.assertRegex(readme, r"production` is not control-plane HA")
        self.assertIn("not three clusters intended to coexist in one project", guide)

    def test_publication_verifier_is_unauthenticated_and_byte_exact(self):
        verifier = (ROOT / "scripts" / "verify-publication.sh").read_text(
            encoding="utf-8"
        )
        for import_name in (
            "import.yaml",
            "import.production.yaml",
            "import.staging.yaml",
        ):
            self.assertIn(import_name, verifier)
        self.assertIn("raw.githubusercontent.com", verifier)
        self.assertIn("curl -q --proto '=https'", verifier)
        self.assertIn("cmp -s", verifier)
        self.assertIn("RECIPE_RELEASE_REF", verifier)
        self.assertNotIn("Authorization:", verifier)
        self.assertNotRegex(verifier, r"\b(?:TOKEN|PASSWORD|SECRET)=")


if __name__ == "__main__":
    unittest.main()
