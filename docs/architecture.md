# Architecture

Zerops is the infrastructure layer and Kubernetes is a nested control plane. Each Kubernetes node is one privileged Ubuntu 24.04 system container inside a Zerops Docker runtime. The outer runtime owns Docker and an authenticated fixed-operation lifecycle agent. Nested state lives below `/var/lib/zerops-k8s`, so an agent deployment does not replace etcd, kubelet, containerd, CNI state, logs, or storage data.

## Profile topology

| Component | `full` | `production` | `staging` |
|---|---|---|---|
| Control planes / stacked etcd | 3 | 1 | 1 |
| Workers | 3, optionally 4 | 2, optionally 3 | 1 fixed |
| Outer edge | 2 `k8sedge` containers | 2 `k8sedge` containers | None |
| Ingress | Istio Gateway API | Traefik Gateway API, 2 replicas | Traefik Gateway API, 1 replica |
| Storage | Longhorn, 3 replicas | Longhorn, 2 replicas | No dynamic storage layer |
| Backup target | Zerops `k8sbackups` | Zerops `k8sbackups` | None |
| Dashboard | Headlamp | None | None |
| Dedicated observability | Prometheus/Grafana and ELK/APM outer services; Alloy, Fluent Bit and exporters in-cluster | None | None |

The `full` edge exposes private TCP paths on `6443` for the Kubernetes API, `8080` for application ingress through worker NodePort `32080`, and `18081` for Headlamp through worker NodePort `32081`. `production` uses `6443` and `8080` but omits Headlamp. Both expose edge readiness on `18082`. `staging` has no edge: its kubeconfig targets `k8scp1.zerops:6443`, and ingress is reached directly at `k8sworker1.zerops:32080` over the Zerops VPN.

The API certificate includes the selected profile's control-plane endpoint. API Secrets are encrypted with the key generated and stored as a Zerops secret. kubeadm identity and cluster ownership remain profile-scoped so one repository cannot operate two nested clusters concurrently in the project.

## Networking and ingress

Calico is the only CNI and CoreDNS is the cluster DNS in every profile. Workload namespaces receive Pod Security Admission labels, default-deny NetworkPolicies, and only the required DNS and ingress allowances.

`full` uses Istio ambient and a two-replica Istio Gateway API data plane. `production` and `staging` deliberately omit Istio and cert-manager; they install pinned standard Gateway API CRDs and Traefik. Zerops handles TLS for any separately configured public HTTP route. The recipe itself leaves application ingress VPN-only.

## Storage and recovery

`full` spreads three Longhorn replicas over three workers. `production` spreads two replicas over two workers. Both send etcd identity bundles and Longhorn backups to their private Zerops `k8sbackups` service. `staging` has neither Longhorn nor off-node backup and must not be used for durable state.

The single control plane in `production` and `staging` is a deliberate availability tradeoff. Its loss interrupts the API and etcd. Two production workers can keep already-running, suitably spread workloads available, but they cannot provide Kubernetes control-plane failover.

## Observability

Every Zerops project core supplies normal service logs and resource statistics. `production` and `staging` rely only on these platform surfaces for their outer node/edge runtimes and do not claim pod-level observability. No Grafana, Prometheus, ELK, APM, Alloy, Fluent Bit, kube-state-metrics, or node-exporter service/pod belongs to either compact profile.

`full` adds the complete stack. Alloy runs once per node and scrapes control-plane, kubelet, cAdvisor, etcd, Calico, Istio, cert-manager, Longhorn, node-exporter and kube-state-metrics targets. It remote-writes metrics to Zerops Prometheus and forwards OTLP traces to APM/Elasticsearch. Fluent Bit reads pod, audit and journal logs, recursively redacts sensitive fields, and forwards them to the outer Logstash service.

## Resource governance

All recipe-managed application and add-on Pods have non-zero CPU/memory requests and finite limits. The demonstration namespace has a `LimitRange` and `ResourceQuota`. Production runs two demo replicas with hard topology spread, a disruption budget and HPA; staging runs one bounded replica without HPA or PDB. Privileged system DaemonSets are named policy exceptions rather than blanket workload permissions.
