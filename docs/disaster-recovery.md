# Disaster recovery

## One worker lost

Longhorn retains three replicas and Kubernetes reschedules workloads. Repair or recreate the affected Zerops service, deploy the node agent, and join it again. Verify Longhorn replica rebuilding before another disruption.

## One control plane lost

The edge proxy removes failed TCP backends naturally. Two etcd members retain quorum. Repair the service and rejoin it as a control plane before taking another member down.

## Two control planes lost

Do not reset the surviving member. Recover at least one failed member if possible. If quorum cannot be recovered, use the most recent verified object beneath `etcd/YYYY/MM/DD/` and its adjacent `.json` metadata. Confirm the downloaded SHA-256 before touching the surviving data directory.

Restore into clean control-plane state using the same Kubernetes/etcd version and the retained PKI/encryption material. Use `etcdutl snapshot restore` to a new data directory with the intended member name, peer URL, and initial cluster membership; point the static etcd Pod at the restored directory only after the restore completes. Start one member, verify etcd and API health, then join/recreate the other control planes serially. An etcd restore is a destructive quorum-recovery operation: preserve the current data directories and follow the target Kubernetes release's kubeadm/etcd recovery procedure rather than restoring over a running member.

## Longhorn restore

The `longhorn/` S3 target contains both volume backups and Longhorn system backups. After recreating a compatible cluster and installing the pinned Longhorn version:

1. Re-run **Back up Zerops Kubernetes** only far enough to configure the runtime S3 target, or recreate the `zerops-s3-backups` Secret from the `k8sbackups` Zerops variables and patch Longhorn's default `BackupTarget`.
2. Wait until the target reports `available: true` and the backup volumes/system backups appear.
3. For full Longhorn metadata recovery, select the required `SystemBackup` and perform a System Restore using Longhorn's supported restore procedure.
4. For an individual workload, restore the selected backup as a Longhorn volume, create/bind the PVC, and deploy the workload against it.
5. Verify application-level integrity before restoring traffic. Database engines should also be recovered from their application-consistent logical backup when available.

Do not commit the generated S3 Secret or copy its values into an Action artifact.

## Whole nested cluster lost

1. Preserve the verified etcd object/metadata pair, required Longhorn system and volume backups, application-aware backups, and the current Zerops secret variables.
2. Run the destroy workflow until the Zerops-side state is `destroyed`.
3. Run the deploy workflow to recreate the cluster.
4. Restore Longhorn metadata/volumes from the Zerops S3 target, then restore application-consistent data where required.
5. Restore etcd only when recovery of the old Kubernetes object/control-plane state is required; otherwise let Git and the deployment workflow recreate that state.
6. Rotate Headlamp tokens and review audit logs.

The repository and Zerops secrets are the configuration source of truth. The backup workflow validates snapshot structure and an S3 upload/download checksum round trip, but a scheduled isolated restore drill is still required to prove the complete application recovery-time objective. Prometheus data is demonstrational and only retained for four hours; it should not be treated as recovery-critical.
