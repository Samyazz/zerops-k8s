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
- Each run creates a consistent stacked-etcd snapshot on `k8scp1`, checks it with `etcdutl`, uploads it beneath `etcd/YYYY/MM/DD/`, downloads it again, and only then uploads its verified-success metadata.
- The matching `control-plane/YYYY/MM/DD/` object is an age/X25519-encrypted archive containing Kubernetes PKI, service-account signing keys, static manifests, kubeconfigs, the API encryption configuration, and an exact node/etcd version manifest. The Action round-trip verifies the encrypted object without exposing its plaintext or private identity.
- The same run configures Longhorn's target beneath `longhorn/`, creates a `SystemBackup` with `volumeBackupPolicy: always`, and requires both `Ready` system-backup state and a completed backup of a real proof PVC. S3 credentials are created at runtime from Zerops object-storage variables and are never stored in Git.
- Longhorn recurring volume backups run at minute 17 every six hours and recurring system backups at minute 47. Each recurring job and the Action-created `zerops-*` SystemBackups retain eight records.
- Etcd and encrypted identity objects use fail-closed tiered retention: the newest 28 verified sets, the newest set from seven UTC days, four ISO weeks, and three calendar months are retained as a union. A snapshot without its adjacent verified metadata is never deleted automatically. Settings are project variables and can be tightened or extended for a published import.
- The recipe provisions a private 25 GB `k8sbackups` bucket. At backup start, an older smaller bucket is increased in place to `K8S_BACKUP_QUOTA_GB` through the Zerops API without replacement or data loss. Every backup then sums the entire bucket inventory after pruning, emits a GitHub warning at 70%, and fails closed at 95%. Raise the configured quota or adjust retention before retrying; the workflow never deletes node images, Longhorn-native objects, incomplete snapshots, or unrecognised keys.
- The four-hour setting applies only to demonstration metrics and logs, not to cluster backups.

Longhorn's three replicas provide node-failure availability, while the S3 target provides the separate off-node backup copy. Databases and other stateful applications may still need application-consistent logical backups in addition to crash-consistent volume backups.

Useful status checks:

```sh
kubectl -n longhorn-system get backuptargets,systembackups,backups
kubectl -n longhorn-system get recurringjobs
kubectl -n zerops-backup-validation get pvc,pod
```

Each Action retains a sanitized one-day artifact with the etcd and encrypted-bundle object keys, byte counts and SHA-256 values, snapshot revision/key count, retention/capacity decisions, Longhorn target status, system-backup status, completed volume-backup status, and S3 object-count proof. It contains no object-store credential, age identity, Kubernetes private key, or decrypted bundle.

## Recovery drills

**Drill Zerops Kubernetes recovery** runs on the first day of each month at 04:13 UTC and can be dispatched by the repository owner. It first creates a fresh recovery point, then:

1. Downloads and checksum-verifies the etcd snapshot and encrypted control-plane bundle.
2. Decrypts the bundle with the GitHub recovery identity and requires the CA, etcd CA, service-account signing key, static etcd manifest, encryption configuration, and version manifest.
3. Uses the recorded official etcd image to restore into a disposable local data directory, starts an isolated member, requires endpoint health, and verifies Kubernetes registry/default-namespace keys.
4. Restores the newest completed backup of the real Longhorn proof PVC into a distinct Longhorn volume/PV/PVC, mounts it read-only, and compares its payload SHA-256 to the live source.
5. Removes all disposable etcd and Longhorn drill resources. Only sanitized evidence is uploaded.

This proves backup readability and data restoration without stopping or overwriting the live API server. A destructive whole-cluster rehearsal still requires an explicitly approved temporary recovery project because the repository's one-cluster invariant forbids a second live cluster by default.

## Break-glass access

SSH remains available through the Zerops VPN. Normal operations should use Kubernetes and the authenticated node agent. SSH to a node service is for recovery when the API and automation paths both fail.
