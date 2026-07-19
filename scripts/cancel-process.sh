#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require curl
require jq

process_id=${1:-}
[[ "$process_id" =~ ^[A-Za-z0-9_-]{10,}$ ]] || die 'a valid Zerops process ID is required'

process=$(mktemp)
services=$(mktemp)
response=$(mktemp)
trap 'rm -f "$process" "$services" "$response"' EXIT

api_request_file GET "/process/${process_id}" '' "$process"
[[ $(jq -r '.projectId' "$process") == "$ZEROPS_PROJECT_ID" ]] \
  || die 'refusing to cancel a process outside the configured project'

service_id=$(jq -er '.serviceStackId' "$process") \
  || die 'refusing to cancel a process that is not scoped to a service'
api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$services"
jq -e --arg id "$service_id" --argjson nodes "$(printf '%s\n' "${NODES[@]}" | jq -R . | jq -s .)" '
  .list[] | select(.id == $id and (.name as $name | $nodes | index($name)))
' "$services" >/dev/null || die 'refusing to cancel a process outside the six Kubernetes node services'

status=$(jq -er '.status' "$process")
case "$status" in
  FINISHED|FAILED|CANCELED)
    log "Zerops process is already terminal: $process_id ($status)"
    exit 0
    ;;
  CANCELING|ROLLBACKING)
    log "Zerops process is already terminating: $process_id ($status)"
    ;;
  RUNNING|PENDING|NEW)
    cancel_status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
      -X PUT -H "Authorization: Bearer $ZEROPS_TOKEN" -H 'Content-Type: application/json' \
      --data '{}' \
      "${ZEROPS_API_BASE:-https://api.app-prg1.zerops.io/api/rest/public}/process/${process_id}/cancel")
    if [[ "$cancel_status" == 2* ]]; then
      log "Zerops accepted cancellation for process: $process_id"
    elif [[ $(jq -r '.error.code // empty' "$response") == processIsAlreadyRunning ]]; then
      # Zerops cannot cancel a build after its deployment phase has begun. Keep
      # the repository lock and wait for the platform's bounded pipeline timeout.
      log "Zerops deployment phase cannot be canceled; waiting for its platform timeout: $process_id"
    else
      jq '{error: (.error.code // .error // "request failed"), message: (.error.message // "")}' "$response" >&2 || true
      die "Zerops refused cancellation for process: $process_id"
    fi
    ;;
  *) die "refusing to cancel process in unexpected state: $status" ;;
esac

deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  api_request_file GET "/process/${process_id}" '' "$process"
  status=$(jq -er '.status' "$process")
  case "$status" in
    CANCELED|FAILED|FINISHED)
      log "Zerops process reached terminal state: $process_id ($status)"
      exit 0
      ;;
  esac
  sleep 2
done
die "Zerops process did not become terminal within 30 minutes: $process_id"
