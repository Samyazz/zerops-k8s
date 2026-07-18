#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops first-class recipe variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_PROJECT_ID
load_zerops_env
require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
wait_for_agents

log 'starting all nested Kubernetes nodes'
pids=()
for node in "${NODES[@]}"; do agent_request "$node" POST /v1/node/start >/dev/null & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done

log 'initializing the first stacked-etcd control plane'
init_response=$(agent_request k8scp1 POST /v1/cluster/init)
ca_hash=$(jq -er .caHash <<<"$init_response")

kubeconfig=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubeconfig
mkdir -p "$(dirname "$kubeconfig")"
agent_request k8scp1 GET /v1/cluster/kubeconfig > "$kubeconfig"
sed -i 's#^[[:space:]]*server:.*#    server: https://k8sedge:6443#' "$kubeconfig"
chmod 0600 "$kubeconfig"
export KUBECONFIG=$kubeconfig
printf 'KUBECONFIG=%s\n' "$kubeconfig" >> "${GITHUB_ENV:-/dev/null}"

api_deadline=$((SECONDS + 600))
until kubectl get --raw=/readyz >/dev/null 2>&1; do
  (( SECONDS < api_deadline )) || die 'Kubernetes API did not become ready within 10 minutes'
  sleep 3
done

log 'installing Calico before the remaining nodes join'
helm repo add projectcalico https://docs.tigera.io/calico/charts --force-update >/dev/null
helm upgrade --install calico-crds projectcalico/crd.projectcalico.org.v1 \
  --version "v${CALICO_VERSION}" --namespace tigera-operator --create-namespace --wait --timeout 15m
helm upgrade --install calico projectcalico/tigera-operator \
  --version "v${CALICO_VERSION}" --namespace tigera-operator --wait --timeout 15m
kubectl apply -f "$ROOT_DIR/kubernetes/calico-installation.yaml"
kubectl wait --for=condition=Established crd/felixconfigurations.crd.projectcalico.org --timeout=5m
kubectl apply -f "$ROOT_DIR/kubernetes/calico-felix.yaml"
kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=10m

join_body=$(jq -cn --arg hash "$ca_hash" '{caHash:$hash}')
for node in k8scp2 k8scp3; do
  log "joining control plane $node"
  agent_request "$node" POST /v1/cluster/join "$join_body" >/dev/null
done

pids=()
for node in "${WORKERS[@]}"; do agent_request "$node" POST /v1/cluster/join "$join_body" >/dev/null & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done

for node in "${WORKERS[@]}"; do
  node_deadline=$((SECONDS + 300))
  until kubectl get node "$node" >/dev/null 2>&1; do
    (( SECONDS < node_deadline )) || die "worker did not register with the API within 5 minutes: $node"
    sleep 2
  done
  kubectl label node "$node" node-role.kubernetes.io/worker='' node.longhorn.io/create-default-disk=true --overwrite
done
kubectl wait --for=condition=Ready nodes --all --timeout=20m
kubectl -n calico-system rollout status daemonset/calico-node --timeout=15m
kubectl -n calico-system rollout status deployment/calico-kube-controllers --timeout=10m
kubectl apply -f "$ROOT_DIR/kubernetes/calico-metrics.yaml"

kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml"
kubectl label namespace kube-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace calico-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace tigera-operator pod-security.kubernetes.io/enforce=privileged --overwrite

log 'installing Gateway API and Istio ambient mesh'
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/experimental-install.yaml"
istioctl install --skip-confirmation --readiness-timeout 15m \
  --set profile=ambient \
  --set "meshConfig.extensionProviders[0].name=zerops-otlp" \
  --set "meshConfig.extensionProviders[0].opentelemetry.service=alloy.observability.svc.cluster.local" \
  --set "meshConfig.extensionProviders[0].opentelemetry.port=4317"
kubectl label namespace istio-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl -n istio-system rollout status deployment/istiod --timeout=10m
kubectl -n istio-system rollout status daemonset/ztunnel --timeout=10m

log 'installing Longhorn, cert-manager, metrics-server, and exporters'
helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null
helm upgrade --install longhorn longhorn/longhorn --version "$LONGHORN_VERSION" \
  --namespace longhorn-system --create-namespace \
  --set csi.kubeletRootDir=/var/lib/kubelet \
  --set defaultSettings.defaultReplicaCount=3 \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --wait --timeout 20m
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager --version "v${CERT_MANAGER_VERSION}" \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout 10m

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_CHART_VERSION" \
  --namespace kube-system --set replicas=2 \
  --set 'args={--cert-dir=/tmp,--secure-port=10250,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname,--kubelet-use-node-status-port,--metric-resolution=15s,--kubelet-insecure-tls}' \
  --wait --timeout 10m

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --version "$KUBE_STATE_METRICS_CHART_VERSION" --namespace observability \
  --set-string service.annotations."prometheus\.io/scrape"='true' \
  --set-string service.annotations."prometheus\.io/port"='8080' --wait --timeout 10m
helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter \
  --version "$NODE_EXPORTER_CHART_VERSION" --namespace observability \
  --set-string service.annotations."prometheus\.io/scrape"='true' \
  --set-string service.annotations."prometheus\.io/port"='9100' --wait --timeout 10m

load_zerops_env
require_env ELASTIC_APM_SECRET_TOKEN
kubectl -n observability create secret generic zerops-observability \
  --from-literal="elastic-apm-secret-token=$ELASTIC_APM_SECRET_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm upgrade --install alloy grafana/alloy --version "$ALLOY_CHART_VERSION" \
  --namespace observability -f "$ROOT_DIR/kubernetes/monitoring/alloy-values.yaml" --wait --timeout 15m
kubectl -n observability rollout restart daemonset/alloy
kubectl -n observability rollout status daemonset/alloy --timeout=15m

helm repo add fluent https://fluent.github.io/helm-charts --force-update >/dev/null
helm upgrade --install fluent-bit fluent/fluent-bit --version "$FLUENT_BIT_CHART_VERSION" \
  --namespace observability -f "$ROOT_DIR/kubernetes/monitoring/fluent-bit-values.yaml" --wait --timeout 15m

kubectl apply -f "$ROOT_DIR/kubernetes/headlamp.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/headlamp-rbac.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/demo.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/istio-gateway.yaml"
kubectl apply -f "$ROOT_DIR/kubernetes/security.yaml"
kubectl -n workloads wait --for=condition=Available deployment/demo --timeout=10m
kubectl -n headlamp wait --for=condition=Available deployment/headlamp --timeout=10m
kubectl -n istio-ingress wait --for=condition=Programmed gateway/public-gateway --timeout=10m

log 'cluster bootstrap and idempotent add-on reconciliation completed'
