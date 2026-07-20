# Upgrades

Ubuntu security updates are applied automatically inside the nested nodes, excluding kubelet, kubeadm, kubectl, and containerd. **Roll Zerops Kubernetes nodes and add-ons** runs every Monday and can be triggered manually; it takes verified backups, rolls the existing pinned nodes one at a time, and reapplies the repository-managed cluster and observability configuration. Every clean deployment rebuilds the pinned node image so replacement nodes also include current security packages.

Kubernetes and core add-ons are intentionally pinned in [`versions.env`](../versions.env). Automatic unreviewed Kubernetes minor upgrades are unsafe for stacked etcd, CNI, mesh, and storage, so **Upgrade Zerops Kubernetes version** is manual and fail-closed:

1. Update `KUBERNETES_VERSION` and `KUBERNETES_PACKAGE_VERSION` together, plus the matching `import.yaml` node-image variables. Do not skip a minor version or downgrade.
2. Review Kubernetes, Calico, Istio, Longhorn, and Gateway API compatibility. Add the exact reviewed tuple to [`upgrade-policy.json`](../upgrade-policy.json); the workflow rejects an unlisted or mismatched tuple.
3. Dispatch the workflow with `confirm_target` exactly equal to `v<KUBERNETES_VERSION>` and leave `plan_only` enabled. The workflow deploys the authenticated fixed-operation agent when needed, creates and restores a fresh recovery point, builds/uploads the exact replacement image, installs the target kubeadm only on the primary, and requires `kubeadm upgrade plan` to pass.
4. Review the sanitized plan/recovery evidence. Dispatch the same commit and target with `plan_only` disabled.
5. The workflow upgrades `k8scp1`, `k8scp2`, and `k8scp3` serially, then every worker serially. Each node is cordoned/drained, each kubelet is verified at the target before uncordon, API readiness and Longhorn health gate every transition, and a partial retry skips already-upgraded nodes.

Before any node is cordoned, the workflow downloads the checksum-pinned Go toolchain, tests the exact requested Git commit, and builds the two static node-agent binaries. It then uses Zerops' direct app-version deployment path to upload that reviewed runtime artifact; no unreviewed source or repository secret is included, and the rollout does not depend on temporary Zerops build-container availability. Artifact checksums are retained with the one-day workflow evidence.
6. After all nodes pass, the workflow persists the new Zerops `K8S_VERSION`, node-image tag/object/checksum contract, reconciles the compatibility-approved add-ons, and runs acceptance plus optional full CNCF conformance.

The target is never taken from an unrestricted workflow input: the confirmation must match the reviewed repository pin. The agent accepts only canonical patch versions, the same minor or exactly the next minor, and the matching pinned Debian package. Its API exposes no generic command execution. A failed apply sets the Zerops lock to `upgrade-failed`; every other mutating workflow remains blocked until the same controlled workflow safely resumes. Kubernetes/etcd downgrade is not used as rollback.

Rollback application/add-on manifests through Git. When a control-plane upgrade cannot be repaired, use the fresh verified etcd and encrypted identity recovery set to restore compatible fresh nodes. Never run a Kubernetes or etcd downgrade over the failed cluster.
