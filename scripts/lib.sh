#!/usr/bin/env bash
# shellcheck disable=SC2034 # ROOT_DIR is intentionally exported to sourcing scripts.
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly CONTROL_PLANES=(k8scp1 k8scp2 k8scp3)
readonly WORKERS=(k8sworker1 k8sworker2 k8sworker3)
readonly NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")

log() { printf '[zerops-k8s] %s\n' "$*"; }
die() { printf '[zerops-k8s] ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

require_env() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || die "required environment variable is unset: $key"
  done
}

load_zerops_env() {
  require_env ZEROPS_PROJECT_ID
  local env_file attempt
  env_file=$(mktemp)
  # zCLI emits shell-compatible dotenv. Values never pass through workflow logs.
  # Write to a file first so a timed-out/API-error response is never sourced.
  for attempt in 1 2 3 4 5; do
    if timeout 60 zcli project env -P "$ZEROPS_PROJECT_ID" --service k8scp1 >"$env_file"; then
      set -a
      # shellcheck disable=SC1090
      source "$env_file"
      set +a
      rm -f "$env_file"
      return 0
    fi
    : >"$env_file"
    log "Zerops environment fetch failed on attempt $attempt; retrying"
    sleep 3
  done
  rm -f "$env_file"
  die 'failed to load Zerops environment after five attempts'
}

agent_request() {
  local node=$1 method=$2 path=$3 data=${4:-}
  local args=(--fail --silent --show-error --connect-timeout 10 --max-time 1200
    --retry 5 --retry-delay 2 --retry-max-time 90 --retry-all-errors
    -X "$method" -H "Authorization: Bearer $K8S_AGENT_TOKEN")
  if [[ -n "$data" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  curl "${args[@]}" "http://${node}:18080${path}"
}

wait_for_agent() {
  local node=$1 deadline=$((SECONDS + 900))
  until curl --fail --silent --connect-timeout 3 --max-time 5 "http://${node}:18080/healthz" >/dev/null; do
    (( SECONDS < deadline )) || die "agent did not become healthy: $node"
    sleep 3
  done
}

wait_for_agents() {
  local node pids=()
  for node in "${NODES[@]}"; do wait_for_agent "$node" & pids+=("$!"); done
  for node in "${pids[@]}"; do wait "$node"; done
}

terminating_node_pods() {
  local node=$1
  kubectl get pods -A --field-selector "spec.nodeName=$node" -o json | jq -r '
    .items[]
    | select(.metadata.deletionTimestamp != null)
    | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)
    | [.metadata.namespace, .metadata.name]
    | @tsv
  '
}

recover_terminating_node_pods() {
  local node=$1 grace_seconds=${2:-180} deadline pods namespace name
  deadline=$((SECONDS + grace_seconds))
  while true; do
    pods=$(terminating_node_pods "$node")
    [[ -z "$pods" ]] && return 0
    (( SECONDS >= deadline )) && break
    sleep 10
  done

  log "force-deleting pods left Terminating on recovered node $node"
  while IFS=$'\t' read -r namespace name; do
    [[ -n "$namespace" && -n "$name" ]] || continue
    kubectl -n "$namespace" delete pod "$name" --ignore-not-found \
      --force --grace-period=0 --wait=false >/dev/null
  done <<<"$pods"

  deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    [[ -z $(terminating_node_pods "$node") ]] && return 0
    sleep 5
  done
  die "pods remained Terminating on recovered node after forced API deletion: $node"
}

recover_all_terminating_pods() {
  local grace_seconds=${1:-180} deadline node pods
  deadline=$((SECONDS + grace_seconds))
  while true; do
    pods=$(kubectl get pods -A -o json | jq \
      '[.items[] | select(.metadata.deletionTimestamp != null) | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)] | length')
    [[ "$pods" -eq 0 ]] && return 0
    (( SECONDS >= deadline )) && break
    sleep 10
  done

  while read -r node; do
    [[ -n "$node" ]] || continue
    recover_terminating_node_pods "$node" 0
  done < <(kubectl get nodes -o name | sed 's#^node/##')
}

api_put() {
  local path=$1 payload=$2 response status
  response=$(mktemp)
  status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    -X PUT -H "Authorization: Bearer $ZEROPS_TOKEN" -H 'Content-Type: application/json' \
    --data "$payload" "${ZEROPS_API_BASE:-https://api.app-prg1.zerops.io/api/rest/public}${path}")
  if [[ "$status" != 2* ]]; then
    jq '{error: (.error.code // .error // "request failed"), message: (.error.message // "")}' "$response" >&2 || true
    return 1
  fi
  jq '{status: (.status // .process.status // "accepted"), projectId: (.project.id // .projectId // null)}' "$response"
}

