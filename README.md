# Kubernetes on Zerops

This repository is a publishable Zerops recipe and an owner-triggered GitHub Actions deployment for a full six-node, highly available Kubernetes cluster inside one existing Zerops project.

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
2. Reconciles Zerops' first-class observability recipes in the existing project.
3. Builds the pinned Ubuntu node image and uploads the archive plus checksum to private Zerops object storage.
4. Deploys the node agents and redundant edge proxies through zCLI.
5. Initializes or updates the single repository-managed cluster.
6. Reconciles networking, mesh, storage, dashboard, identity, and telemetry resources.
7. Tests control-plane failover, actual worker loss and rescheduling, cross-node networking, DNS, ingestion, Kubescape, and full CNCF conformance.
8. Stores the admin kubeconfig and four Headlamp role tokens as secret variables on `k8scp1` in Zerops.
9. Leaves a passing cluster running. A failing or canceled run resets partial nested infrastructure.

Required repository configuration:

- Secret `ZEROPS_TOKEN`: a Zerops access token able to manage the target project.
- Variable `ZEROPS_PROJECT_ID`: the existing project ID.
- Variable `ZEROPS_CLIENT_ID`: the owning Zerops client/team ID.

The workflow uses no third-party Actions. GitHub-owned Actions are pinned to full commit SHAs; every other operation is shell plus the Zerops API/zCLI.

## Recipe import

[`import.yaml`](import.yaml) is the publishable topology. It uses generated secret expressions and contains no credential material. Runtime services start without code because the GitHub workflow owns ordered deployment and validation. [`zerops.yaml`](zerops.yaml) defines node, edge, Prometheus, and Grafana lifecycles.

For an existing project, the workflow uses the first-class recipe endpoints and [`infrastructure/observability.import.yaml`](infrastructure/observability.import.yaml) only as the official-service fallback.

## Access

- Kubernetes API: `https://k8sedge:6443` while connected to the Zerops VPN.
- Headlamp: `http://k8sedge:18081` while connected to the Zerops VPN.
- Application ingress: the Zerops subdomain of `k8sedge`, which terminates public TLS before forwarding to Gateway API on port 8080.
- Grafana and Kibana: their Zerops service pages/subdomains and Zerops-generated credentials.
- Kubeconfig and Headlamp credentials: sensitive Zerops project variables suffixed with `RUN_<GitHub run ID>`. The project tag `zerops-k8s.run` identifies the current set; decode `K8S_ADMIN_KUBECONFIG_B64_RUN_<ID>` before use.

See [operations](docs/operations.md), [upgrades](docs/upgrades.md), [disaster recovery](docs/disaster-recovery.md), [troubleshooting](docs/troubleshooting.md), [security](docs/security.md), and [costs](docs/costs.md).

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).
