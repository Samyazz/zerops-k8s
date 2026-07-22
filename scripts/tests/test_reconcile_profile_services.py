import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReconcileProfileServicesFixtureTests(unittest.TestCase):
    def test_apply_preserves_unrelated_services_and_cleans_failed_import_before_retry(self):
        desired = [
            "k8scp1", "k8sworker1", "k8sworker2", "k8sedge", "k8sbackups",
        ]
        initial = [
            "k8scp1", "k8sworker1", "k8sedge", "k8sbackups",
            "k8scp2", "grafana", "zcp",
        ]

        with tempfile.TemporaryDirectory() as temporary:
            environment, state_path, project_path, event_path = self._fixture(
                Path(temporary),
                initial,
                [
                    "zerops-k8s.state=destroyed",
                    "zerops-k8s.repository=Samyazz/zerops-k8s",
                ],
                fail_first_import=True,
            )
            environment["TRACK_RECONCILE_CREATED"] = "true"
            result = subprocess.run(
                ["bash", "scripts/reconcile-profile-services.sh", "apply"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            final = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(
                sorted(item["name"] for item in final["list"]),
                sorted(desired + ["zcp"]),
            )
            events = event_path.read_text(encoding="utf-8").splitlines()
            self.assertIn("delete:k8scp2", events)
            self.assertIn("delete:grafana", events)
            self.assertNotIn("delete:zcp", events)

            tracking = next(
                index for index, event in enumerate(events)
                if event.startswith("project-put:")
                and "zerops-k8s.reconcile-created=k8sworker2" in event
            )
            failed = events.index("import-failed")
            self.assertLess(tracking, failed, "creation ownership was not recorded before import")
            deleted = events.index("delete:k8sworker2", failed)
            succeeded = events.index("import-succeeded", deleted)
            absence_checks = [
                index for index, event in enumerate(events)
                if deleted < index < succeeded
                and event.startswith("inventory:")
                and "k8sworker2" not in event.split(":", 1)[1].split(",")
            ]
            self.assertTrue(
                absence_checks,
                "the failed service was retried before an inventory read proved deletion",
            )
            project = json.loads(project_path.read_text(encoding="utf-8"))
            self.assertIn(
                "zerops-k8s.reconcile-created=k8sworker2", project["tagList"]
            )

    def test_failed_reconcile_cleanup_removes_only_services_created_by_that_attempt(self):
        preexisting = ["k8scp1", "k8sworker1", "k8sbackups", "zcp"]
        newly_created = ["k8sworker2", "k8sedge"]
        with tempfile.TemporaryDirectory() as temporary:
            environment, state_path, project_path, event_path = self._fixture(
                Path(temporary),
                [*preexisting, *newly_created],
                [
                    "zerops-k8s.state=running",
                    "zerops-k8s.repository=Samyazz/zerops-k8s",
                    "zerops-k8s.run=prior-successful-run",
                    "zerops-k8s.operation=reconcile",
                    "zerops-k8s.attempt=run-42",
                    f"zerops-k8s.reconcile-created={'.'.join(newly_created)}",
                ],
            )
            environment["GITHUB_RUN_ID"] = "run-42"
            result = subprocess.run(
                ["bash", "scripts/cleanup-failed-run.sh"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            final = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(
                sorted(item["name"] for item in final["list"]), sorted(preexisting)
            )
            events = event_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                [event for event in events if event.startswith("delete:")],
                [f"delete:{service}" for service in newly_created],
            )
            project = json.loads(project_path.read_text(encoding="utf-8"))
            self.assertIn("zerops-k8s.state=reconcile-failed", project["tagList"])
            self.assertIn("zerops-k8s.reconcile-created=none", project["tagList"])
            self.assertIn("zerops-k8s.attempt=complete", project["tagList"])

            state_after_first = state_path.read_text(encoding="utf-8")
            project_after_first = project_path.read_text(encoding="utf-8")
            events_after_first = event_path.read_text(encoding="utf-8")
            second = subprocess.run(
                ["bash", "scripts/cleanup-failed-run.sh"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertIn("cleanup skipped", second.stdout)
            self.assertEqual(state_path.read_text(encoding="utf-8"), state_after_first)
            self.assertEqual(project_path.read_text(encoding="utf-8"), project_after_first)
            self.assertEqual(event_path.read_text(encoding="utf-8"), events_after_first)

    def test_targeted_delivery_deploys_only_new_node_and_edge_runtimes(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            bin_path = temporary_path / "bin"
            bin_path.mkdir()
            calls_path = temporary_path / "zcli-calls.log"
            calls_path.write_text("", encoding="utf-8")
            self._write_executable(
                bin_path / "zcli",
                """
                #!/usr/bin/env bash
                set -Eeuo pipefail
                if [[ ${1:-} == project && ${2:-} == env ]]; then
                  exit 0
                fi
                printf '%s\\n' "$*" >>"$FIXTURE_ZCLI_CALLS"
                [[ ${1:-} == service && ${2:-} == deploy ]]
                """,
            )

            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            ).stdout.strip()
            runner_temp = temporary_path / "runner"
            artifact = runner_temp / f"zerops-k8s-agent-{revision[:12]}" / "runtime"
            (artifact / "dist").mkdir(parents=True)
            self._write_executable(artifact / "dist" / "zerops-k8s", "#!/bin/sh\nexit 0\n")
            self._write_executable(artifact / "s3-fetch", "#!/bin/sh\nexit 0\n")
            go_bin = runner_temp / "zerops-k8s-go-1.22.12" / "bin" / "go"
            go_bin.parent.mkdir(parents=True)
            self._write_executable(
                go_bin,
                "#!/bin/sh\nprintf 'go version go1.22.12 linux/amd64\\n'\n",
            )

            environment = {
                **os.environ,
                "PATH": f"{bin_path}:{os.environ['PATH']}",
                "K8S_PROFILE": "production",
                "ZEROPS_PROJECT_ID": "test-project",
                "RECONCILE_EXISTING": "true",
                "TARGET_RUNTIME_SERVICES": "k8sworker2.k8sedge.k8sbackups",
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_SHA": revision,
                "GITHUB_RUN_ID": "run-42",
                "FIXTURE_ZCLI_CALLS": str(calls_path),
            }
            result = subprocess.run(
                ["bash", "scripts/build-and-deploy.sh"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = calls_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(calls), 2, calls)
            self.assertTrue(any("service deploy k8sworker2 " in call for call in calls))
            self.assertTrue(any("--setup worker2-production" in call for call in calls))
            self.assertTrue(any("service deploy k8sedge " in call for call in calls))
            self.assertTrue(any("--setup edge-production" in call for call in calls))
            for untouched in ("k8scp1", "k8sworker1", "k8sbackups"):
                self.assertFalse(any(f"service deploy {untouched} " in call for call in calls))

    def test_deploy_and_cleanup_share_the_same_attempt_owned_service_set(self):
        deploy = (ROOT / "scripts" / "deploy.sh").read_text(encoding="utf-8")
        delivery = (ROOT / "scripts" / "build-and-deploy.sh").read_text(encoding="utf-8")
        cleanup = (ROOT / "scripts" / "cleanup-failed-run.sh").read_text(encoding="utf-8")
        record = deploy.index("reconcile_created_services=$(cluster_tag_value reconcile-created)")
        target = deploy.index('TARGET_RUNTIME_SERVICES="$reconcile_created_services"', record)
        targeted_build = deploy.index('"$ROOT_DIR/scripts/build-and-deploy.sh"', target)
        self.assertLess(record, target)
        self.assertLess(target, targeted_build)
        self.assertIn(
            "in-place reconciliation requires an explicit TARGET_RUNTIME_SERVICES ownership set",
            delivery,
        )
        self.assertIn('reconcile-profile-services.sh" cleanup-created', cleanup)

    def test_cleanup_created_fails_closed_for_an_unrecognized_service(self):
        initial = ["k8scp1", "zcp"]
        with tempfile.TemporaryDirectory() as temporary:
            environment, state_path, _, event_path = self._fixture(
                Path(temporary),
                initial,
                ["zerops-k8s.reconcile-created=zcp"],
            )
            result = subprocess.run(
                ["bash", "scripts/reconcile-profile-services.sh", "cleanup-created"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to delete unrecognized", result.stderr)
            final = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(
                sorted(item["name"] for item in final["list"]), sorted(initial)
            )
            events = event_path.read_text(encoding="utf-8").splitlines()
            self.assertFalse(any(event.startswith("delete:") for event in events))

    def _fixture(self, temporary_path, initial_services, tags, fail_first_import=False):
        bin_path = temporary_path / "bin"
        bin_path.mkdir()
        state_path = temporary_path / "state.json"
        project_path = temporary_path / "project.json"
        event_path = temporary_path / "events.log"
        counter_path = temporary_path / "imports.count"
        state_path.write_text(
            json.dumps({
                "list": [
                    {"name": name, "status": "ACTIVE"}
                    for name in initial_services
                ]
            }),
            encoding="utf-8",
        )
        project_path.write_text(
            json.dumps({
                "name": "fixture",
                "description": "",
                "publicIpV4Shared": True,
                "tagList": tags,
            }),
            encoding="utf-8",
        )
        event_path.write_text("", encoding="utf-8")

        self._write_executable(
            bin_path / "curl",
            """
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys

            arguments = sys.argv[1:]
            output = Path(arguments[arguments.index("--output") + 1])
            method = arguments[arguments.index("-X") + 1]
            url = arguments[-1]
            events = Path(os.environ["FIXTURE_EVENTS"])

            def record(value):
                with events.open("a", encoding="utf-8") as handle:
                    handle.write(value + "\\n")

            if "/service-stack?" in url:
                state = json.loads(Path(os.environ["FIXTURE_STATE"]).read_text())
                output.write_text(json.dumps(state))
                names = ",".join(sorted(item["name"] for item in state["list"]))
                record(f"inventory:{names}")
            elif url.endswith("/project/test-project") and method == "GET":
                output.write_text(Path(os.environ["FIXTURE_PROJECT"]).read_text())
            elif url.endswith("/project/test-project") and method == "PUT":
                payload = arguments[arguments.index("--data") + 1]
                Path(os.environ["FIXTURE_PROJECT"]).write_text(payload)
                output.write_text(payload)
                record("project-put:" + payload.replace("\\n", ""))
            else:
                output.write_text("{}")
            print("200", end="")
            """,
        )
        self._write_executable(
            bin_path / "zcli",
            """
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import re
            import sys

            arguments = sys.argv[1:]
            state_path = Path(os.environ["FIXTURE_STATE"])
            events = Path(os.environ["FIXTURE_EVENTS"])
            state = json.loads(state_path.read_text())

            def record(value):
                with events.open("a", encoding="utf-8") as handle:
                    handle.write(value + "\\n")

            if arguments[:2] == ["service", "delete"]:
                name = arguments[2]
                state["list"] = [item for item in state["list"] if item["name"] != name]
                state_path.write_text(json.dumps(state))
                record(f"delete:{name}")
                raise SystemExit(0)

            if arguments[:2] == ["project", "service-import"]:
                import_path = Path(arguments[2])
                names = re.findall(
                    r"^  - hostname: ([a-z0-9]+)$",
                    import_path.read_text(),
                    re.MULTILINE,
                )
                counter_path = Path(os.environ["FIXTURE_IMPORT_COUNTER"])
                count = int(counter_path.read_text()) if counter_path.exists() else 0
                counter_path.write_text(str(count + 1))
                state["list"] = [item for item in state["list"] if item["name"] not in names]
                should_fail = os.environ["FIXTURE_FAIL_FIRST_IMPORT"] == "true" and count == 0
                status = "ACTION_FAILED" if should_fail else "ACTIVE"
                state["list"].extend({"name": name, "status": status} for name in names)
                state_path.write_text(json.dumps(state))
                record("import-failed" if should_fail else "import-succeeded")
                raise SystemExit(1 if should_fail else 0)

            record("unexpected-zcli:" + " ".join(arguments))
            raise SystemExit(2)
            """,
        )
        self._write_executable(bin_path / "sleep", "#!/bin/sh\nexit 0\n")

        environment = {
            **os.environ,
            "PATH": f"{bin_path}:{os.environ['PATH']}",
            "K8S_PROFILE": "production",
            "ZEROPS_TOKEN": "fixture-token",
            "ZEROPS_PROJECT_ID": "test-project",
            "GITHUB_REPOSITORY": "Samyazz/zerops-k8s",
            "GITHUB_RUN_ID": "fixture-run",
            "FIXTURE_STATE": str(state_path),
            "FIXTURE_PROJECT": str(project_path),
            "FIXTURE_EVENTS": str(event_path),
            "FIXTURE_IMPORT_COUNTER": str(counter_path),
            "FIXTURE_FAIL_FIRST_IMPORT": str(fail_first_import).lower(),
        }
        return environment, state_path, project_path, event_path

    @staticmethod
    def _write_executable(path, body):
        path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
