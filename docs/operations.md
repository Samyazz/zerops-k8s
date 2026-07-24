# Operations

## Select the live profile

Every manual workflow has a `profile` input and defaults to `full`. Select the profile that is actually live. Scheduled backup and maintenance runs use repository variable `K8S_PROFILE`, falling back to `full`; update that variable after an intentional profile switch.

All changing workflows share one GitHub concurrency group and verify the Zerops repository/profile lock. Unknown profiles, a profile different from the live ownership tag, an unresolved `cleanup-failed`/`upgrade-failed` lock, and unsupported capabilities fail before infrastructure mutation.

| Operation | `full` | `production` | `staging` |
|---|---|---|---|
| Deploy/reconcile and destroy | Yes | Yes | Yes |
| Routine roll | Backup, workers, 3 control planes, add-ons | Backup, workers, sole control plane, add-ons | Restart/recover worker and sole control plane; no backup/storage step |
| Kubernetes upgrade | Yes | Yes; expected API interruption | Yes; expected outages and no backup step |
| Vertical resize | Yes | Yes | Yes |
| Horizontal resize | 3–4 workers | 2–3 workers | No; count remains 1 |
| Backup and restore drill | Yes | Yes | No |

Unsupported staging backup, restore, storage-health, horizontal-resize, and HA-disruption paths exit with a profile capability message before a Zerops login or mutation.

## Daily checks

Connect the Zerops VPN and use the selected profile's kubeconfig:

```sh
export KUBECONFIG="$HOME/.kube/zerops-k8s"
kubectl get --raw=/readyz
kubectl get nodes
kubectl get pods -A
kubectl get gateways,httproutes -A
```

For `full` and `production`, also inspect Longhorn:

```sh
kubectl -n longhorn-system get nodes.longhorn.io,volumes.longhorn.io
```

For `full`, use Grafana's **Zerops Kubernetes** dashboards and Kibana for cluster telemetry; `istioctl proxy-status` verifies the ambient mesh. For `production` and `staging`, inspect normal logs, CPU, RAM and health on each outer runtime's Zerops service detail. Those compact profiles intentionally do not offer nested pod-level Grafana/Kibana telemetry.

Decode a kubeconfig value retrieved from the current run's sensitive Zerops project variable without printing it:

```sh
umask 077
printf '%s' "$K8S_ADMIN_KUBECONFIG_B64" | base64 -d >"$HOME/.kube/zerops-k8s"
```

The server in every generated kubeconfig is `https://<derived-vrrp-vip>:6443`. The address is host `.222` in the last `/24` of the project `/22` and is stored as `K8S_VRRP_VIP`. Keepalived moves the `/32` between the two HAProxy replicas; the API certificate contains the VIP as an IP SAN, so no TLS server-name override is required.

From a trusted project runtime, `scripts/verify-vrrp-failover.sh` checks that exactly one replica owns the VIP. Add `--disrupt` to terminate Keepalived on the elected master, measure takeover by the other replica, and prove the API remains reachable. The edge supervisor then lets Zerops replace the failed runtime; `nopreempt` prevents the returning container from stealing the VIP back.

## Deploy, reconcile and switch

Run **Deploy Zerops Kubernetes** manually. A same-profile run updates in place and leaves a passing cluster running. A profile change is destructive:

1. Acquire the GitHub and Zerops locks and record source/target profiles.
2. If the source supports backup, require a fresh verified recovery point.
3. Destroy the nested cluster and cleanly retire Kubernetes/etcd/Longhorn membership.
4. Remove only repository-owned services forbidden by the target profile.
5. Reconcile the target services, deploy, and run target acceptance.

Never downsize three-member etcd to one member in place. Staging is disposable; its data is not automatically promoted to another profile. An application-data restore requires a separate, explicitly compatible recovery decision.

Run **Destroy Zerops Kubernetes** with the live profile to reset its nested state and perform repository-owned cleanup. It must preserve Zerops project-core services, `zcp`, and unrelated user services.

