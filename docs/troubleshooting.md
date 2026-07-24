# Troubleshooting

Start every investigation by confirming the workflow's selected `profile` matches both the live `zerops-k8s.profile` tag and the repository variable used by scheduled jobs. A wrong profile can look like missing nodes or services; do not bypass the mismatch gate.

## Deployment or operation is blocked

- `cleanup-failed`: run **Destroy Zerops Kubernetes** with the live profile. Later mutations remain blocked until all failed/partial owned resources are gone and cleanup verifies success.
- `upgrade-failed`: resume **Upgrade Zerops Kubernetes version** from the same commit, profile and reviewed target. Do not downgrade Kubernetes/etcd.
- `profile ... does not support backup/restore/horizontal resize`: the operation is invalid for that profile and was rejected before mutation. Staging has no backup/restore and its worker count is fixed at one.
- Profile tag mismatch: inspect the last successful deployment evidence and select the actual live profile. A profile switch must use the deploy workflow's clean replacement sequence.

## Kubernetes API is unavailable

Use the correct VPN-only endpoint:

- Every profile uses `https://<derived-vrrp-vip>:6443`. Read the exact address from `K8S_VRRP_VIP`, then check `http://<vip>:18082/healthz`, Keepalived election logs, and HAProxy backend state on both edge containers. Exactly one replica must own the VIP.

Keepalived discovers the default interface and current `/22` address every time a replica starts; multicast VRRP has no static peer list. After an edge replacement, confirm the new address enters `BACKUP` and the current master retains the VIP. HAProxy uses the Zerops resolver from `/etc/resolv.conf` with short DNS holds; after a node-container replacement, confirm its backend changes from `DOWN` to `UP`.

The workflows connect with `zcli vpn up --mtu 1280`. If small responses work but kubeconfig or larger transfers stall, reconnect with the same MTU. Never disable TLS verification for routine access.

An unavailable sole control plane is an expected API outage in `production` and `staging`, not a failover event. In `full`, check all three control-plane agents and edge backend health before declaring quorum loss.

## Application ingress is unavailable

- Every profile: test `http://<derived-vrrp-vip>:8080`, Gateway/HTTPRoute status, then worker NodePort `32080` from the private network.

`full` uses Istio; inspect its Gateway data plane and ambient components. `production` and `staging` use Traefik and must not have Istio resources. All profiles leave public routing disabled by default.

## A node is NotReady

Inspect conditions and required system pods:

```sh
kubectl describe node NODE
kubectl -n calico-system get pods -o wide
kubectl -n kube-system get pods -o wide
```

For break glass, SSH to the outer service and inspect the nested node with `docker exec zerops-k8s-node journalctl -u kubelet -u containerd`. The node agent is private on port `18080`; `/healthz` is unauthenticated readiness, while operational paths require the Zerops-held bearer token.

In staging, also verify that the pinned node image built locally. It must not wait for an object in `k8sbackups`, because that service does not exist.

## Longhorn is degraded

This section applies only to `full` and `production`; Longhorn must be absent in staging.

Check worker readiness, free space, mount propagation, `iscsid`, host-module prerequisites, and replica state:

```sh
kubectl -n kube-system get daemonset/longhorn-node-prerequisites
kubectl -n longhorn-system get nodes.longhorn.io,replicas.longhorn.io,volumes.longhorn.io
```

Do not disrupt another worker or delete the last healthy replica while rebuilding. Full expects three storage replicas; production expects two.

## Backup or restore drill fails

Backups are valid only for `full` and `production`. Check target and proof resources without printing the generated Secret:

```sh
kubectl -n longhorn-system get backuptargets.longhorn.io default -o yaml
kubectl -n longhorn-system get systembackups.longhorn.io,backups.longhorn.io
kubectl -n zerops-backup-validation get pvc,pod
```

The target must be available, the system backup Ready, and the proof-volume backup Completed. Use the sanitized artifact to compare object key, byte count, SHA-256, etcd key count, identity-bundle linkage, quota and restore checksum. Never paste `k8sbackups` values or the age identity into logs.

An age-recipient error means repository variable `K8S_RECOVERY_AGE_RECIPIENT` is absent or malformed. A decryption error means `K8S_RECOVERY_AGE_IDENTITY` does not match. Rotate the pair together and retain the old private identity offline while old recovery points exist.

The drill restores into disposable etcd/Longhorn resources and never overwrites live data. Remove any resource with the drill prefix before retrying. A staging dispatch should stop at the capability gate; if it reaches S3 or Longhorn code, treat that as a workflow bug.

## Metrics, logs, or traces are missing

For `full`, inspect Alloy, Fluent Bit, Prometheus, Logstash and APM health, then use the one-day acceptance artifact's ingestion/redaction proofs. Grafana and Kibana are reached from their Zerops service pages/subdomains.

For `production` and `staging`, there is no dedicated cluster telemetry stack. Use the Zerops service detail for fresh outer runtime logs and CPU/RAM statistics. Absence of pod-level Prometheus, Loki/ELK or tracing data is by design. Acceptance must prove excluded observability services and collector/exporter Pods are absent instead of querying them.

## Evidence is missing or unsafe

Artifacts use one-day retention and include `profile-contract.json`. A valid deployment bundle also contains exact Zerops service inventory, Kubernetes nodes/pods/Gateway status, functional/security results, forbidden-component checks, and supported backup results. Fail the workflow if any artifact contains bearer tokens, authorization headers, cookies, e-mail addresses, IP addresses, kubeconfigs, private keys, Kubernetes Secret data, or raw unredacted API responses.