service_exists() {
  local name=$1 response
  response=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?nameContains=${name}&limit=100" '' "$response"
  jq -e --arg name "$name" '.list | any(.name == $name)' "$response" >/dev/null
}

api_request_file() {
  local method=$1 path=$2 payload=$3 response=$4 status
  local args=(--silent --show-error --output "$response" --write-out '%{http_code}'
    -X "$method" -H "Authorization: Bearer $ZEROPS_TOKEN")
  if [[ -n "$payload" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$payload")
  fi
  status=$(curl "${args[@]}" "${ZEROPS_API_BASE:-https://api.app-prg1.zerops.io/api/rest/public}${path}")
  if [[ "$status" != 2* ]]; then
    jq '{error: (.error.code // .error // "request failed"), message: (.error.message // "")}' "$response" >&2 || true
    return 1
  fi
}

wait_public_process() {
  local process_id=$1 response status deadline=$((SECONDS + 1800))
  response=$(mktemp)
  while (( SECONDS < deadline )); do
    api_request_file GET "/process/${process_id}" '' "$response"
    status=$(jq -er '.status' "$response")
    case "$status" in
      FINISHED) return 0 ;;
      FAILED|CANCELED)
        jq '{id, status, actionName}' "$response" >&2
        return 1
        ;;
    esac
    sleep 2
  done
  die "Zerops process did not finish within 30 minutes: $process_id"
}

project_json() {
  local response attempt
  response=$(mktemp)
  for attempt in 1 2 3 4 5; do
    if api_request_file GET "/project/${ZEROPS_PROJECT_ID}" '' "$response"; then
      printf '%s\n' "$response"
      return 0
    fi
    sleep $((attempt * 2))
  done
  rm -f "$response"
  return 1
}

cluster_tag_value() {
  local key=$1 response value
  response=$(project_json) || return 1
  value=$(jq -r --arg prefix "zerops-k8s.${key}=" \
    '.tagList[]? | select(startswith($prefix)) | ltrimstr($prefix)' "$response" | tail -n 1)
  rm -f "$response"
  printf '%s\n' "$value"
}

assert_repository_cluster() {
  local state repository expected_repository response
  response=$(project_json) || die 'could not read the Zerops-side cluster lock after five attempts'
  state=$(jq -r '[.tagList[]? | select(startswith("zerops-k8s.state=")) | ltrimstr("zerops-k8s.state=")] | last // ""' "$response")
  repository=$(jq -r '[.tagList[]? | select(startswith("zerops-k8s.repository=")) | ltrimstr("zerops-k8s.repository=")] | last // ""' "$response")
  rm -f "$response"
  expected_repository=${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}
  [[ "$state" != cleanup-failed ]] \
    || die 'the Zerops-side lock is cleanup-failed; run the explicit destroy workflow before continuing'
  [[ "$state" != upgrade-failed || "${ALLOW_UPGRADE_RECOVERY:-false}" == true ]] \
    || die 'the Zerops-side lock is upgrade-failed; resume the controlled upgrade workflow before other cluster changes'
  [[ -n "$state" && "$state" != destroyed ]] \
    || die 'no live repository-managed cluster is available for this operation'
  [[ -z "$repository" || "$repository" == unknown || "${repository,,}" == "${expected_repository,,}" ]] \
    || die "this Zerops project is managed by $repository, not $expected_repository"
}

