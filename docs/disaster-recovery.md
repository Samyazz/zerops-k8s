# Disaster recovery

## Recovery capability by profile

| Failure | `full` | `production` | `staging` |
|---|---|---|---|
| One worker | Workloads reschedule; three-replica Longhorn rebuilds | Workloads reschedule; two-replica Longhorn rebuilds | Whole workload capacity is unavailable until the worker returns |
| One control plane | Two etcd members keep quorum and the edge removes the failed backend | API/etcd outage until the sole member returns or is restored | API/etcd outage; recreate the disposable cluster if repair is not worthwhile |
| Off-node recovery | Etcd identity plus Longhorn in Zerops S3 | Etcd identity plus Longhorn in Zerops S3 | Not available |
| Isolated restore drill | Supported | Supported | Rejected before mutation |

`production` is not an HA control plane. Two workers protect suitable running workloads from one worker failure, not from loss of the Kubernetes API. Staging has no durable-state promise.

## Worker loss

For `full` and `production`, repair or recreate the affected Zerops runtime, deploy the pinned node agent, join it, and wait until Longhorn replicas are healthy before another disruption. Verify the application remains spread across the surviving workers.

For `staging`, recover `k8sworker1` or recreate the profile. The demo and ingress are unavailable while its only worker is down.

## Control-plane loss

In `full`, do not reset the surviving etcd members. Restore a failed service and rejoin it serially. If quorum is lost, preserve the current data directories and use the newest verified etcd snapshot, linked encrypted identity bundle, version manifest and supported kubeadm/etcd recovery procedure. Restore with `etcdutl` into a clean directory; never restore over a running member.

In `production`, first attempt to recover `k8scp1` with its persisted nested state. If that is impossible, recreate a compatible sole control plane from the verified etcd snapshot and age-encrypted identity bundle, then reattach or rebuild workers. API outage continues throughout this procedure.

In `staging`, the normal recovery path is clean profile recreation from Git. There is no S3 snapshot or encrypted identity bundle to rely on.

## Longhorn restore

This section applies only to `full` and `production`. The private `longhorn/` target contains volume and system backups.

1. Recreate a cluster using the same profile or a separately reviewed compatible target and install the pinned Longhorn version.
2. Recreate the runtime S3 Secret from `k8sbackups` Zerops variables without printing it, then configure the default `BackupTarget`.
3. Wait for `available: true` and inventory the required system/volume backups.
4. Restore the selected system backup or restore an individual backup as a distinct volume and PVC.
5. Verify application-level integrity before restoring traffic. Stateful applications may also require logical backups.

Never commit the generated S3 Secret or copy its values into an Action artifact.

## Whole nested-cluster loss

For `full` or `production`:

1. Preserve the verified etcd object and metadata, linked encrypted control-plane bundle and metadata, offline age identity, Longhorn backups, application-aware backups, and current Zerops secrets.
2. Run **Destroy Zerops Kubernetes** with the source profile until its state is `destroyed` and no failed/partial owned service remains.
3. Run **Deploy Zerops Kubernetes** for the target profile.
4. Restore Longhorn volumes and application-consistent data when compatible.
5. Restore etcd only when old Kubernetes object/control-plane state is required; otherwise let Git and the workflow recreate it.
6. Rotate long-lived UI/service-account credentials and inspect audit evidence.

For staging, destroy and redeploy; do not import production credentials or data by default.

## Profile switching and data

A profile change is a clean replacement. Before leaving a backup-capable source, create a fresh recovery point. Never shrink full's stacked-etcd membership into the single-member production/staging topology. Staging data is discarded. Application-data migration between `full` and `production` is outside automatic switching unless an explicitly reviewed restore input confirms compatibility.
