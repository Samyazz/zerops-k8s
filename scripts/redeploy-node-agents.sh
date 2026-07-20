#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require zcli
require curl
require jq
require sha256sum
require tar

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
if [[ -d "$ROOT_DIR/.git" ]]; then
  source_revision=${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}
else
  source_revision=working
fi
version_name="github-${GITHUB_RUN_ID:-local}-${source_revision:0:12}-node-agent"
agent_artifact_dir=

prepare_agent_artifact() {
  local tool_root archive tmp go_bin current_version artifact_parent
  tool_root="${RUNNER_TEMP:-/tmp}/zerops-k8s-go-${GO_VERSION}"
  go_bin="$tool_root/bin/go"
  if [[ ! -x "$go_bin" ]]; then
    require_env GO_LINUX_AMD64_SHA256
    tmp=$(mktemp -d)
    archive="$tmp/go${GO_VERSION}.linux-amd64.tar.gz"
    log "installing the pinned Go ${GO_VERSION} toolchain for the reviewed node-agent artifact"
    curl -fsSLo "$archive" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    printf '%s  %s\n' "$GO_LINUX_AMD64_SHA256" "$archive" | sha256sum -c -
    mkdir -p "$tool_root"
    tar -xzf "$archive" -C "$tool_root" --strip-components=1
  fi
  current_version=$($go_bin version | awk '{print $3}')
  [[ "$current_version" == "go${GO_VERSION}" ]] \
    || die "pinned Go toolchain mismatch: expected go${GO_VERSION}, got $current_version"

  artifact_parent="${RUNNER_TEMP:-/tmp}/zerops-k8s-agent-${source_revision:0:12}"
  agent_artifact_dir="$artifact_parent/runtime"
  if [[ ! -x "$agent_artifact_dir/dist/zerops-k8s" || ! -x "$agent_artifact_dir/s3-fetch" ]]; then
    [[ -d "$ROOT_DIR/.git" ]] \
      || die 'a committed Git checkout is required to assemble the reviewed node-agent artifact'
    mkdir -p "$agent_artifact_dir"
    git -C "$ROOT_DIR" archive --format=tar "$source_revision" | tar -xf - -C "$agent_artifact_dir"
    mkdir -p "$agent_artifact_dir/dist"
    (
      cd "$agent_artifact_dir"
      CGO_ENABLED=0 "$go_bin" test ./...
      CGO_ENABLED=0 "$go_bin" build -trimpath -ldflags='-s -w' -o dist/zerops-k8s ./cmd/zerops-k8s
      CGO_ENABLED=0 "$go_bin" build -trimpath -ldflags='-s -w' -o s3-fetch ./cmd/s3-fetch
    )
    mkdir -p "${RUNNER_TEMP:-/tmp}/evidence"
    (
      cd "$agent_artifact_dir"
      sha256sum dist/zerops-k8s s3-fetch
    ) >"${RUNNER_TEMP:-/tmp}/evidence/node-agent-artifact.sha256"
  fi
}

deploy_agent() {
  local service=$1 setup attempt result
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
  set -e
}
trap restore_cordon EXIT INT TERM

# Build and test the exact committed agent before any Kubernetes node is
# cordoned. zcli `service deploy` uploads this runtime artifact directly and
# therefore does not depend on Zerops' temporary build-container capacity.
if [[ "$push_agent_code" == true ]]; then
  prepare_agent_artifact
fi

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