set_cluster_state() {
  local state=$1 repository=${2:-${GITHUB_REPOSITORY:-unknown}} run_id=${3:-${GITHUB_RUN_ID:-local}}
  local response payload current
  response=$(project_json)
  current=$(mktemp)
  jq --arg state "$state" --arg repository "$repository" --arg run "$run_id" '
    .tagList = ([.tagList[]? | select(
      (startswith("zerops-k8s.managed=") | not)
      and (startswith("zerops-k8s.repository=") | not)
      and (startswith("zerops-k8s.state=") | not)
      and (startswith("zerops-k8s.run=") | not)
    )] + [
      "zerops-k8s.managed=true",
      "zerops-k8s.repository=" + $repository,
      "zerops-k8s.state=" + $state,
      "zerops-k8s.run=" + $run
    ]) |
    {name, description, publicIpV4Shared, tagList}
  ' "$response" > "$current"
  payload=$(<"$current")
  api_request_file PUT "/project/${ZEROPS_PROJECT_ID}" "$payload" "$response"
  log "Zerops project cluster state set to $state"
}

set_cluster_tag() {
  local key=$1 value=$2 response payload current prefix
  [[ "$key" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid cluster tag key: $key"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid cluster tag value for $key"
  prefix="zerops-k8s.${key}="
  response=$(project_json)
  current=$(mktemp)
  jq --arg prefix "$prefix" --arg tag "${prefix}${value}" '
    .tagList = ([.tagList[]? | select(startswith($prefix) | not)] + [$tag])
    | {name, description, publicIpV4Shared, tagList}
  ' "$response" >"$current"
  payload=$(<"$current")
  api_request_file PUT "/project/${ZEROPS_PROJECT_ID}" "$payload" "$response"
  rm -f "$current" "$response"
  log "updated Zerops-side cluster setting: $key"
}

wait_longhorn_healthy() {
  local deadline=$((SECONDS + 1200)) unhealthy
  kubectl get crd volumes.longhorn.io >/dev/null 2>&1 || return 0
  while (( SECONDS < deadline )); do
    unhealthy=$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq \
      '[.items[] | select(.status.robustness != "healthy")] | length')
    [[ "$unhealthy" -eq 0 ]] && return 0
    sleep 10
  done
  die 'Longhorn volumes did not return to healthy before the disruption deadline'
}

safe_drain() {
  local node=$1 result blockers
  set +e
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force \
    --grace-period=60 --timeout=3m --skip-wait-for-delete-timeout=60 >/dev/null
  result=$?
  set -e
  (( result == 0 )) && return 0

  # kubectl drain can leave its watch open after every evictable Pod has
  # disappeared. Fail closed unless an independent API read proves that only
  # static and DaemonSet Pods remain on the node.
  blockers=$(kubectl get pods -A --field-selector "spec.nodeName=$node" -o json | jq '
    [.items[]
      | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)
      | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet")
    ] | length
  ')
  [[ "$blockers" -eq 0 ]] || die "node drain failed with $blockers evictable Pods remaining: $node"
  log "drain watch timed out after all evictable Pods left $node; continuing from verified API state"
}

repair_replaced_longhorn_disk() {
  local node=$1 replicas deadline ready
  kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1 || return 0

  replicas=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq \
    --arg node "$node" '[.items[] | select(.spec.nodeID == $node)] | length')
  [[ "$replicas" -eq 0 ]] \
    || die "refusing to replace the stale Longhorn disk record on $node because it still owns $replicas replicas"

  log "recreating the stale empty Longhorn disk record after filesystem replacement: $node"
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    ready=$(kubectl get "node/$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" != True ]] && break
    sleep 3
  done
  [[ "$ready" != True ]] || die "node did not become NotReady before Longhorn disk replacement: $node"
  kubectl -n longhorn-system patch "nodes.longhorn.io/$node" --type=merge \
    -p '{"spec":{"allowScheduling":false}}' >/dev/null
  kubectl -n longhorn-system delete "nodes.longhorn.io/$node" --wait=true >/dev/null
}

