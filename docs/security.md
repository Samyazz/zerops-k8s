# Security model

- Node lifecycle endpoints are private, bearer-authenticated, and expose fixed operations rather than a generic shell.
- The node image archive is private and verified with SHA-256 before loading.
- Kubernetes Secrets use API-server envelope encryption with a Zerops-generated 32-byte key.
- Audit policy records mutations and metadata access; Fluent Bit redacts credentials, cookies, e-mail addresses, usernames, and IP addresses before forwarding.
- The `workloads` namespace enforces the Restricted Pod Security Standard. System namespaces explicitly opt into the minimum required privileged policy for CNI, mesh CNI, storage, node metrics, and log collection.
- Istio ambient enforces strict mTLS for meshed workloads.
- Headlamp is raw TCP behind `k8sedge:18081`, has no public Zerops HTTP route, and uses role-specific long-lived service-account tokens.
- Repository files contain no secret values. Workflow credentials are GitHub secrets; generated operational credentials are sensitive Zerops project variables keyed by the successful GitHub run ID.
- Kubescape and CIS findings are reports. They do not automatically block this demonstration, while conformance and functional failures do.

The cluster deliberately permits privileged system components needed by Calico, Istio CNI/ztunnel, Longhorn, node-exporter, Alloy, and Fluent Bit. User workloads do not receive those exemptions.
