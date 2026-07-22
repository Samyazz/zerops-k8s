# Kubernetes on Zerops

This repository is a publishable Zerops recipe and owner-triggered GitHub Actions automation for running upstream Kubernetes inside one Zerops project. It offers three mutually exclusive profiles. `full` remains the backward-compatible default.

| Profile | Zerops services | Kubernetes add-ons | Intended use |
|---|---|---|---|
| `full` | 3 control planes, 3 workers, redundant edge, backup storage, Grafana/Prometheus and ELK/APM services | Calico, Istio ambient, Gateway API, Longhorn, cert-manager, Headlamp, metrics and telemetry collectors | Proper production demonstration with HA control plane and the complete operational stack |
| `production` | 1 control plane, 2 workers, redundant edge, backup storage | Calico, Traefik Gateway API, Longhorn and metrics-server | Compact production with redundant workers and Zerops platform observability only |
| `staging` | 1 control plane, 1 worker, redundant DSR/HAProxy edge | Calico, Traefik Gateway API and metrics-server | Minimal, disposable stage with no storage or observability service |

All profiles use the pinned Kubernetes and add-on versions in [`versions.env`](versions.env), encrypted Kubernetes Secrets, audit logging, Pod Security Admission, least-privilege RBAC, NetworkPolicy defaults, resource-bounded demonstration workloads, and Kubescape reporting.

`production` is not control-plane HA. If its sole control plane is unavailable, the Kubernetes API and etcd are unavailable until that node recovers. Existing worker workloads can continue, but scheduling and reconciliation stop. Choose `full` when control-plane quorum and failover are requirements. `staging` is intentionally non-HA and has no off-node backup.

## Deployment

Run **Deploy Zerops Kubernetes** from the repository's Actions page and select `profile`. The default is `full`, preserving existing callers. Deployment is manual and repository-owner-only. It uses the reusable workflow in [`.github/workflows/reusable-deploy.yml`](.github/workflows/reusable-deploy.yml), with no third-party Actions and GitHub-owned Actions pinned to full commit SHAs.

The workflow acquires the repository-wide GitHub concurrency lock and the Zerops repository/profile lock, validates the selected profile before any mutation, reconciles its exact service inventory, deploys the nested cluster, runs profile-appropriate acceptance tests, and retains sanitized evidence for one day. A same-profile run reconciles in place. A profile change is a deliberate clean replacement; it never attempts to shrink a three-member etcd cluster into one member in place.

Required repository configuration:

- Secret `ZEROPS_TOKEN`: a Zerops access token able to manage the target project.
- Variable `ZEROPS_PROJECT_ID`: the existing project ID.
- Variable `ZEROPS_CLIENT_ID`: the owning Zerops client/team ID.
- Variable `K8S_PROFILE`: the profile used by scheduled backup and maintenance jobs; it defaults to `full` when absent. Keep it equal to the live profile.
- Variable `K8S_RECOVERY_AGE_RECIPIENT`: the public X25519 recipient produced by `age-keygen`; required by `full` and `production` backup paths.
- Secret `K8S_RECOVERY_AGE_IDENTITY`: the matching private age identity, used by recovery drills. Keep an offline copy outside Zerops and GitHub.

Full CNCF conformance is mandatory for `full`. It is opt-in for `production` and `staging`; uncheck `run_full_conformance` for their normal Sonobuoy-quick-plus-functional and functional-smoke gates, respectively.

## Operations workflows

Every cluster-changing workflow accepts `profile`, defaults to `full`, shares `zerops-k8s-${{ github.repository }}` concurrency, and validates the profile or capability before installing tools, authenticating, or changing state.

| Workflow | `full` | `production` | `staging` |
|---|---|---|---|
| Deploy/reconcile | Supported | Supported | Supported |
| Destroy | Supported | Supported | Supported |
| Rolling maintenance | Workers, then three control planes; backup and storage health gates | Workers, then sole control plane; backup and storage health gates; expected API interruption | Worker and sole control plane restart/recovery; expected outage; no backup/storage gates |
| Controlled upgrade | Supported; full conformance default | Supported; API interruption during the sole-control-plane step | Supported; fixed two-node topology and no backup path |
| Vertical resize | Supported within the profile contract | Supported within the profile contract | Supported within the fixed two-node contract |
| Horizontal worker resize | 3 to 4 workers | 2 to 3 workers | Unsupported; rejected before mutation |
| Backup | Etcd identity plus Longhorn to `k8sbackups` | Etcd identity plus Longhorn to `k8sbackups` | Unsupported; rejected before mutation |
| Restore drill | Etcd and Longhorn isolated restore | Etcd and Longhorn isolated restore | Unsupported; rejected before mutation |

