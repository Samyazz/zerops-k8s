#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops first-class recipe variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

gateway=$(profile_json '.addons.gateway')
storage=$(profile_json '.addons.storage')
observability=$(profile_json '.addons.observability')
demo=$(profile_json '.addons.demo')
gateway_replicas=$(profile_json '.addons.gatewayReplicas')
storage_replicas=$(profile_json '.addons.storageReplicas')
metrics_server_replicas=$(profile_json '.addons.metricsServerReplicas')
cert_manager=$(profile_json '.addons.certManager')
dashboard=$(profile_json '.addons.dashboard')
security=$(profile_json '.addons.security')

print_feature_gates() {
  printf '%s\n' \
    "profile=$K8S_PROFILE" \
    "cni=$(profile_json '.addons.cni')" \
    "gateway=$gateway" \
    "gateway-replicas=$gateway_replicas" \
    "storage=$storage" \
    "storage-replicas=$storage_replicas" \
    "metrics-server-replicas=$metrics_server_replicas" \
    "platform-observability=$([[ "$observability" == platform ]] && printf true || printf false)" \
    "dedicated-observability=$([[ "$observability" == advanced ]] && printf true || printf false)" \
    "dashboard=$dashboard" \
    "demo=$demo" \
    "security=$security"
}

if [[ "${1:-}" == --print-feature-gates ]]; then
  print_feature_gates
  exit 0
fi
[[ $# -eq 0 ]] || die 'usage: cluster-bootstrap.sh [--print-feature-gates]'

install_calico() {
  log 'installing the pinned Calico CNI before the remaining nodes join'
  helm repo add projectcalico https://docs.tigera.io/calico/charts --force-update >/dev/null
  helm upgrade --install calico-crds projectcalico/crd.projectcalico.org.v1 \
    --version "v${CALICO_VERSION}" --namespace tigera-operator --create-namespace --wait --timeout 15m
  helm upgrade --install calico projectcalico/tigera-operator \
    --version "v${CALICO_VERSION}" --namespace tigera-operator --wait --timeout 15m
  kubectl apply -f "$ROOT_DIR/kubernetes/calico-installation.yaml"
  kubectl wait --for=condition=Established crd/felixconfigurations.crd.projectcalico.org --timeout=5m
  kubectl apply -f "$ROOT_DIR/kubernetes/calico-felix.yaml"
  kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=10m
}

install_istio_gateway() {
  log 'installing the pinned Gateway API and Istio ambient mesh'
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/experimental-install.yaml"
  istioctl install --skip-confirmation --readiness-timeout 15m \
    --set profile=ambient \
    --set "meshConfig.extensionProviders[0].name=zerops-otlp" \
    --set "meshConfig.extensionProviders[0].opentelemetry.service=alloy.observability.svc.cluster.local" \
    --set "meshConfig.extensionProviders[0].opentelemetry.port=4317"
  kubectl label namespace istio-system pod-security.kubernetes.io/enforce=privileged --overwrite
  kubectl -n istio-system rollout status deployment/istiod --timeout=10m
  kubectl -n istio-system rollout status daemonset/ztunnel --timeout=10m
}

install_traefik_gateway() {
  local values="$ROOT_DIR/kubernetes/profiles/$K8S_PROFILE/traefik-values.yaml"
  [[ -f "$values" ]] || die "Traefik values are missing for profile $K8S_PROFILE"
  log "installing standard Gateway API and pinned Traefik ($gateway_replicas replicas)"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"
  helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
  helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
    --namespace traefik-system --create-namespace -f "$values" --wait --timeout 15m
  kubectl -n traefik-system rollout status deployment/traefik --timeout=10m
}

install_longhorn() {
  log "installing Longhorn with $storage_replicas storage replicas"
  kubectl apply -f "$ROOT_DIR/kubernetes/longhorn-node-prerequisites.yaml"
  kubectl -n kube-system rollout status daemonset/longhorn-node-prerequisites --timeout=10m
  helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null
  if [[ -f "$ROOT_DIR/kubernetes/profiles/$K8S_PROFILE/longhorn-values.yaml" ]]; then
    helm upgrade --install longhorn longhorn/longhorn --version "$LONGHORN_VERSION" \
      --namespace longhorn-system --create-namespace \
      -f "$ROOT_DIR/kubernetes/profiles/$K8S_PROFILE/longhorn-values.yaml" \
      --wait --timeout 20m
    kubectl -n longhorn-system set resources deployment/longhorn-driver-deployer \
      --containers=longhorn-driver-deployer \
      --requests=cpu=25m,memory=64Mi --limits=cpu=250m,memory=256Mi
    kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=10m
  else
    helm upgrade --install longhorn longhorn/longhorn --version "$LONGHORN_VERSION" \
      --namespace longhorn-system --create-namespace \
      --set csi.kubeletRootDir=/var/lib/kubelet \
      --set "defaultSettings.defaultReplicaCount=$storage_replicas" \
      --set defaultSettings.createDefaultDiskLabeledNodes=true \
      --wait --timeout 20m
  fi
  kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite
  if [[ "$observability" == advanced ]]; then
    kubectl -n longhorn-system annotate service longhorn-backend \
      prometheus.io/scrape='true' prometheus.io/port='9500' --overwrite
  fi
}

install_cert_manager() {
  log 'installing cert-manager'
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout 10m
}

install_metrics_server() {
  local values="$ROOT_DIR/kubernetes/profiles/$K8S_PROFILE/metrics-server-values.yaml"
  log "installing metrics-server ($metrics_server_replicas replicas)"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
  if [[ -f "$values" ]]; then
    helm upgrade --install metrics-server metrics-server/metrics-server \
      --version "$METRICS_SERVER_CHART_VERSION" --namespace kube-system \
      -f "$values" --wait --timeout 10m
  else
    helm upgrade --install metrics-server metrics-server/metrics-server \
      --version "$METRICS_SERVER_CHART_VERSION" --namespace kube-system \
      --set "replicas=$metrics_server_replicas" \
      --set 'args={--kubelet-insecure-tls}' --wait --timeout 10m
  fi
}

install_advanced_observability() {
  log 'installing full-profile in-cluster observability collectors and exporters'
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
    --version "$KUBE_STATE_METRICS_CHART_VERSION" --namespace observability \
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
}

require_env ZEROPS_PROJECT_ID
load_zerops_env
require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
wait_for_agents

log "starting all nested Kubernetes nodes for profile $K8S_PROFILE"
pids=()
for node in "${NODES[@]}"; do agent_request "$node" POST /v1/node/start >/dev/null & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done

log 'initializing the first stacked-etcd control plane'
init_response=$(agent_request "${CONTROL_PLANES[0]}" POST /v1/cluster/init)
ca_hash=$(jq -er .caHash <<<"$init_response")

kubeconfig=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubeconfig
mkdir -p "$(dirname "$kubeconfig")"
agent_request "${CONTROL_PLANES[0]}" GET /v1/cluster/kubeconfig > "$kubeconfig"
sed -i "s#^[[:space:]]*server:.*#    server: https://${CONTROL_PLANE_ENDPOINT}#" "$kubeconfig"
chmod 0600 "$kubeconfig"
export KUBECONFIG=$kubeconfig
printf 'KUBECONFIG=%s\n' "$kubeconfig" >> "${GITHUB_ENV:-/dev/null}"

api_deadline=$((SECONDS + 600))
until kubectl get --raw=/readyz >/dev/null 2>&1; do
  (( SECONDS < api_deadline )) || die 'Kubernetes API did not become ready within 10 minutes'
  sleep 3
done

[[ $(profile_json '.addons.cni') == calico ]] || die 'only the reviewed Calico CNI is supported'
install_calico

join_body=$(jq -cn --arg hash "$ca_hash" '{caHash:$hash}')
for node in "${CONTROL_PLANES[@]:1}"; do
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
  kubectl label node "$node" node-role.kubernetes.io/worker='' --overwrite
  if [[ "$storage" == longhorn ]]; then
    kubectl label node "$node" node.longhorn.io/create-default-disk=true --overwrite
  fi
done
kubectl wait --for=condition=Ready nodes --all --timeout=20m
kubectl -n calico-system rollout status daemonset/calico-node --timeout=15m
kubectl -n calico-system rollout status deployment/calico-kube-controllers --timeout=10m
for node in "${NODES[@]}"; do recover_terminating_node_pods "$node" 0; done
[[ "$observability" != advanced ]] || kubectl apply -f "$ROOT_DIR/kubernetes/calico-metrics.yaml"

if [[ "$gateway" == istio ]]; then
  kubectl apply -f "$ROOT_DIR/kubernetes/namespaces.yaml"
else
  kubectl apply -f "$ROOT_DIR/kubernetes/profiles/common/namespaces.yaml"
fi
kubectl label namespace kube-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace calico-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace tigera-operator pod-security.kubernetes.io/enforce=privileged --overwrite

case "$gateway" in
  istio) install_istio_gateway ;;
  traefik) install_traefik_gateway ;;
  *) die "unsupported gateway feature: $gateway" ;;