longhorn_disk_is_empty() {
  local node=$1
  kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json 2>/dev/null | jq -e \
    '(.spec.disks // {}) | length == 0' >/dev/null
}

longhorn_disk_needs_replacement() {
  local node=$1
  kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json 2>/dev/null | jq -e '
    any(.status.diskStatus[]?;
      any(.conditions[]?;
        .type == "Ready" and .status == "False" and .reason == "DiskFilesystemChanged")
      or (
        .storageMaximum == 0
        and any(.conditions[]?;
          .type == "Ready" and .status == "False" and .reason == "NodeNotReady")
      )
    )
  ' >/dev/null
}

wait_longhorn_disk_ready() {
  local node=$1 deadline=$((SECONDS + 600)) ready disk_count capacity capacity_kib percentage reserved payload
  while (( SECONDS < deadline )); do
    disk_count=$(kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json 2>/dev/null | jq \
      '(.spec.disks // {}) | length' 2>/dev/null || true)
    if [[ "$disk_count" == 0 ]]; then
      capacity=$(kubectl get "node/$node" -o jsonpath='{.status.capacity.ephemeral-storage}' 2>/dev/null || true)
      percentage=$(kubectl -n longhorn-system get settings.longhorn.io \
        storage-reserved-percentage-for-default-disk -o jsonpath='{.value}' 2>/dev/null || true)
      capacity_kib=${capacity%Ki}
      if [[ "$capacity" =~ ^[0-9]+Ki$ && "$percentage" =~ ^[0-9]+$ ]]; then
        reserved=$((capacity_kib * 1024 * percentage / 100))
        payload=$(jq -cn --argjson reserved "$reserved" '{spec:{allowScheduling:true,disks:{"default-disk-zerops":{allowScheduling:true,diskDriver:"",diskType:"filesystem",evictionRequested:false,path:"/var/lib/longhorn/",storageReserved:$reserved,tags:[]}}}}')
        log "configuring a default Longhorn disk on $node"
        kubectl -n longhorn-system patch "nodes.longhorn.io/$node" --type=merge -p "$payload" >/dev/null
      fi
    fi
    ready=$(kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json 2>/dev/null | jq -r \
      '[.status.diskStatus[]?.conditions[]? | select(.type == "Ready") | .status] | first // ""')
    [[ "$ready" == True ]] && return 0
    sleep 5
  done
  die "replacement Longhorn disk did not become Ready: $node"
}

store_project_secret() {
  local key=$1 value=$2 response payload process_id
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid Zerops project secret key: $key"
  [[ "$value" != *$'\n'* ]] || die "secret $key contains a newline and cannot be stored"
  payload=$(jq -cn --arg key "$key" --arg content "$value" \
    '{key:$key, content:$content, sensitive:true}')
  response=$(mktemp)
  api_request_file POST "/project/${ZEROPS_PROJECT_ID}/env" "$payload" "$response"
  process_id=$(jq -er '.id' "$response")
  wait_public_process "$process_id"
}

store_project_variable() {
  local key=$1 value=$2 response payload process_id
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid Zerops project variable key: $key"
  [[ "$value" != *$'\n'* ]] || die "project variable $key contains a newline and cannot be stored"
  payload=$(jq -cn --arg key "$key" --arg content "$value" \
    '{key:$key, content:$content, sensitive:false}')
  response=$(mktemp)
  api_request_file POST "/project/${ZEROPS_PROJECT_ID}/env" "$payload" "$response"
  process_id=$(jq -er '.id' "$response")
  wait_public_process "$process_id"
}
