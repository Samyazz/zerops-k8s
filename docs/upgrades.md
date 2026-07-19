# Upgrades

Ubuntu security updates are applied automatically inside the nested nodes, excluding kubelet, kubeadm, kubectl, and containerd. **Roll Zerops Kubernetes nodes and add-ons** runs every Monday and can be triggered manually; it takes verified backups, rolls the existing pinned nodes one at a time, and reapplies the repository-managed cluster and observability configuration. Every clean deployment rebuilds the pinned node image so replacement nodes also include current security packages.

Kubernetes and core add-ons are intentionally pinned in [`versions.env`](../versions.env). Automatic unreviewed Kubernetes minor upgrades are unsafe for stacked etcd, CNI, mesh, and storage, so Kubernetes upgrades use a controlled workflow:

1. Update one component/version at a time in `versions.env`, the node Dockerfile arguments, and any matching image/chart references.
2. Read that component's compatibility and upgrade notes.
3. Run **Back up Zerops Kubernetes** and require both the verified etcd object and a `Ready` Longhorn system backup before changing a node.
4. Run static validation and the regular deployment with full conformance.
5. Upgrade control planes one at a time, then workers one at a time. Keep kubelet no newer than the API server.
6. Confirm all Grafana dashboards and ELK/APM ingestion after each phase.

The maintenance workflow intentionally refuses a kubelet version that differs from `versions.env`; it does not implement an arbitrary version input. For Kubernetes minor versions, add and review a sequential `kubeadm upgrade plan/apply/node` change in a dedicated branch. Do not skip minors. Calico must explicitly list the target Kubernetes release as tested; Istio must list it as supported; Longhorn must satisfy its Kubernetes and host prerequisites.

Rollback application/add-on manifests through Git. Kubernetes/etcd downgrades are not a routine rollback mechanism; restore into fresh nodes from a known-good etcd snapshot when a control-plane upgrade cannot be repaired.
