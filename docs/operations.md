# Operations

## Daily checks

Use Grafana's **Zerops Kubernetes** folder for cluster, node, workload, etcd, Calico, Istio, ingress, certificate, and deployment views. Use Kibana for container, journal, audit, and control-plane logs. Retention is four hours by design.

With the Zerops VPN connected:

```sh
export KUBECONFIG="$HOME/.kube/zerops-k8s"
kubectl get nodes
kubectl get pods -A
kubectl get gateways,httproutes -A
kubectl get volumes.longhorn.io -A
istioctl proxy-status
```

Decode the kubeconfig stored in Zerops:

```sh
printf '%s' "$K8S_ADMIN_KUBECONFIG_B64" | base64 -d > "$HOME/.kube/zerops-k8s"
chmod 0600 "$HOME/.kube/zerops-k8s"
```

Headlamp roles are intentionally separate: admin, operator, developer (the `workloads` namespace), and read-only. Paste the corresponding service-account token into Headlamp's login screen.

## Deploy and reconcile

Run **Deploy Zerops Kubernetes** manually. A successful run is an update-in-place and remains running. GitHub concurrency rejects parallel runs, while the Zerops-side state blocks deployment after failed cleanup.

Run **Destroy Zerops Kubernetes** to reset every nested node. It removes the cluster state but leaves the reusable Zerops services and first-class observability services in the current project.

## Rolling maintenance

Run **Roll Zerops Kubernetes nodes and add-ons** for a routine node-agent and pinned add-on reconciliation. It also runs every Monday at 03:17 UTC. The workflow:

1. Rejects a repository mismatch or unresolved cleanup lock.
2. Creates and verifies fresh etcd and Longhorn backups.
3. Checks that every kubelet still matches `versions.env`.
4. Drains and rolls workers one at a time, followed by `k8scp2`, `k8scp3`, and `k8scp1`.
5. Waits for node readiness and healthy Longhorn replicas between disruptions.
6. Reconciles the pinned add-ons and runs non-destructive acceptance checks.

This workflow rolls the current pinned release; it is not an unreviewed Kubernetes version-upgrade switch. See the upgrade guide before changing version pins.

## Resize

Run **Resize Zerops Kubernetes** and provide the desired fixed resources. Control planes accept 4–32 dedicated CPUs, 8–128 GB RAM, and 20–500 GB disk. Workers accept 4–32 dedicated CPUs, 12–128 GB RAM, and 50–1000 GB disk. The desired worker count is either three or four.

The workflow takes verified backups first, then cordons, drains, resizes, restarts, verifies, and uncordons one node at a time. CPU and RAM can move up or down. Zerops Docker VM disks can only grow, so any disk value below the current allocation is rejected before that node is changed.

Scaling to four creates `k8sworker4`, deploys the agent, joins and labels the node, and waits for Calico, Istio, Longhorn, and the required host modules. Scaling to three disables Longhorn scheduling on worker four, waits for all replicas to evacuate, drains and resets it, and only then removes its Kubernetes and Zerops records. Three workers remain the HA and Longhorn-replica floor.

## Backups

- Prometheus snapshots run hourly and keep four object-storage copies.
- **Back up Zerops Kubernetes** runs at minute 23 every six hours and can also be started manually by the repository owner.
- Each run creates a consistent stacked-etcd snapshot on `k8scp1`, checks it with `etcdutl`, uploads it beneath `etcd/YYYY/MM/DD/`, uploads checksum metadata beside it, downloads it again, and requires a byte-for-byte SHA-256 match.
- The same run configures Longhorn's target beneath `longhorn/`, creates a `SystemBackup` with `volumeBackupPolicy: always`, and requires both `Ready` system-backup state and a completed backup of a real proof PVC. S3 credentials are created at runtime from Zerops object-storage variables and are never stored in Git.
- Longhorn recurring volume backups run at minute 17 every six hours and recurring system backups at minute 47. Each job retains its latest eight Longhorn backup records. Etcd objects are deliberately immutable and are not pruned by repository automation; configure a Zerops bucket lifecycle or review them manually according to the required recovery window.
- The four-hour setting applies only to demonstration metrics and logs, not to cluster backups.

Longhorn's three replicas provide node-failure availability, while the S3 target provides the separate off-node backup copy. Databases and other stateful applications may still need application-consistent logical backups in addition to crash-consistent volume backups.

Useful status checks:

```sh
kubectl -n longhorn-system get backuptargets,systembackups,backups
kubectl -n longhorn-system get recurringjobs
kubectl -n zerops-backup-validation get pvc,pod
```

Each Action retains a sanitized one-day artifact with the etcd object key, byte count, SHA-256, snapshot revision/key count, Longhorn target status, system-backup status, completed volume-backup status, and S3 object-count proof. It contains no object-store credential.

## Break-glass access

SSH remains available through the Zerops VPN. Normal operations should use Kubernetes and the authenticated node agent. SSH to a node service is for recovery when the API and automation paths both fail.
