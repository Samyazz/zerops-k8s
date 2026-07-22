#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/node-agent-artifact.sh"

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
canary_only=${NODE_AGENT_CANARY_ONLY:-false}
[[ "$canary_only" == true || "$canary_only" == false ]] \
  || die 'NODE_AGENT_CANARY_ONLY must be true or false'
[[ "$canary_only" != true || "$push_agent_code" == true ]] \
  || die 'NODE_AGENT_CANARY_ONLY requires PUSH_AGENT_CODE=true'
agent_artifact_dir=
version_name=
canary_service=k8sagentcanary
canary_created=false

deploy_agent() {
  local service=$1 setup attempt result
  if [[ "$service" == "$canary_service" ]]; then
    setup=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .setup' "$PROFILE_FILE")
  else
    setup=$(jq -er --arg service "$service" '.services[] | select(.hostname == $service) | .setup' "$PROFILE_FILE" 2>/dev/null || true)
    if [[ -z "$setup" ]]; then
      setup="worker${service#k8sworker}"
      [[ "$K8S_PROFILE" == full ]] || setup="${setup}-${K8S_PROFILE}"
    fi
  fi
  for attempt in 1 2 3; do
    set +e
    timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli service deploy "$service" -P "$ZEROPS_PROJECT_ID" \
      --setup "$setup" --version-name "${version_name}-${attempt}" \
      --working-dir "$agent_artifact_dir" --path-to-file-or-dir .
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
  if [[ "$canary_created" == true ]]; then
    log 'removing the disposable node-agent delivery canary'
    zcli service delete "$canary_service" -P "$ZEROPS_PROJECT_ID" --confirm >/dev/null 2>&1 || true
    canary_created=false
  fi
  set -e
}
trap restore_cordon EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

preflight_agent_delivery() {
  local import_file worker_mode worker_cpu worker_ram worker_disk

  if service_exists "$canary_service"; then
    log 'removing a stale node-agent delivery canary from an interrupted run'
    zcli service delete "$canary_service" -P "$ZEROPS_PROJECT_ID" --confirm >/dev/null
  fi
  worker_cpu=$(cluster_tag_value worker-cpu)
  worker_ram=$(cluster_tag_value worker-ram)
  worker_disk=$(cluster_tag_value worker-disk)
  worker_mode=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpuMode' "$PROFILE_FILE")
  worker_cpu=${worker_cpu:-$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")}
  worker_ram=${worker_ram:-$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")}
  worker_disk=${worker_disk:-$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")}
  [[ "$worker_cpu" =~ ^[0-9]+$ && "$worker_ram" =~ ^[0-9]+$ && "$worker_disk" =~ ^[0-9]+$ ]] \
    || die 'worker resource tags must be whole numbers before the rollout canary is created'

  import_file=$(mktemp)
  printf '%s\n' \
    'services:' \
    "  - hostname: $canary_service" \
    '    type: docker@26.1.5' \
    '    minContainers: 1' \
    '    maxContainers: 1' \
    '    verticalAutoscaling:' \
    "      cpuMode: $worker_mode" \
    "      minCpu: $worker_cpu" \
    "      maxCpu: $worker_cpu" \
    "      startCpuCoreCount: $worker_cpu" \
    "      minRam: $worker_ram" \
    "      maxRam: $worker_ram" \
    "      minDisk: $worker_disk" \
    "      maxDisk: $worker_disk" \
    '      swapEnabled: false' >"$import_file"

  log "proving Zerops can allocate a ${worker_cpu}-CPU/${worker_ram}GB Docker rollout canary before any node is drained"
  canary_created=true
  if ! zcli project service-import "$import_file" -P "$ZEROPS_PROJECT_ID" >/dev/null; then
    rm -f "$import_file"
    die 'Zerops could not allocate the rollout canary; no Kubernetes node was changed'
  fi
  rm -f "$import_file"
  deploy_agent "$canary_service"
  wait_for_agent "$canary_service"
  agent_request "$canary_service" GET /v1/state | jq -e '.status == "missing"' >/dev/null
  zcli service delete "$canary_service" -P "$ZEROPS_PROJECT_ID" --confirm >/dev/null
  canary_created=false
  log 'node-agent delivery canary passed and was removed'
}

# Build and test the exact committed agent before any Kubernetes node is
# cordoned. zcli `service deploy` uploads this runtime artifact directly and
# therefore does not depend on Zerops' temporary build-container capacity.
if [[ "$push_agent_code" == true ]]; then
  prepare_node_agent_artifact
  agent_artifact_dir=$NODE_AGENT_ARTIFACT_DIR
  version_name=$NODE_AGENT_VERSION_NAME
  if [[ "$K8S_PROFILE" != staging ]]; then
    preflight_agent_delivery
  else
    log 'staging forbids orbiting services; skipping the disposable rollout canary'
  fi
  if [[ "$canary_only" == true ]]; then
    log 'node-agent delivery canary-only check completed; no Kubernetes node was changed'
    exit 0
  fi
fi

order=("${WORKERS[@]}")
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
for node in "${optional_workers[@]}"; do
  if service_exists "$node"; then order+=("$node"); fi
done
for ((index=${#CONTROL_PLANES[@]}-1; index>=0; index--)); do
  order+=("${CONTROL_PLANES[index]}")
done
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

if profile_capability storageHealth; then
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
    kubectl label node "$service" node-role.kubernetes.io/worker='' --overwrite >/dev/null
    if profile_capability storageHealth; then
      kubectl label node "$service" node.longhorn.io/create-default-disk=true --overwrite >/dev/null
    fi
  fi
  if [[ "$K8S_PROFILE" == staging && "$service" == k8sworker* && "$drained" == true ]]; then
    # The single staging worker is also the only eligible Typha host. Leaving
    # it cordoned until Calico is Ready creates a dependency cycle: Typha
    # cannot schedule, so calico-node cannot make the node Ready. Make the
    # recovered worker schedulable as soon as it re-registers.
    log "uncordoning the single staging worker so Calico Typha can recover"
    kubectl uncordon "$service" >/dev/null
    current_drained=false
    drained=false
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
