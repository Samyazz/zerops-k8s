# Kubernetes on Zerops

This repository is a publishable Zerops recipe and owner-triggered GitHub Actions automation for a full, highly available Kubernetes cluster inside one existing Zerops project. The default topology has six nodes; the resize workflow can add a fourth worker temporarily or permanently.

The design intentionally treats Zerops as the infrastructure layer and Kubernetes as a nested control plane:

- Kubernetes `v1.36.2`: three stacked-etcd control planes and three workers.
- Calico `v3.32.1` with VXLAN networking.
- Istio `v1.30.3` in ambient mode, strict mTLS, and Gateway API ingress.
- Longhorn `v1.12.0`, three storage replicas.
- Headlamp `v0.43.0`, reachable only over the Zerops VPN.
- Grafana Alloy for metrics and OTLP traces; a narrowly scoped Fluent Bit bridge for logs because Zerops' first-class logging backend is ELK rather than Loki.
- Zerops' first-class Prometheus/Grafana and ELK/Kibana/APM recipes. No observability backend runs inside Kubernetes.
- Pod Security Admission, secret encryption at rest, Kubernetes auditing, Kubescape reports, and full CNCF conformance.

## Deployment

The repository owner runs **Deploy Zerops Kubernetes** from GitHub's Actions page. It is deliberately `workflow_dispatch` only. The deployment workflow:

1. Uses GitHub concurrency and a Zerops-side repository/run lock.
2. Reconciles and verifies all six node services through the Zerops API: exactly one VM each, dedicated 4-vCPU mode, 8/12 GB RAM, and 20/50 GB disk with fixed minimum and maximum values.
3. Reconciles Zerops' first-class observability recipes in the existing project.
4. Builds the pinned Ubuntu node image and uploads the archive plus checksum to private Zerops object storage.
5. Deploys the node agents and redundant edge proxies through zCLI.
6. Initializes or updates the single repository-managed cluster.
7. Reconciles networking, mesh, storage, dashboard, identity, and telemetry resources.
8. Creates and verifies etcd and Longhorn backups in Zerops S3-compatible object storage.
9. Tests the live Zerops resource contract, control-plane failover, actual worker loss and rescheduling, cross-node networking, DNS, ingestion, Kubescape, and optional full CNCF conformance.
10. Stores the admin kubeconfig and four Headlamp role tokens as sensitive Zerops project variables.
11. Leaves a passing cluster running. A failed first deployment resets partial nested infrastructure; a failed reconciliation preserves the existing cluster for diagnosis.

Required repository configuration:

- Secret `ZEROPS_TOKEN`: a Zerops access token able to manage the target project.
- Variable `ZEROPS_PROJECT_ID`: the existing project ID.
- Variable `ZEROPS_CLIENT_ID`: the owning Zerops client/team ID.

The workflow uses no third-party Actions. GitHub-owned Actions are pinned to full commit SHAs; every other operation is shell plus the Zerops API/zCLI.

## Operations workflows

All cluster-changing workflows share one GitHub concurrency group and verify the Zerops-side repository lock, so a backup, deployment, resize, maintenance roll, or destroy cannot race another operation.

- **Back up Zerops Kubernetes** runs every six hours or on demand. It creates a consistent etcd snapshot and Longhorn system/volume backups in `k8sbackups`, then downloads and checksum-verifies the new etcd object and proves the Longhorn S3 prefix is populated.
- **Roll Zerops Kubernetes nodes and add-ons** runs weekly or on demand. It requires a successful pre-update backup, drains and rolls workers before control planes one at a time, waits for Longhorn health between disruptions, reconciles pinned add-ons, and runs acceptance checks. It does not silently change the pinned Kubernetes version.
- **Resize Zerops Kubernetes** runs on demand. It safely changes the fixed dedicated CPU/RAM/disk contract one node at a time and scales between three and four workers. Disk can grow but cannot shrink; scale-in drains workloads and evicts Longhorn replicas before deleting worker four.
- **Destroy Zerops Kubernetes** is the explicit teardown and cleanup-recovery path.

The backup, rolling-maintenance, vertical up/down, and horizontal up/down paths have each completed successfully against the live project. Sanitized evidence is retained as a GitHub artifact for one day.

## Recipe import

[`import.yaml`](import.yaml) is the publishable topology. It uses generated secret expressions and contains no credential material. Runtime services start without code because the GitHub workflow owns ordered deployment and validation. [`zerops.yaml`](zerops.yaml) defines node, edge, Prometheus, and Grafana lifecycles.

For an existing project, the workflow uses the first-class recipe endpoints and [`infrastructure/observability.import.yaml`](infrastructure/observability.import.yaml) only as the official-service fallback.

## Access

- Kubernetes API: `https://k8sedge.zerops:6443` while connected to the Zerops VPN.
- Headlamp: `http://k8sedge:18081` while connected to the Zerops VPN.
- Application ingress: `http://k8sedge:8080` over the Zerops VPN. Public exposure is intentionally omitted so enabling one outer subdomain cannot accidentally expose the API or Headlamp ports; publish applications through a separate HTTP-only Zerops edge if needed.
- Grafana and Kibana: their Zerops service pages/subdomains and Zerops-generated credentials.
- Kubeconfig and Headlamp credentials: sensitive Zerops project variables suffixed with `RUN_<GitHub run ID>`. The project tag `zerops-k8s.run` identifies the current set; decode `K8S_ADMIN_KUBECONFIG_B64_RUN_<ID>` before use.

See [operations](docs/operations.md), [upgrades](docs/upgrades.md), [disaster recovery](docs/disaster-recovery.md), [troubleshooting](docs/troubleshooting.md), [security](docs/security.md), and [costs](docs/costs.md).

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).
