# Architecture

The six Zerops Docker services each run one privileged Ubuntu 24.04 system container. The outer Zerops container owns the Docker daemon and a small authenticated lifecycle agent. Kubernetes state lives below `/var/lib/zerops-k8s` on each outer service, so an agent deployment does not replace etcd, kubelet, containerd, CNI, logs, or Longhorn data.

`k8sedge` runs two Zerops replicas and provides three TCP paths:

- `6443` balances the Kubernetes API across all control planes.
- `8080` balances public ingress across worker NodePort `32080`.
- `18081` balances VPN-only Headlamp across worker NodePort `32081`.

The Kubernetes API certificate includes the edge hostname. kubeadm uses a non-expiring bootstrap token for this demonstration and a 32-byte certificate key. API Secrets are encrypted with AES-CBC; the encryption key originates in a Zerops secret.

Calico is the only Kubernetes network provider. Istio ambient adds encrypted workload identity without sidecars. The public `Gateway` is produced by Istio's Gateway API controller as a two-replica NodePort gateway.

Alloy runs once per node, scrapes the kubelet, cAdvisor, etcd where present, annotated pods/services, Calico, Istio, cert-manager, node-exporter, and kube-state-metrics, then remote-writes to the outer Zerops Prometheus service. OTLP traces go through Alloy to Zerops APM/Elasticsearch. Fluent Bit reads pod, audit, and journal logs, applies recursive redaction, and sends RFC5424 syslog to the outer Zerops Logstash service.

Longhorn uses worker disks below `/var/lib/longhorn`, with three replicas. The control plane is stacked etcd across all three control-plane nodes.
