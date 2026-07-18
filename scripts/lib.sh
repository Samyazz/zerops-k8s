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
  local response
  response=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}" '' "$response"
  printf '%s\n' "$response"
}

cluster_tag_value() {
  local key=$1 response
  response=$(project_json)
  jq -r --arg prefix "zerops-k8s.${key}=" \
    '.tagList[]? | select(startswith($prefix)) | ltrimstr($prefix)' "$response" | tail -n 1
}

set_cluster_state() {
  local state=$1 repository=${2:-${GITHUB_REPOSITORY:-unknown}} run_id=${3:-${GITHUB_RUN_ID:-local}}
  local response payload current
  response=$(project_json)
  current=$(mktemp)
  jq --arg state "$state" --arg repository "$repository" --arg run "$run_id" '
    .tagList = ([.tagList[]? | select(startswith("zerops-k8s.") | not)] + [
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
