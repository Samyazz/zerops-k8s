#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require zcli
require curl
require jq

if [[ -z "${K8S_AGENT_TOKEN:-}" ]]; then
  load_zerops_env
fi
require_env K8S_AGENT_TOKEN

current_service=
current_drained=false
restore_cordon() {
  if [[ "$current_drained" == true && -n "$current_service" && -s "${KUBECONFIG:-}" ]]; then
    kubectl uncordon "$current_service" >/dev/null 2>&1 || true
  fi
}
trap restore_cordon EXIT INT TERM

order=(k8sworker1 k8sworker2 k8sworker3)
if service_exists k8sworker4; then order+=(k8sworker4); fi
order+=(k8scp2 k8scp3 k8scp1)
targets=("${order[@]}")
if (( $# )); then
  targets=("$@")
fi
for service in "${targets[@]}"; do
  [[ " ${order[*]} " == *" $service "* ]] || die "refusing to roll an unknown node: $service"
done

init_response=$(agent_request k8scp1 POST /v1/cluster/init)
ca_hash=$(jq -er .caHash <<<"$init_response")
join_payload=$(jq -cn --arg hash "$ca_hash" '{caHash:$hash}')

mapfile -t interrupted_backups < <(
  kubectl -n longhorn-system get systembackups.longhorn.io -o json | jq -r \
    '.items[] | select(.status.state != "Ready") | .metadata.name'
)
if (( ${#interrupted_backups[@]} > 0 )); then
  log 'cleaning the disposable proof volume from an interrupted backup test'
  kubectl -n longhorn-system delete systembackups.longhorn.io "${interrupted_backups[@]}" --wait=false >/dev/null
  kubectl -n zerops-backup-validation delete pvc longhorn-backup-proof \
    --ignore-not-found --wait=true >/dev/null
fi

for service in "${order[@]}"; do
  [[ " ${targets[*]} " == *" $service "* ]] || continue
  current_service=$service
  current_drained=false
  drained=false
  disk_replacement=false
  if [[ "$service" == k8sworker* ]] && longhorn_disk_needs_replacement "$service"; then
    disk_replacement=true
  fi
  node_ready=$(kubectl get "node/$service" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$node_ready" == True ]]; then
    if [[ "$disk_replacement" != true ]]; then wait_longhorn_healthy; fi
    log "cordoning and draining $service before its rolling node restart"
    kubectl cordon "$service" >/dev/null
    safe_drain "$service"
    drained=true
    current_drained=true
  elif [[ -n "$node_ready" ]]; then
    log "removing the stale non-Ready node object before recovering $service"
    kubectl delete "node/$service" --ignore-not-found >/dev/null
  fi

  log "restarting the nested Kubernetes node: $service"
  node_state=$(agent_request "$service" GET /v1/state | jq -er '.status')
  if [[ "$node_state" == running ]]; then
    agent_request "$service" POST /v1/node/stop >/dev/null
  fi
  if [[ "$disk_replacement" == true ]]; then
    repair_replaced_longhorn_disk "$service"
  fi
  wait_for_agent "$service"
  agent_request "$service" POST /v1/node/start >/dev/null
  if [[ "$service" == k8scp1 ]]; then
    agent_request "$service" POST /v1/cluster/init >/dev/null
  else
    agent_request "$service" POST /v1/cluster/join "$join_payload" >/dev/null
  fi
  if [[ "$service" == k8sworker* ]]; then
    kubectl label node "$service" node-role.kubernetes.io/worker='' \
      node.longhorn.io/create-default-disk=true --overwrite >/dev/null
  fi
  kubectl wait "node/$service" --for=condition=Ready --timeout=15m
  if [[ "$disk_replacement" == true ]]; then
    wait_longhorn_disk_ready "$service"
  fi
  recover_terminating_node_pods "$service"
  if [[ "$drained" == true ]]; then
    kubectl uncordon "$service" >/dev/null
    current_drained=false
  fi
  wait_longhorn_healthy
done