## Rolling maintenance

Run **Roll Zerops Kubernetes nodes and add-ons** on demand. It also runs Monday at 03:17 UTC using `K8S_PROFILE`.

- `full`: verified etcd/Longhorn backup, workers one at a time, `k8scp2`, `k8scp3`, then `k8scp1`, with Longhorn and API gates.
- `production`: verified etcd/Longhorn backup, two workers one at a time, then `k8scp1`. The API is expected to be unavailable while the sole control plane restarts.
- `staging`: recover/restart the worker and control plane separately. Outage is expected; no backup, storage-health, worker-disruption, or HA claim is made.

The workflow reconciles the current pinned release. It does not silently select a newer Kubernetes version.

## Resize

Run **Resize Zerops Kubernetes** with the live profile and fixed resource values. CPU and RAM can increase or decrease within the profile contract. A disk can grow but cannot shrink; a requested disk below the current allocation fails before that node changes.

The `desired_workers` input must be 3 or 4 for `full`, 2 or 3 for `production`, and exactly 1 for `staging`. Staging vertical resize therefore uses `desired_workers=1`; any other count is rejected before mutation.

Scale-in drains the retiring worker and evacuates Longhorn replicas before removing its Kubernetes and Zerops records. `full` never drops below three workers, and `production` never drops below two. Staging has no horizontal path.

## Backups

Backups exist only for `full` and `production`.

- **Back up Zerops Kubernetes** runs every six hours using repository variable `K8S_PROFILE` or on demand with an explicit profile.
- Each run creates a consistent stacked-etcd snapshot on `k8scp1`, verifies it with `etcdutl`, and pairs it with an age-encrypted identity bundle containing the compatible PKI, signing keys, static manifests, kubeconfigs, encryption configuration, and version manifest.
- The workflow configures Longhorn's private S3 target, creates a system backup and proof-volume backup, and verifies S3 round trips before writing completion metadata.
- `full` uses three Longhorn replicas; `production` uses two. Both store their off-node copies in `k8sbackups`.
- Retention and quota checks are fail-closed. Unrecognized or incomplete objects are never deleted automatically.
- A one-day artifact contains only profile, resolved non-secret contract, object keys, sizes/checksums, statuses, capacity decisions, and test summaries.

`staging` has no object storage, Longhorn, backup credentials, backup job, or restore job. Use Git and redeployment to recreate it.

Useful backup status checks for supported profiles:

```sh
kubectl -n longhorn-system get backuptargets,systembackups,backups
kubectl -n longhorn-system get recurringjobs
kubectl -n zerops-backup-validation get pvc,pod
```

## Recovery drills

**Drill Zerops Kubernetes recovery** runs monthly for the configured non-staging profile and can be dispatched by the repository owner. It creates a fresh recovery point, checksum-verifies and decrypts the identity bundle without exposing plaintext, starts an isolated restored etcd member, queries Kubernetes registry keys, restores the proof Longhorn volume under a distinct name, compares its content checksum, and removes all drill resources.

This proves backup readability without overwriting the live API server. It is rejected for `staging` before mutation. A destructive whole-cluster rehearsal requires an explicitly approved temporary project because this repository otherwise enforces one managed cluster.

## Evidence

Workflow artifacts are retained for one day. The deploy artifact includes the selected profile, resolved descriptor, exact Zerops inventory, Kubernetes nodes/pods and Gateway status, functional/security results, forbidden-component assertions, and backup/restore results only when the capability exists. Sanitization must remove tokens, authorization headers, cookies, e-mail addresses, and IP addresses. Raw kubeconfigs, Kubernetes Secrets, private keys, object-storage credentials, unredacted API responses, and support bundles are never uploaded.

## Break-glass access

SSH remains available through the Zerops VPN. Normal operations use Kubernetes and the fixed-operation node agent. SSH to an outer node is reserved for recovery when both the Kubernetes API and normal automation are unavailable.