esac

case "$storage" in
  longhorn) install_longhorn ;;
  none) log 'dynamic storage disabled by the selected profile' ;;
  *) die "unsupported storage feature: $storage" ;;
esac

[[ "$cert_manager" != true ]] || install_cert_manager
install_metrics_server

case "$observability" in
  advanced) install_advanced_observability ;;
  platform) log '{"component":"cluster-bootstrap","observability":"zerops-platform","status":"enabled"}' ;;
  *) die "unsupported observability feature: $observability" ;;
esac

if [[ "$dashboard" == true ]]; then
  kubectl apply -f "$ROOT_DIR/kubernetes/headlamp.yaml"
  kubectl apply -f "$ROOT_DIR/kubernetes/headlamp-rbac.yaml"
fi

if [[ "$demo" == full ]]; then
  kubectl apply -f "$ROOT_DIR/kubernetes/demo.yaml"
  kubectl apply -f "$ROOT_DIR/kubernetes/istio-gateway.yaml"
else
  kubectl apply -f "$ROOT_DIR/kubernetes/profiles/$demo/demo.yaml"
  kubectl apply -f "$ROOT_DIR/kubernetes/profiles/common/gateway.yaml"
fi

if [[ "$security" == true ]]; then
  if [[ "$gateway" == istio ]]; then
    kubectl apply -f "$ROOT_DIR/kubernetes/security.yaml"
  else
    kubectl apply -f "$ROOT_DIR/kubernetes/profiles/common/security.yaml"
  fi
fi

kubectl -n workloads wait --for=condition=Available deployment/demo --timeout=10m
if [[ "$dashboard" == true ]]; then
  kubectl -n headlamp wait --for=condition=Available deployment/headlamp --timeout=10m
fi
if [[ "$gateway" == istio ]]; then
  kubectl -n istio-ingress wait --for=condition=Programmed gateway/public-gateway --timeout=10m
else
  kubectl -n traefik-system wait --for=condition=Programmed gateway/public-gateway --timeout=10m
  kubectl -n workloads wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    httproute/demo --timeout=10m
fi

log "{\"component\":\"cluster-bootstrap\",\"profile\":\"$K8S_PROFILE\",\"status\":\"ready\"}"
