# Kubernetes recipe variants — executable task matrix

Status: implementation plan; no variant has been provisioned by creating this file.  
Repository: `Samyazz/zerops-k8s`  
Target region: EU Central  
Last reviewed: 2026-07-21

## Goal

Add two publishable, first-class Zerops recipe variants to the existing full Kubernetes recipe:

1. `production` — compact production with one control plane, two workers, durable Kubernetes storage/backups, and only Zerops platform observability.
2. `staging` — minimal staging with one control plane, one worker, ingress, and no recipe-owned orbiting services.

Keep the current six-node recipe as `full`, the proper-production/default variant. All three variants must be deployable by the same owner-triggered reusable GitHub Actions workflow into the current Zerops project, but only one repository-managed cluster may exist there at a time.

## How to run this as a goal

Use this objective:

> Implement every unchecked task in `task-matrix.md` in dependency order. Preserve the existing `full` recipe as the default, add the `production` and `staging` variants exactly as specified, validate all profiles, commit and push the work, and do not mutate the live Zerops project unless `LIVE_ACCEPTANCE=true` is explicitly included in the goal.

Execution inputs:

| Input | Allowed values | Default | Meaning |
|---|---|---:|---|
| `K8S_PROFILE` | `full`, `production`, `staging` | `full` | Variant selected by deploy/maintenance workflows. |
| `LIVE_ACCEPTANCE` | `true`, `false` | `false` | Permits destructive clean-room testing in the current project. |
| `FINAL_PROFILE` | `full`, `production`, `staging` | `production` | Profile left running after live acceptance. |
| `RUN_FULL_CONFORMANCE` | `true`, `false` | `false` for new variants | Full CNCF suite remains mandatory for `full`; it is optional for the smaller tiers. |

Rules for the executing agent:

- Change `[ ]` to `[x]` only after the deliverable and its acceptance check both pass.
- Do not mark the goal complete with failed, partially created, or undeleted recipe-owned Zerops services.
- Treat live profile changes as destructive. Before live acceptance, acquire both locks, prove a fresh recovery point when the source profile supports backups, and record the exact source and target profiles.
- A same-profile run reconciles in place. A profile change performs an intentional clean replacement; it must not try to shrink a three-member etcd control plane into one member in place.
- Preserve unrelated project services, including `zcp`, and preserve the Zerops project core. “Exact service inventory” below means exact recipe-owned services.
- Never commit credentials, kubeconfigs, tokens, rendered secrets, or unredacted API responses.
- Keep third-party GitHub Actions prohibited. GitHub-owned Actions remain pinned to full commit SHAs.

## Research basis and Zerops tier mapping

The design follows these current Zerops conventions:

- Standard development recipes use paired `{name}dev` and `{name}stage` runtimes; stage uses the production build/start path at lower scale. Simple recipes use one self-deployed runtime. Production recipes use git-backed builds, health gates, production settings, and redundant runtimes where appropriate.
- Zerops' production guidance recommends Serious Core, dedicated CPU, multiple application containers, health checks, and removal of development-only helpers. Staging/development favors Lightweight Core, shared CPU, and one container.
- Every Zerops project core already includes logger and statistics services. The two new variants use that platform visibility and deliberately do not deploy Grafana, Prometheus, ELK, Loki, Tempo, APM Server, Alloy, Fluent Bit, kube-state-metrics, or node-exporter.
- Mature Zerops recipes commonly keep a normal import and a separate production import. This repository keeps its existing root `import.yaml` as the stable full/default entry point and adds two explicit sibling entry points.
- Ingress-NGINX was retired in March 2026. The new variants therefore use the standard Kubernetes Gateway API with a pinned Traefik controller, not ingress-nginx.

Primary references:

