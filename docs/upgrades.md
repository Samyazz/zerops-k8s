# Upgrades

Ubuntu security updates are applied automatically inside nested nodes, excluding kubelet, kubeadm, kubectl, and containerd. The weekly maintenance workflow rolls the current node image and pinned add-ons. Kubernetes minor versions remain controlled because kubeadm, etcd, Calico, the ingress implementation, and—where enabled—Istio and Longhorn must move as a reviewed compatibility set.

## Profile behavior

| Profile | Node order | Pre-upgrade recovery gate | Post-upgrade acceptance |
|---|---|---|---|
| `full` | `k8scp1`, `k8scp2`, `k8scp3` serially, then workers serially | Fresh etcd/identity and Longhorn backup plus isolated restore proof | Functional suite and full CNCF conformance by default |
| `production` | Sole `k8scp1`, then workers serially | Fresh etcd/identity and Longhorn backup plus isolated restore proof | Functional suite and Sonobuoy quick by default |
| `staging` | Sole `k8scp1`, then `k8sworker1` | No backup capability; require clean recreatability and a plan-only pass | Functional networking/DNS/ingress/security smoke suite |

The `production` and `staging` API is unavailable while the sole control plane is upgraded or restarted. The workflow must report this expected interruption rather than describe it as failover. Existing production worker workloads may continue, but scheduling and reconciliation pause.

## Controlled upgrade procedure

1. Update `KUBERNETES_VERSION` and `KUBERNETES_PACKAGE_VERSION` together in [`versions.env`](../versions.env), plus matching profile/import node-image variables. Do not skip a minor version or downgrade.
2. Review the selected profile's compatibility tuple. `full` includes Calico, Istio, Longhorn and Gateway API; `production` includes Calico, Traefik, Longhorn and Gateway API; `staging` includes Calico, Traefik and Gateway API. Add the exact reviewed tuple to [`upgrade-policy.json`](../upgrade-policy.json).
3. Dispatch **Upgrade Zerops Kubernetes version** with the live `profile`, `confirm_target` exactly equal to `v<KUBERNETES_VERSION>`, and `plan_only=true`.
4. Review the sanitized plan and, when supported, recovery evidence. Dispatch the same commit/profile/target with `plan_only=false`.
5. The workflow cordons and drains one node at a time, verifies its kubelet at the target, waits for API and profile-supported storage health, then uncordons it. A retry skips nodes already at the target.
6. After every node passes, the workflow persists the version/image contract, reconciles only that profile's add-ons, and runs its acceptance level.

Before the first drain, the workflow tests and builds the exact committed node-agent artifact. `full` and `production` may cache the image in `k8sbackups`; staging builds its node image locally in each Docker runtime and must not acquire an S3 dependency.

The target is never taken from an unrestricted input: the confirmation must match the reviewed repository pin and policy. Only the same minor or next minor is accepted. A failed applied upgrade sets `upgrade-failed`; other mutations remain blocked until the same controlled workflow resumes or the explicit recovery path succeeds.

Application and add-on manifests roll back through Git. Kubernetes and etcd are never downgraded in place. For `full` or `production`, use the fresh verified recovery set when an incompatible control-plane failure requires rebuild. Staging is destroyed and recreated from the pinned repository state.
