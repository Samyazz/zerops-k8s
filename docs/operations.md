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

## Backups

- Prometheus snapshots run hourly and keep four object-storage copies.
- Kubernetes application data is replicated three ways by Longhorn; this is availability, not an off-site backup.
- Back up important application data using application-aware jobs to `k8sbackups` or another external store.
- Back up etcd before Kubernetes upgrades as described in the upgrade guide.

## Break-glass access

SSH remains available through the Zerops VPN. Normal operations should use Kubernetes and the authenticated node agent. SSH to a node service is for recovery when the API and automation paths both fail.
