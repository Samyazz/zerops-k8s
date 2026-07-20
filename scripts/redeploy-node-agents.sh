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
current_stopped=false
push_agent_code=${PUSH_AGENT_CODE:-false}
[[ "$push_agent_code" == true || "$push_agent_code" == false ]] \
  || die 'PUSH_AGENT_CODE must be true or false'
source_revision=${GITHUB_SHA:-working}
version_name="github-${GITHUB_RUN_ID:-local}-${source_revision:0:12}-node-agent"

deploy_agent() {
  local service=$1 setup attempt result source_args=(--workspace-state all)
  case "$service" in
    k8scp1) setup=controlplane1 ;;
    k8scp2) setup=controlplane2 ;;
    k8scp3) setup=controlplane3 ;;
    k8sworker1) setup=worker1 ;;
    k8sworker2) setup=worker2 ;;
    k8sworker3) setup=worker3 ;;
    k8sworker4) setup=worker4 ;;
    *) die "no node-agent setup is mapped for $service" ;;
  esac
  if [[ ! -d "$ROOT_DIR/.git" ]]; then source_args=(--no-git); fi
  for attempt in 1 2 3; do
    set +e
    timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli push "$service" -P "$ZEROPS_PROJECT_ID" \
      --setup "$setup" --version-name "$version_name" --working-dir "$ROOT_DIR" \
      "${source_args[@]}"
    result=$?
    set -e
    (( result == 0 )) && return 0
    (( result != 124 )) || die "Zerops node-agent deployment timed out for $service"
    if (( attempt < 3 )); then
      log "node-agent deployment failed on attempt $attempt; retrying $service"
      sleep 5
    fi
  done
  die "node-agent deployment failed after three attempts: $service"
}
restore_cordon() {
  local response
  set +e
  if [[ "$current_stopped" == true && -n "$current_service" && -s "${KUBECONFIG:-}" ]]; then
    log "recovering stopped node after an interrupted or failed node-agent delivery: $current_service"
    wait_for_agent "$current_service"
    agent_request "$current_service" POST /v1/node/start >/dev/null
    if [[ "$current_service" == k8scp1 ]]; then
      agent_request "$current_service" POST /v1/cluster/init >/dev/null
    else
      response=${join_payload:-}
      [[ -n "$response" ]] && agent_request "$current_service" POST /v1/cluster/join "$response" >/dev/null
    fi
    kubectl wait "node/$current_service" --for=condition=Ready --timeout=15m >/dev/null
    recover_terminating_node_pods "$current_service" 60
    current_stopped=false
  fi
  if [[ "$current_drained" == true && -n "$current_service" && -s "${KUBECONFIG:-}" ]]; then
    kubectl uncordon "$current_service" >/dev/null 2>&1 || true
    current_drained=false
  fi
  set -e
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

for service in "${targets[@]}"; do
  if [[ "$service" == k8sworker* ]] && longhorn_disk_is_empty "$service"; then
    log "repairing an empty Longhorn disk definition before rolling $service"
    wait_longhorn_disk_ready "$service"
  fi
done

for service in "${order[@]}"; do
  [[ " ${targets[*]} " == *" $service "* ]] || continue
  current_service=$service
  current_drained=false
  drained=false
  disk_replacement=false
  stale_node=false
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
    stale_node=true
  fi

  log "restarting the nested Kubernetes node: $service"
  node_state=$(agent_request "$service" GET /v1/state | jq -er '.status')
  if [[ "$node_state" == running ]]; then
    agent_request "$service" POST /v1/node/stop >/dev/null
  fi
  current_stopped=true
  if [[ "$disk_replacement" == true ]]; then
    repair_replaced_longhorn_disk "$service"
  fi
  if [[ "$stale_node" == true ]]; then
    log "removing the stale non-Ready node object before recovering $service"
    kubectl delete "node/$service" --ignore-not-found >/dev/null
  fi
  if [[ "$push_agent_code" == true ]]; then
    log "deploying the reviewed node-agent revision while $service is drained"
    deploy_agent "$service"
  fi
  wait_for_agent "$service"
  agent_request "$service" POST /v1/node/start >/dev/null
  if [[ "$service" == k8scp1 ]]; then
    agent_request "$service" POST /v1/cluster/init >/dev/null
  else
    agent_request "$service" POST /v1/cluster/join "$join_payload" >/dev/null
  fi
  current_stopped=false
  deadline=$((SECONDS + 300))
  until kubectl get "node/$service" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "node did not register after restart: $service"
    sleep 3
  done
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