For scheduled jobs, set repository variable `K8S_PROFILE` to the live profile. Manual dispatch inputs override that variable. Supplying an unsupported combination—for example `staging` backup, restore, or a worker count other than one—fails before a Zerops login or any infrastructure mutation.

See [operations](docs/operations.md), [upgrades](docs/upgrades.md), [disaster recovery](docs/disaster-recovery.md), [troubleshooting](docs/troubleshooting.md), [security](docs/security.md), and [costs](docs/costs.md).

## Recipe import and publishing

The imports are alternatives, not services to import side-by-side. Use exactly one topology per project:

- [`import.yaml`](import.yaml) / [raw full import](https://raw.githubusercontent.com/Samyazz/zerops-k8s/0f3ddf700174be7cb71b158317b51151db4de6cf/import.yaml)
- [`import.production.yaml`](import.production.yaml) / [raw compact-production import](https://raw.githubusercontent.com/Samyazz/zerops-k8s/0f3ddf700174be7cb71b158317b51151db4de6cf/import.production.yaml)
- [`import.staging.yaml`](import.staging.yaml) / [raw minimal-staging import](https://raw.githubusercontent.com/Samyazz/zerops-k8s/0f3ddf700174be7cb71b158317b51151db4de6cf/import.staging.yaml)

The raw links use the exact immutable commit that passed static, live backup,
and evidence-safety acceptance. A release tag is only a human-friendly alias;
published imports remain pinned to the full commit SHA. Paste one raw file into
**Import a project** in the Zerops dashboard, or download it and run
`zcli project project-import FILE`. To operate in the existing project, use the
profile-aware deployment workflow; do not paste a second profile import over a
running cluster. See [profile and publishing details](docs/profiles.md).

[`zerops.yaml`](zerops.yaml) defines the shared node and HAProxy edge build/run setups. Zerops supplies `_dsr.k8sedge.zerops` as the stable in-project service address and distributes connections over two edge containers in every profile. HAProxy then selects only healthy kube-apiserver backends using native TLS `/readyz` checks. Zerops VPN currently resolves the DSR name but refuses its TCP path, so generated kubeconfigs use the same two-replica HAProxy service through `k8sedge.zerops`; clean-room acceptance separately proves the VPN endpoint and the in-project DSR endpoint. The public imports contain no cluster credential values; the deployment workflow generates them locally and stores them as sensitive Zerops project secrets before any node code is deployed.

## Access

Connect the Zerops VPN before using private cluster endpoints.

| Surface | `full` | `production` | `staging` |
|---|---|---|---|
| Kubernetes API over Zerops VPN | `https://k8sedge.zerops:6443` | `https://k8sedge.zerops:6443` | `https://k8sedge.zerops:6443` |
| Kubernetes API from project services (DSR) | `https://_dsr.k8sedge.zerops:6443` | `https://_dsr.k8sedge.zerops:6443` | `https://_dsr.k8sedge.zerops:6443` |
| Application ingress | `http://k8sedge.zerops:8080` | `http://k8sedge.zerops:8080` | `http://k8sedge.zerops:8080` |
| Edge health | `http://k8sedge.zerops:18082/healthz` | `http://k8sedge.zerops:18082/healthz` | `http://k8sedge.zerops:18082/healthz` |
| Headlamp | `http://k8sedge.zerops:18081` | Not installed | Not installed |
| Grafana/Kibana | Their Zerops service pages and enabled subdomains | Not installed | Not installed |
| Platform logs/statistics | Zerops service detail for every outer runtime | Zerops service detail for all four runtimes and backup storage health/quota | Zerops service detail for both nodes and the edge runtime |

The API and Headlamp are VPN-only. Public application routing is deliberately not enabled by the recipe. Retrieve the admin kubeconfig and, for `full`, role-specific Headlamp tokens from sensitive Zerops project variables for the current successful GitHub run. Never put them in repository files or Action artifacts.

The `_dsr` label is a Zerops-reserved private DNS name. kubeadm applies RFC-1123 validation and cannot accept that label directly in `controlPlaneEndpoint` or `apiServer.certSANs`; the node agent therefore gives kubeadm the ordinary `k8sedge.zerops` service name and atomically extends each generated kube-apiserver certificate with the exact `_dsr.k8sedge.zerops` SAN. The same certificate validates both endpoint names, and the generated VPN kubeconfig needs no `tls-server-name` override.

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).
