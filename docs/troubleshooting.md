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

## Metrics, logs, or traces are missing

- Metrics: inspect Alloy and query `http://prometheus.zerops:9090/-/ready` over the VPN.
- Logs: inspect Fluent Bit, resolve `logstash.zerops`, and check Logstash TCP port 1514.
- Traces: confirm the `zerops-observability` Kubernetes Secret exists, the Istio Telemetry provider is `zerops-otlp`, and APM Server is healthy.

The acceptance workflow first proves the six live Zerops services match the dedicated CPU and fixed RAM/disk contract, then checks a two-minute freshness window for every Kubernetes metric family, emits a synthetic log containing token, email, and IP patterns, proves those values were redacted, generates a uniquely identifiable audit event, and requires a recent Istio trace. Its one-day sanitized evidence artifact is the best first diagnostic bundle. `zerops-node-resources.json` contains the sanitized outer-node proof. Kubescape findings exclude raw Kubernetes resource objects, and only Sonobuoy result summaries are retained, so Secret data and raw support archives are not uploaded.

If a Zerops Docker VM restart interrupts nested-node recovery, run the owner-only **Destroy Zerops Kubernetes** workflow. It first redeploys the restart-safe node agent, repairs mount propagation, resets all persisted nested state, and clears the Zerops-side cleanup lock before another deployment is allowed. If Zerops left a node build/deploy process nonterminal, pass its process ID through the workflow's optional `stuck_process_id` input; the workflow verifies that it belongs to one of this recipe's six node services before canceling it.