- [Zerops project cores and built-in logger/statistics](https://docs.zerops.io/features/infrastructure)
- [Zerops scaling presets](https://docs.zerops.io/guides/scaling)
- [Zerops development/stage lifecycle](https://docs.zerops.io/features/coding-agents)
- [Official recipe normal import](https://github.com/zeropsio/recipe-laravel-jetstream/blob/main/zerops-project-import.yml)
- [Official recipe production import](https://github.com/zeropsio/recipe-laravel-jetstream/blob/main/zerops-project-production-import.yml)
- [Kubernetes Ingress-NGINX retirement notice](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Traefik Gateway API provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)

This is an infrastructure recipe rather than a normal application recipe. It therefore maps the Zerops tiers to mutually exclusive cluster topologies instead of putting dev and stage Kubernetes clusters in the same project:

| Zerops-style tier | Repository profile | Entry point | Role |
|---|---|---|---|
| Proper production | `full` | `import.yaml` | Existing 3-control-plane, 3-worker experience with the complete operational and observability stack. |
| Simple production | `production` | `import.production.yaml` | New 1-control-plane, 2-worker compact production cluster. |
| Stage | `staging` | `import.staging.yaml` | New disposable 1-control-plane, 1-worker cluster with only essential add-ons. |

## Non-negotiable profile contracts

### Cross-profile invariants

- Kubernetes version, node image, CNI, chart versions, and image digests remain pinned in `versions.env` or an equally reviewable profile manifest.
- Kubernetes API access is VPN-only. Only application ingress may use Zerops HTTP routing.
- Kubernetes Secrets remain encrypted at rest with the key supplied through Zerops project/service secrets.
- Pod Security Admission, least-privilege RBAC, NetworkPolicy defaults, API audit policy, token/header/cookie redaction, and Kubescape reporting remain enabled without installing a permanent security platform.
- All recipe-managed application/add-on pods define non-zero CPU and memory requests and finite limits. Privileged/system DaemonSets must be explicit exceptions.
- The GitHub concurrency lock and Zerops repository/profile tags prevent simultaneous cluster operations.
- Switching profile records `zerops-k8s.profile=<profile>` and retains the repository ownership tag.
- Failed or canceled creation removes the partial nested cluster and every failed/partial service created by that run before retrying. A failed cleanup sets `cleanup-failed` and blocks later deployments.
- Public recipe files contain generated secret expressions or references only; no secret material is stored in git.

### Topology and feature matrix

| Capability | `full` (existing) | `production` (new) | `staging` (new) |
|---|---|---|---|
| Project core for new imports | Serious | Serious | Lightweight |
| Control planes | 3 | 1 | 1 |
| Workers | 3, optionally 4 | 2, optionally 3 | 1, fixed |
| Stable outer edge | 2 `k8sedge` containers | 2 `k8sedge` containers | None; direct node endpoints |
| CNI / DNS | Calico / CoreDNS | Calico / CoreDNS | Calico / CoreDNS |
| Ingress | Istio Gateway API | Traefik Gateway API, 2 replicas | Traefik Gateway API, 1 replica |
| Service mesh | Istio ambient | None | None |
| Dynamic storage | Longhorn, 3 replicas | Longhorn, 2 replicas | None |
| Off-node backups | Zerops S3: etcd + Longhorn | Zerops S3: etcd + Longhorn | None |
| Cluster UI | Headlamp | None | None |
| Metrics API | metrics-server, 2 replicas | metrics-server, 2 replicas | metrics-server, 1 replica |
| Dedicated observability | Grafana/Prometheus + ELK/APM, Alloy/Fluent Bit/exporters | None | None |
| Observability guarantee | Full nested-cluster telemetry | Zerops outer-service logs, health, and resource statistics only | Zerops outer-service logs, health, and resource statistics only |
| Demonstration workload | Existing demo | Resource-bounded, 2 replicas, PDB, spread, HPA | Resource-bounded, 1 replica |
| Conformance default | Full CNCF | Sonobuoy quick + functional suite | Functional smoke suite |
| Control-plane failover | Required | Impossible with one control plane; report planned API outage | Impossible with one control plane; report planned API outage |
| Worker disruption | Required | Required, one worker at a time | Not a HA test; restart/recovery only |

The `production` profile is production-shaped but is not a highly available Kubernetes control plane. Loss or maintenance of `k8scp1` interrupts the API and etcd until it returns. The two workers keep already-running data-plane workloads available when they do not require control-plane decisions. Use `full` when control-plane quorum and control-plane failover are required.

### Exact Zerops service inventory

Platform core services and a pre-existing `zcp` service are outside this inventory and must not be deleted.

| Profile | Required recipe-owned services | Forbidden recipe-owned services |
|---|---|---|
| `full` | Existing inventory in `import.yaml` | No change in this goal. |
| `production` | `k8scp1`, `k8sworker1`, `k8sworker2`, `k8sedge`, `k8sbackups` | `k8scp2`, `k8scp3`, `k8sworker3`, `k8sworker4`, `grafanadb`, `prometheusbackups`, `grafana`, `prometheus`, `elkstorage`, `kibana`, `logstash`, `apmserver` |
| `staging` | `k8scp1`, `k8sworker1` | Every other recipe-owned service, including `k8sedge` and `k8sbackups` |

`production` allows `k8sbackups` as its only durable outer dependency because a one-control-plane production cluster needs an off-node recovery copy. All runtime add-ons stay inside Kubernetes. `staging` has no such exception: node image creation and cluster access must work without object storage or an edge runtime.

### Initial Zerops resource contracts

These are fixed baselines, not autoscaling targets. Disk never shrinks; downsizing below an already allocated disk requires replacement.

| Profile/service | Containers | CPU | RAM | Disk/storage |
|---|---:|---:|---:|---:|
| `production` `k8scp1` | 1 | 4 dedicated | 8 GB | 20 GB |
| `production` each worker | 1 | 4 dedicated | 8 GB | 50 GB |
| `production` `k8sedge` | 2 | 1–2 shared each | 0.5–1 GB each | 1–2 GB each |
| `production` `k8sbackups` | fixed | n/a | n/a | 25 GB initial quota |
| `staging` `k8scp1` | 1 | 2 shared | 4 GB | 20 GB |
| `staging` `k8sworker1` | 1 | 2 shared | 4 GB | 20 GB |

For a new import, `staging` requests Lightweight Core. When deploying into the existing Serious-Core project, the workflow leaves the core unchanged rather than attempting a downgrade.

### In-cluster resource floor

The implementation may tune these after measurement, but it may not omit requests/limits:

| Workload | `production` | `staging` |
|---|---|---|
| Traefik | 2 replicas; request `100m/128Mi`, limit `1/512Mi`; hard topology spread | 1 replica; same per-pod request/limit |
| metrics-server | 2 replicas; request `50m/100Mi`, limit `250m/256Mi` | 1 replica; same per-pod request/limit |
| Demo app | 2 replicas; request `25m/32Mi`, limit `250m/128Mi`; PDB `minAvailable: 1`; HPA 2–6 | 1 replica; same per-pod request/limit; no PDB/HPA |
| Longhorn | Explicit requests/limits for manager, driver, UI-disabled components; two storage replicas | Not installed |
| Workload namespace | `LimitRange` defaults plus `ResourceQuota`: requests `2 CPU/2Gi`, limits `4 CPU/4Gi`, 30 pods | `LimitRange` defaults plus `ResourceQuota`: requests `1 CPU/1Gi`, limits `2 CPU/2Gi`, 15 pods |

## Task matrix

Dependencies refer to task IDs. Tasks within the same dependency level may be implemented together, but acceptance must follow the listed gates.

| Status | ID | Depends on | Task and deliverable | Acceptance gate |
|---|---|---|---|---|
| [x] | R-00 | — | Research Zerops recipe tier, core, scaling, production-import, built-in observability, and current ingress-controller conventions; record the result in this document. | Every research claim above has a primary Zerops, Kubernetes, Traefik, or official recipe reference. |
| [ ] | B-01 | R-00 | Add one validated profile descriptor for `full`, `production`, and `staging`. It is the sole source for nodes, addons, endpoints, backup support, resource contracts, and acceptance level. | A unit/static test rejects unknown profiles and proves the three resolved contracts exactly match the tables above. |
| [ ] | B-02 | B-01 | Replace hard-coded `CONTROL_PLANES`, `WORKERS`, and node/setup lists in shared scripts with values loaded from the descriptor. Preserve `full` as the default. | Existing full-profile tests pass; rendered node order is 3+3, 1+2, and 1+1 respectively. |
| [ ] | B-03 | B-01 | Add `import.production.yaml` and `import.staging.yaml`. Keep `import.yaml` backward compatible and publishable. Add tier tags and mechanism-first comments. | Zerops schema/dry-run validation passes; a secret scan finds no literal credentials; service inventories are exact. |
| [ ] | B-04 | B-01 | Make `zerops.yaml` profile-safe. No setup may contain a cross-service reference to a service absent from that profile. Reuse generic build logic where possible. | Render/deploy validation finds no unresolved `k8sbackups_*`, observability, or secondary-control-plane references. |
| [ ] | B-05 | B-01 | Generalize the edge proxy backends and make Headlamp/unused listeners optional. `full` keeps current defaults; `production` targets one API backend and two Traefik NodePorts. | Go tests cover disabled routes, one API backend, backend failover, readiness, and full-profile compatibility. |
| [ ] | B-06 | B-01 | Add a staging node-image path that builds the pinned node image locally inside each Docker runtime from deployed source. It must not require S3, a release asset, or another Zerops service. | Fresh `staging` node runtimes start with no `k8sbackups_*` variables; the resulting image ID and Kubernetes version match the pinned contract. |
| [ ] | B-07 | B-02, B-03 | Implement exact service reconciliation. Safely retire profile-owned nodes from Kubernetes/etcd/Longhorn before deleting their Zerops services; delete failed/partial target services and wait for deletion before retry. | Fixture/API tests prove unrelated services are untouched, forbidden services are removed, and a stuck failed create cannot be retried until deletion finishes. |
| [ ] | B-08 | B-01 | Split bootstrap into small feature gates (`cni`, `gateway`, `storage`, `platform-observability`, `dashboard`, `demo`, `security`) instead of profile-name conditionals scattered across scripts. | `shellcheck` passes and a dry render lists only the expected feature gates for every profile. |
| [ ] | P-01 | B-03, B-04 | Define compact-production services and secrets: one control plane, two workers, redundant edge, private backup object storage, Serious Core for new imports. | `validate-recipe.sh production` proves exact topology/resources and generated-secret-only configuration. |
| [ ] | P-02 | B-05, B-08 | Bootstrap Calico, standard Gateway API CRDs, pinned Traefik with two replicas, metrics-server with two replicas, and Longhorn with two storage replicas. Omit Istio and cert-manager by default; Zerops terminates public HTTP TLS. | All expected pods are Ready; no Istio/cert-manager namespaces or CRDs exist; Gateway and HTTPRoute are Programmed/Accepted. |
| [ ] | P-03 | P-02 | Apply the shared security baseline: encryption at rest, audit policy/rotation, PSA labels, default-deny NetworkPolicies plus required allows, RBAC, and explicit privileged-system exceptions. | Encryption test cannot find plaintext sentinel in etcd; audit event is emitted; policy-negative tests are denied; Kubescape report is collected. |
| [ ] | P-04 | P-02, P-03 | Add the two-replica demo workload, Service, HTTPRoute, requests/limits, topology spread, PDB, HPA, LimitRange, and ResourceQuota. | Requests through `k8sedge` succeed; replicas occupy different workers; `kubectl top`, HPA metrics, PDB, and quota checks pass. |
| [ ] | P-05 | P-02 | Remove dedicated observability reconciliation from this profile. Emit structured node-agent/edge lifecycle logs and health status to Zerops' normal runtime surfaces. Do not claim nested pod-level telemetry. | No forbidden observability service or collector/exporter pod exists; Zerops API/dashboard evidence shows fresh logs and CPU/RAM statistics for all four runtime services plus health/quota state for `k8sbackups`. |
| [ ] | P-06 | P-02, B-04 | Adapt etcd/identity and Longhorn backup/retention workflows to one control plane, two storage replicas, and `k8sbackups`. Keep redaction and encrypted recovery identity handling. | Fresh etcd and Longhorn backups exist in Zerops S3 and an isolated restore drill verifies both checksums. |
| [ ] | P-07 | P-02, P-06 | Adapt rolling maintenance, upgrade, vertical resize, and horizontal resize. Worker floor is 2 and ceiling is 3. Workers roll before the single control plane; the workflow states that API downtime is expected during control-plane maintenance. | Worker disruption reschedules the demo without ingress loss; scale 2→3→2 passes; vertical up/down passes subject to no disk shrink; upgrade plan and no-op paths pass. |
| [ ] | P-08 | P-03, P-04, P-05, P-06, P-07 | Add compact-production acceptance and evidence collection. Do not run the impossible control-plane failover test. | Exact services, three Ready nodes, DNS, cross-node network, Gateway traffic, storage, backup/restore, worker disruption, platform observability, security, and Sonobuoy quick all pass. |
| [ ] | S-01 | B-03, B-04, B-06 | Define staging services: only `k8scp1` and `k8sworker1`, Lightweight Core for new imports, locally built node images, no S3 and no edge. | `validate-recipe.sh staging` proves exact topology/resources and zero references to absent services. |
| [ ] | S-02 | S-01 | Expose the API as `k8scp1.zerops:6443` over VPN and application ingress through the worker's Traefik NodePort/HTTP port. Set the kubeadm control-plane endpoint per profile. | Kubeconfig reaches `/readyz` through VPN; the ingress smoke URL succeeds; the API port has no public HTTP route. |
| [ ] | S-03 | B-08, S-02 | Bootstrap only Calico, CoreDNS/kube-proxy, standard Gateway API CRDs, one Traefik replica, one metrics-server replica, namespaces, and the shared security baseline. | Expected system pods are Ready; forbidden namespace/CRD checks prove Istio, Longhorn, cert-manager, Headlamp, and observability components are absent. |
| [ ] | S-04 | S-03 | Add the one-replica staging demo workload, Service, HTTPRoute, requests/limits, LimitRange, and ResourceQuota. Do not add HPA or a PDB. | DNS, service networking, ingress, quota, limits, and `kubectl top` smoke tests pass on the single worker. |
| [ ] | S-05 | S-03 | Enforce “no orbiting services” in validation and cleanup. This includes no edge, backup storage, Grafana/Prometheus/ELK/APM, database, cache, or cluster UI service created by the recipe. | Exact Zerops service check passes while a fixture proves a pre-existing unrelated service is preserved. |
| [ ] | S-06 | S-03 | Add staging maintenance behavior: restart/recover the worker and control plane, plan upgrades, and allow fixed vertical resizing. Disable backup, restore, horizontal resize, storage-health, and HA-disruption jobs with an explicit explanation. | Supported operations pass; unsupported operations fail before mutation with a clear profile capability message. |
| [ ] | S-07 | S-02, S-04, S-05, S-06 | Add staging acceptance and evidence collection. | Exact services, two Ready nodes, DNS, pod networking, Gateway traffic, platform service logs/stats, security checks, and stop/start recovery pass. Forbidden-component evidence is included. |
| [ ] | W-01 | B-01, B-02 | Add a validated `profile` input to reusable deploy, deploy, destroy, maintenance, upgrade, resize, backup, and restore workflows as applicable. Keep `full` as the backward-compatible default, manual owner-only deployment, and repository-wide concurrency. | Workflow lint/tests prove `full` defaults are unchanged and profile capabilities gate every operation before mutation. |
| [ ] | W-02 | B-07, W-01 | Implement profile switching as backup → nested-cluster teardown → retired-service cleanup → target reconciliation → deploy → acceptance. Never mutate etcd membership from 3 to 1 in place. | Simulated transitions for all profile pairs have deterministic plans and no service deletion outside repository ownership. |
| [ ] | W-03 | B-07, W-01 | Make cancellation/failure cleanup profile-aware and idempotent. A failed clean creation is destroyed; a failed same-profile reconciliation preserves the last healthy cluster unless it created partial services. | Repeated cleanup tests converge; cleanup failure sets the blocking project tag; a later explicit destroy clears it only after verification. |
| [ ] | W-04 | P-08, S-07, W-01 | Produce short-lived sanitized evidence with profile, resolved contract, exact service list, Kubernetes inventory, functional results, forbidden-component checks, and backup results when supported. | Artifact contains no secrets and uses one-day retention; a redaction test covers tokens, auth headers, cookies, emails, and IP addresses. |
| [ ] | D-01 | P-08, S-07 | Update README and architecture, operations, upgrades, recovery, security, troubleshooting, and cost documentation with a three-profile comparison and limitations. | Every workflow/profile combination and every access URL is documented; `production` is never described as control-plane HA. |
| [ ] | D-02 | B-03, D-01 | Add first-class recipe publishing notes and direct import links for all three entry points. Explain that profile imports are alternative topologies, not simultaneous clusters. | Links resolve at the pushed commit and recipe descriptions match the exact inventories. |
| [ ] | Q-01 | B-01 through W-04 | Add shell/Go/Python tests and fixtures for profile rendering, edge routing, service pruning, forbidden references, workflow capability gates, and evidence redaction. | `go test ./...`, `go vet ./...`, Python tests, `shellcheck scripts/*.sh`, workflow lint, and `git diff --check` pass. |
| [ ] | Q-02 | Q-01, D-02 | Run static clean-room validation for every import and workflow without changing Zerops. | All three imports validate, all manifests render server-side/dry-run against the supported Kubernetes version, and the repository is clean after the commit. |
| [ ] | L-01 | Q-02 | Only when `LIVE_ACCEPTANCE=true`: preserve a fresh recovery point for the current live profile, switch to `staging`, deploy from clean state, run `S-07`, archive sanitized evidence, then destroy staging. | Staging run is green and no staging recipe-owned service remains after teardown. |
| [ ] | L-02 | L-01 | Deploy `production` from clean state, run `P-08`, including backup/restore and worker disruption, and archive sanitized evidence. | Production run is green, exact service inventory passes, no failed/partial service exists, and the cluster remains running if `FINAL_PROFILE=production`. |
| [ ] | L-03 | L-02 | If `FINAL_PROFILE` is not `production`, cleanly switch to the requested final profile and run its acceptance level before handoff. | Final repository/profile tags, service inventory, Ready nodes, access endpoints, and latest backup status match the chosen profile. |

## Profile-specific acceptance commands and evidence

The implementation may wrap these in scripts, but the evidence must preserve their meaning and redact sensitive values.

### Common

- Validate the selected import and resolved service/resource contract.
- Query Zerops for exact recipe-owned services and assert there are no failed, creating, deleting, or orphaned services.
- `kubectl get --raw=/readyz`
- `kubectl wait --for=condition=Ready nodes --all --timeout=20m`
- `kubectl get pods -A -o wide` with every expected workload Ready/Completed.
- DNS and cross-node/single-node service tests as appropriate to the profile.
- Gateway/HTTPRoute status plus an HTTP request through the profile's ingress endpoint.
- API audit sentinel, encryption-at-rest sentinel, RBAC checks, PSA-negative tests, NetworkPolicy tests, and Kubescape report.
- Zerops runtime health, fresh structured log, and CPU/RAM-statistics evidence for every recipe-owned runtime service.
- Negative inventory assertions for every excluded service, namespace, CRD, and Helm release.

### `production`

- Assert exactly one control plane and two workers before optional resize tests.
- Assert the demo replicas and Traefik replicas are spread across both workers.
- Stop one worker, prove ingress remains available and the demo reschedules, restore it, and wait for Longhorn health.
- Create/verify fresh etcd and Longhorn backups, then complete the isolated restore drill.
- Run Sonobuoy quick mode by default; run full certified-conformance only when requested.
- Report the single-control-plane outage limitation instead of attempting a fake failover test.

### `staging`

- Assert exactly one control plane and one worker and no other recipe-owned Zerops service.
- Prove node images were built locally without S3 variables.
- Restart and recover each node separately; an outage during either restart is expected and must be reported.
- Run functional networking/DNS/ingress/security smoke tests only.
- Prove backup, restore, storage, horizontal-resize, mesh, and dedicated-observability operations are disabled before mutation.

## Profile switching and data policy

| Transition | Required handling |
|---|---|
| Same profile → same profile | Reconcile in place; preserve cluster data and identity. |
| `full` → `production` | Fresh full backup, destroy nested cluster, remove extra control planes/workers and full observability services, create compact cluster, restore application data only when explicitly compatible. |
| `production` → `full` | Fresh compact backup, destroy nested cluster, add HA nodes/full services, create full cluster, restore supported data, run full acceptance. |
| Any profile → `staging` | Treat staging as disposable. Preserve source backups when available, then create staging without importing production credentials or data by default. |
| `staging` → another profile | Destroy staging; there is no guaranteed durable staging state to migrate. |

The node image is an implementation artifact, not user data. `production` and `full` may cache it in `k8sbackups`; `staging` rebuilds it locally. Application data migration is outside automatic profile switching unless a separately reviewed restore input explicitly requests it.

## Definition of done

The implementation goal is complete only when:

- All non-live tasks through `Q-02` are checked, committed, and pushed.
- `import.yaml` still deploys the existing full profile by default.
- The two new import entry points are publishable, documented, and free of secrets.
- Static validation proves the exact topology, resource, feature, and exclusion contracts for all three profiles.
- Every workflow rejects unsupported operations before changing state.
- No credentials or sensitive evidence are tracked by git.
- If the goal was invoked with `LIVE_ACCEPTANCE=true`, `L-01` through the applicable final-profile task are checked and the final live state has no failed/partial services.
- The handoff states which profile is live, its access endpoints, limitations, latest backup/restore result, commit SHA, and GitHub workflow run URLs.
