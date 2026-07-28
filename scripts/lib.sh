#!/usr/bin/env bash
# shellcheck disable=SC2034 # ROOT_DIR is intentionally exported to sourcing scripts.
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR

# The selected profile descriptor is the topology/capability source of truth.
# Keep `full` as the default so existing callers remain backward compatible.
K8S_PROFILE=${K8S_PROFILE:-full}
case "$K8S_PROFILE" in
  full|production|staging) ;;
  *) printf '[zerops-k8s] ERROR: unknown K8S_PROFILE: %s\n' "$K8S_PROFILE" >&2; exit 1 ;;
esac
readonly K8S_PROFILE
PROFILE_FILE="$ROOT_DIR/profiles/$K8S_PROFILE.json"
readonly PROFILE_FILE
[[ -f "$PROFILE_FILE" ]] \
  || { printf '[zerops-k8s] ERROR: profile descriptor is missing: %s\n' "$PROFILE_FILE" >&2; exit 1; }

profile_json() {
  local filter=${1:?profile_json requires a jq filter}
  jq -r "($filter) | if . == null then error(\"profile value is null\") else . end" \
    "$PROFILE_FILE"
}

profile_capability() {
  local capability=${1:?profile_capability requires a capability name}
  [[ "$capability" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
  jq -e --arg capability "$capability" \
    '.capabilities[$capability] == true' "$PROFILE_FILE" >/dev/null
}

mapfile -t CONTROL_PLANES < <(profile_json '.topology.controlPlanes[]')
mapfile -t WORKERS < <(profile_json '.topology.workers[]')
readonly CONTROL_PLANES WORKERS
readonly NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")
CONTROL_PLANE_PORT=$(profile_json '.topology.controlPlaneEndpoint.port')
CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT:-${K8S_CONTROL_PLANE_ENDPOINT:-}}
EDGE_ENABLED=$(profile_json '.topology.edge.enabled')
EDGE_HOSTNAME=$(jq -r '.topology.edge.hostname // ""' "$PROFILE_FILE")
VRRP_PREFIX_LENGTH=$(jq -r '.topology.edge.vrrpPrefixLength // ""' "$PROFILE_FILE")
VRRP_HOST_OCTET=$(jq -r '.topology.edge.vrrpHostOctet // ""' "$PROFILE_FILE")
VRRP_VIRTUAL_ROUTER_ID=$(jq -r '.topology.edge.vrrpVirtualRouterId // ""' "$PROFILE_FILE")
VRRP_VIP=${VRRP_VIP:-${K8S_VRRP_VIP:-}}
BACKUP_ENABLED=$(profile_json '.topology.backup.enabled')
BACKUP_HOSTNAME=$(jq -r '.topology.backup.hostname // ""' "$PROFILE_FILE")
NODE_IMAGE_MODE=$(profile_json '.nodeImage.mode')
readonly CONTROL_PLANE_PORT EDGE_ENABLED EDGE_HOSTNAME
readonly VRRP_PREFIX_LENGTH VRRP_HOST_OCTET VRRP_VIRTUAL_ROUTER_ID
readonly BACKUP_ENABLED BACKUP_HOSTNAME NODE_IMAGE_MODE

log() { printf '[zerops-k8s] %s\n' "$*"; }
die() { printf '[zerops-k8s] ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

require_env() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || die "required environment variable is unset: $key"
  done
}

ipv4_to_int() {
  local address=${1:?ipv4_to_int requires an address}
  local a b c d octet
  IFS=. read -r a b c d <<<"$address"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && "$address" != *.*.*.*.* ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1
  done
  printf '%s\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

int_to_ipv4() {
  local value=${1:?int_to_ipv4 requires an integer}
  printf '%d.%d.%d.%d\n' \
    "$(( (value >> 24) & 255 ))" "$(( (value >> 16) & 255 ))" \
    "$(( (value >> 8) & 255 ))" "$(( value & 255 ))"
}

derive_vrrp_vip() {
  local source_ip=${1:?derive_vrrp_vip requires a project IPv4 address}
  local source_int subnet_size network_int broadcast_int last_24_network vip_int
  [[ "$VRRP_PREFIX_LENGTH" =~ ^([1-9]|[12][0-9]|30)$ ]] \
    || die "invalid profile VRRP prefix length: $VRRP_PREFIX_LENGTH"
  [[ "$VRRP_HOST_OCTET" =~ ^([1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]] \
    || die "invalid profile VRRP host octet: $VRRP_HOST_OCTET"
  source_int=$(ipv4_to_int "$source_ip") \
    || die "cannot derive the VRRP VIP from invalid address: $source_ip"
  subnet_size=$((1 << (32 - VRRP_PREFIX_LENGTH)))
  network_int=$((source_int / subnet_size * subnet_size))
  broadcast_int=$((network_int + subnet_size - 1))
  last_24_network=$((broadcast_int - 255))
  vip_int=$((last_24_network + VRRP_HOST_OCTET))
  int_to_ipv4 "$vip_int"
}

resolve_vrrp_topology() {
  local source_ip=${1:-}
  local derived_vip
  if [[ -z "$source_ip" ]]; then
    source_ip=$(getent ahostsv4 "${EDGE_HOSTNAME}.zerops" \
      | awk '{print $1}' | sort -u | head -n 1)
  fi
  [[ -n "$source_ip" ]] || die "could not resolve ${EDGE_HOSTNAME}.zerops to derive the VRRP VIP"
  derived_vip=$(derive_vrrp_vip "$source_ip")
  if [[ -n "${K8S_VRRP_VIP:-}" && "$K8S_VRRP_VIP" != "$derived_vip" ]]; then
    die "stored K8S_VRRP_VIP $K8S_VRRP_VIP conflicts with derived VIP $derived_vip"
  fi
  VRRP_VIP=$derived_vip
  CONTROL_PLANE_ENDPOINT="${VRRP_VIP}:${CONTROL_PLANE_PORT}"
  export VRRP_VIP CONTROL_PLANE_ENDPOINT
}

load_zerops_env() {
  require_env ZEROPS_PROJECT_ID
  local env_file attempt
  env_file=$(mktemp)
  # zCLI emits shell-compatible dotenv. Values never pass through workflow logs.
  # Write to a file first so a timed-out/API-error response is never sourced.
  for attempt in 1 2 3 4 5; do
    if timeout 60 zcli project env -P "$ZEROPS_PROJECT_ID" --service k8scp1 >"$env_file"; then
      # The workflow-selected descriptor is immutable for the whole process.
      # A stored project marker with the same name is metadata, not an input
      # allowed to overwrite the readonly selection made above.
      sed -i '/^K8S_PROFILE=/d' "$env_file"
      set -a
      # shellcheck disable=SC1090
      if ! source "$env_file"; then
        set +a
        rm -f "$env_file"
        die 'Zerops returned an environment file that could not be loaded safely'
      fi
      set +a
      rm -f "$env_file"
      if [[ -n "${K8S_VRRP_VIP:-}" ]]; then
        resolve_vrrp_topology "$K8S_VRRP_VIP"
      elif [[ -n "${K8S_CONTROL_PLANE_ENDPOINT:-}" ]]; then
        CONTROL_PLANE_ENDPOINT=$K8S_CONTROL_PLANE_ENDPOINT
        export CONTROL_PLANE_ENDPOINT
      fi
      return 0
    fi
    : >"$env_file"
    log "Zerops environment fetch failed on attempt $attempt; retrying"
    sleep 3
  done
  rm -f "$env_file"
  die 'failed to load Zerops environment after five attempts'
}

load_backup_env() {
  [[ "$BACKUP_ENABLED" == true && -n "$BACKUP_HOSTNAME" ]] \
    || die "profile $K8S_PROFILE has no managed backup environment"
  require_env ZEROPS_PROJECT_ID
  local env_file attempt apiUrl bucketName accessKeyId secretAccessKey
  env_file=$(mktemp)
  # A fresh startWithoutCode node has no yaml-baked sibling aliases yet. Read
  # the managed object-storage service in its own context and immediately map
  # only its four connection fields to the names shared by the workflows.
  for attempt in 1 2 3 4 5; do
    if timeout 60 zcli project env -P "$ZEROPS_PROJECT_ID" --service "$BACKUP_HOSTNAME" >"$env_file"; then
      sed -i '/^K8S_PROFILE=/d' "$env_file"
      set -a
      # shellcheck disable=SC1090
      if ! source "$env_file"; then
        set +a
        rm -f "$env_file"
        die 'Zerops returned a backup-service environment that could not be loaded safely'
      fi
      set +a
      rm -f "$env_file"
      require_env apiUrl bucketName accessKeyId secretAccessKey
      export K8S_IMAGE_STORAGE_ENDPOINT=$apiUrl
      export K8S_IMAGE_STORAGE_BUCKET=$bucketName
      export AWS_ACCESS_KEY_ID=$accessKeyId
      export AWS_SECRET_ACCESS_KEY=$secretAccessKey
      unset apiUrl bucketName accessKeyId secretAccessKey
      return 0
    fi
    : >"$env_file"
    log "Zerops backup environment fetch failed on attempt $attempt; retrying"
    sleep 3
  done
  rm -f "$env_file"
  die 'failed to load the managed backup environment after five attempts'
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
  local node=$1 replicas engines deadline ready reason
  kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1 || return 0

  replicas=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq \
    --arg node "$node" '[.items[] | select(.spec.nodeID == $node)] | length')
  [[ "$replicas" -eq 0 ]] \
    || die "refusing to replace the stale Longhorn disk record on $node because it still owns $replicas replicas"
  engines=$(kubectl -n longhorn-system get engines.longhorn.io -o json | jq \
    --arg node "$node" '[.items[] | select(.spec.nodeID == $node and .status.currentState == "running")] | length')
  [[ "$engines" -eq 0 ]] \
    || die "refusing to replace the stale Longhorn disk record on $node because it still owns $engines running engines"

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
  # Longhorn's admission webhook rejects deletion while the Kubernetes node
  # merely reports NotReady. Remove the stale node identity first so Longhorn
  # observes KubernetesNodeGone. The Longhorn controller may then garbage-
  # collect its Node object itself, so both outcomes are valid.
  kubectl delete "node/$node" --ignore-not-found --wait=true >/dev/null
  deadline=$((SECONDS + 180))
  while kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1; do
    reason=$(kubectl -n longhorn-system get "nodes.longhorn.io/$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    [[ "$reason" == KubernetesNodeGone ]] && break
    (( SECONDS < deadline )) \
      || die "Longhorn did not observe the removed Kubernetes node before disk replacement: $node"
    sleep 3
  done
  if kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1; then
    kubectl -n longhorn-system delete "nodes.longhorn.io/$node" --wait=true >/dev/null
  fi
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

project_env_id() {
  local key=$1 response payload env_id
  require_env ZEROPS_CLIENT_ID
  response=$(mktemp)
  payload=$(jq -cn --arg project_id "$ZEROPS_PROJECT_ID" --arg client_id "$ZEROPS_CLIENT_ID" \
    '{search:[
      {name:"clientId",operator:"eq",value:$client_id},
      {name:"id",operator:"eq",value:$project_id}
    ],sort:[],limit:1}')
  if ! api_request_file POST /project/search "$payload" "$response"; then
    rm -f "$response"
    return 1
  fi
  env_id=$(jq -r --arg key "$key" '.items[0].envList[]? | select(.key == $key) | .id' "$response" | head -n 1)
  rm -f "$response"
  printf '%s\n' "$env_id"
}

store_project_env() {
  local key=$1 value=$2 sensitive=$3 response payload process_id env_id method path
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid Zerops project environment key: $key"
  [[ "$value" != *$'\n'* ]] || die "project environment value $key contains a newline and cannot be stored"
  [[ "$sensitive" == true || "$sensitive" == false ]] || die "invalid sensitivity for $key: $sensitive"

  payload=$(jq -cn --arg key "$key" --arg content "$value" --argjson sensitive "$sensitive" \
    '{key:$key, content:$content, sensitive:$sensitive}')
  env_id=$(project_env_id "$key")
  if [[ -n "$env_id" ]]; then
    method=PUT
    path="/project-env/${env_id}"
  else
    method=POST
    path="/project/${ZEROPS_PROJECT_ID}/env"
  fi

  response=$(mktemp)
  if ! api_request_file "$method" "$path" "$payload" "$response"; then
    rm -f "$response"
    return 1
  fi
  process_id=$(jq -er '.id' "$response")
  rm -f "$response"
  wait_public_process "$process_id"
}

store_project_secret() {
  store_project_env "$1" "$2" true
}

store_project_variable() {
  store_project_env "$1" "$2" false
}

generate_cluster_secret() {
  local key=${1:?cluster secret key is required}
  require openssl
  case "$key" in
    K8S_AGENT_TOKEN|K8S_CERTIFICATE_KEY|K8S_ENCRYPTION_KEY)
      openssl rand -hex 32
      ;;
    K8S_BOOTSTRAP_TOKEN)
      printf '%s.%s\n' "$(openssl rand -hex 3)" "$(openssl rand -hex 8)"
      ;;
    *) die "unsupported generated cluster secret: $key" ;;
  esac
}

rotate_project_cluster_secrets() {
  local key value
  log 'rotating clean-cluster credentials into Zerops project secrets'
  for key in K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY; do
    value=$(generate_cluster_secret "$key")
    store_project_secret "$key" "$value"
  done
  load_zerops_env
  require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
}

ensure_project_cluster_secrets() {
  local key value project_env
  project_env=$(mktemp)
  zcli project env -P "$ZEROPS_PROJECT_ID" >"$project_env"
  for key in K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY; do
    if grep -q "^${key}=" "$project_env"; then
      continue
    fi
    value=${!key:-}
    [[ -n "$value" ]] || value=$(generate_cluster_secret "$key")
    store_project_secret "$key" "$value"
  done
  rm -f "$project_env"
  load_zerops_env
  require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
}

join_zerops_backends() {
  local port=$1
  shift
  local host backends=() old_ifs=$IFS
  [[ "$port" =~ ^[0-9]+$ ]] || die "join_zerops_backends requires a numeric port"
  for host in "$@"; do
    [[ "$host" =~ ^[a-z0-9]+$ ]] || die "invalid edge backend hostname: $host"
    backends+=("${host}.zerops:${port}")
  done
  IFS=,
  printf '%s' "${backends[*]}"
  IFS=$old_ifs
}

edge_workers_for_count() {
  local count=$1
  local -a workers optional=()
  [[ "$count" =~ ^[0-9]+$ ]] || die "edge worker count must be an integer"
  (( count >= ${#WORKERS[@]} )) || die "edge worker count $count is below profile floor ${#WORKERS[@]}"
  workers=("${WORKERS[@]}")
  mapfile -t optional < <(profile_json '.topology.optionalWorkers[]?' 2>/dev/null || true)
  if (( count > ${#workers[@]} )); then
    [[ ${#optional[@]} -gt 0 ]] \
      || die "profile $K8S_PROFILE has no optional worker for count $count"
    workers+=("${optional[0]}")
  fi
  (( ${#workers[@]} == count )) \
    || die "internal edge worker list mismatch: expected $count, got ${#workers[@]}"
  printf '%s\n' "${workers[@]}"
}

sync_edge_backend_variables() {
  local worker_count=${1:-${#WORKERS[@]}}
  local -a workers
  mapfile -t workers < <(edge_workers_for_count "$worker_count")
  store_project_variable K8S_EDGE_API_BACKENDS \
    "$(join_zerops_backends 6443 "${CONTROL_PLANES[@]}")"
  store_project_variable K8S_EDGE_INGRESS_BACKENDS \
    "$(join_zerops_backends 32080 "${workers[@]}")"
  if [[ $(profile_json '.addons.dashboard') == true ]]; then
    store_project_variable K8S_EDGE_HEADLAMP_BACKENDS \
      "$(join_zerops_backends 32081 "${workers[@]}")"
  fi
}

sync_alloy_scrape_targets() {
  local worker_count=${1:-${#WORKERS[@]}}
  local -a workers
  mapfile -t workers < <(edge_workers_for_count "$worker_count")
  store_project_variable K8S_ALLOY_SCRAPE_TARGETS \
    "$(join_zerops_backends 12345 "${workers[@]}")"
}

redeploy_edge_runtime() {
  [[ "$EDGE_ENABLED" == true ]] || return 0
  require zcli
  local setup version_name="edge-resync-${GITHUB_RUN_ID:-local}-$(date +%s)"
  setup=$(jq -er --arg hostname "$EDGE_HOSTNAME" \
    '.services[] | select(.hostname == $hostname) | .setup' "$PROFILE_FILE")
  log "redeploying $EDGE_HOSTNAME so HAProxy reloads refreshed backend project variables"
  timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli service deploy "$EDGE_HOSTNAME" -P "$ZEROPS_PROJECT_ID" \
    --setup "$setup" --version-name "$version_name" \
    --working-dir "$ROOT_DIR" --path-to-file-or-dir edge
}

redeploy_prometheus_runtime() {
  [[ $(profile_json '.addons.observability') == advanced ]] || return 0
  require zcli
  local version_name="prometheus-resync-${GITHUB_RUN_ID:-local}-$(date +%s)"
  local source_args=(--workspace-state all)
  [[ -d "$ROOT_DIR/.git" ]] || source_args=(--no-git)
  [[ "${GITHUB_ACTIONS:-false}" != true ]] && source_args=(--workspace-state clean)
  log 'redeploying prometheus so Alloy scrape targets match the current worker floor'
  timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli push prometheus -P "$ZEROPS_PROJECT_ID" \
    --setup prometheus --version-name "$version_name" \
    --working-dir "$ROOT_DIR" "${source_args[@]}"
}
