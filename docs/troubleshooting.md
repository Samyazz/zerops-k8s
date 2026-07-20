# Troubleshooting

## Deployment is blocked

If the Zerops project tag `zerops-k8s.state` is `cleanup-failed`, run **Destroy Zerops Kubernetes**. Later deploys intentionally remain blocked until every nested node resets successfully.

## An outer node agent is unavailable

Check the corresponding Zerops service build/runtime events and logs. The agent listens privately on port `18080`; it is not an HTTP subdomain. Confirm the node image object and `.sha256` object both exist in `k8sbackups`.

## Kubernetes API is unavailable

Check `http://k8sedge:18082/healthz`, then each control plane's agent state. The kubeconfig server must be `https://k8sedge.zerops:6443` and the Zerops VPN must be active. Never bypass TLS verification for routine access.

The workflows connect with `zcli vpn up --mtu 1280`. If a manual VPN connection can transfer small health responses but stalls on kubeconfig or other larger responses, reconnect with the same MTU instead of the default 1420.

## Node is NotReady

Inspect conditions and system pods:

```sh
kubectl describe node NODE
kubectl -n calico-system get pods -o wide
kubectl -n kube-system get pods -o wide
```

For break glass, SSH to its outer Zerops service and inspect the nested node with `docker exec zerops-k8s-node journalctl -u kubelet -u containerd`.

## Longhorn volume is degraded

Ensure all workers are Ready, `iscsid` is active, mount propagation is shared, and `/var/lib/longhorn` has free space. Do not delete the last healthy replica. Let rebuilding finish before maintenance.

The nested workers rely on the privileged `longhorn-node-prerequisites` DaemonSet to load the Zerops host's `iscsi_tcp`, `nfs`, and `dm_crypt` kernel modules. Check it before diagnosing an attach failure:

```sh
kubectl -n kube-system get daemonset/longhorn-node-prerequisites
kubectl -n kube-system get pods -l app.kubernetes.io/name=longhorn-node-prerequisites -o wide
kubectl -n longhorn-system get nodes.longhorn.io,replicas.longhorn.io
```

All desired DaemonSet Pods must be Ready on workers, and each Longhorn worker disk must report Ready. The exception is limited to `kube-system`; application namespaces still enforce restricted Pod Security Admission.

## A backup fails

Check the target and backup resources without printing the generated Secret:

```sh
kubectl -n longhorn-system get backuptargets.longhorn.io default -o yaml
kubectl -n longhorn-system get systembackups.longhorn.io
kubectl -n longhorn-system get backups.longhorn.io
kubectl -n zerops-backup-validation get pvc,pod
```

The target must report `available: true`, the latest on-demand SystemBackup must be `Ready`, and the proof-volume backup must be `Completed`. If the target is unavailable, confirm the `k8sbackups` service exists and that its environment keys are wired to the Action; never paste their values into logs. For etcd, inspect the sanitized artifact's status JSON and compare its object key, byte count, and SHA-256 metadata. A missing or mismatched download fails the workflow automatically.

If `capacity-pre-backup.json` or `capacity-post-backup.json` reports 70% or more, raise Zerops project variable `K8S_BACKUP_QUOTA_GB` or reduce the documented tiered-retention settings; the next backup performs the supported in-place quota increase. At 95% the workflow fails after safe pruning and before risking an incomplete recovery point. Automatic pruning requires both metadata documents to cross-reference a complete encrypted recovery set with valid SHA-256 fields; unrecognised or incomplete objects must be reviewed manually.

An age recipient error means repository variable `K8S_RECOVERY_AGE_RECIPIENT` is missing or malformed. A recovery-drill decryption error means secret `K8S_RECOVERY_AGE_IDENTITY` is not the matching private identity. Replace the pair together and preserve the old identity offline until every recovery point encrypted to it has expired.

## A recovery drill fails

Inspect `restore-drill.json` and the preceding backup evidence. The drill never restores over the live etcd member or source Longhorn volume. An etcd failure usually means the recorded official etcd image cannot read the snapshot or the encrypted identity bundle is incomplete. A Longhorn failure usually means the selected backup has not synchronized, the temporary volume cannot obtain three replicas, or `/data/proof.txt` differs from the live source. The trap removes only resources prefixed `restore-drill-`; verify and delete leftovers before retrying:

```sh
kubectl -n longhorn-system get volumes.longhorn.io | grep restore-drill
kubectl -n zerops-backup-validation get pod,pvc
kubectl get pv | grep restore-drill
```

## A controlled version upgrade fails

The project lock becomes `upgrade-failed`, blocking deploy, resize, maintenance, and backup changes while leaving explicit teardown available. Re-run **Upgrade Zerops Kubernetes version** from the same reviewed commit and target; already-upgraded nodes are skipped. Do not attempt a package or Kubernetes downgrade. If kubeadm cannot resume, preserve the failed nodes and use the fresh restore-drill evidence plus the disaster-recovery runbook to rebuild compatible control planes.

## Metrics, logs, or traces are missing

- Metrics: inspect Alloy and query `http://prometheus.zerops:9090/-/ready` over the VPN.
- Logs: inspect Fluent Bit, resolve `logstash.zerops`, and check Logstash TCP port 1514.
- Traces: confirm the `zerops-observability` Kubernetes Secret exists, the Istio Telemetry provider is `zerops-otlp`, and APM Server is healthy.

The acceptance workflow first proves the six live Zerops services match the dedicated CPU and fixed RAM/disk contract, then checks a two-minute freshness window for every Kubernetes metric family, emits a synthetic log containing token, email, and IP patterns, proves those values were redacted, generates a uniquely identifiable audit event, and requires a recent Istio trace. Its one-day sanitized evidence artifact is the best first diagnostic bundle. `zerops-node-resources.json` contains the sanitized outer-node proof. Kubescape findings exclude raw Kubernetes resource objects, and only Sonobuoy result summaries are retained, so Secret data and raw support archives are not uploaded.

If a Zerops Docker VM restart interrupts nested-node recovery, run the owner-only **Destroy Zerops Kubernetes** workflow. It reuses every healthy node agent, redeploys only agents that are unreachable, repairs mount propagation, resets all persisted nested state, and clears the Zerops-side cleanup lock before another deployment is allowed. Normal agent upgrades stop and restart each nested node serially around its Zerops rollout so host-networked Kubernetes components cannot interfere with container replacement. If Zerops left a node build/deploy process nonterminal, pass its process ID through the workflow's optional `stuck_process_id` input; the workflow verifies that it belongs to one of this recipe's six node services before canceling it. A process already in Zerops' non-cancelable deployment phase remains protected by the repository lock while the workflow waits up to 30 minutes for the platform timeout.
