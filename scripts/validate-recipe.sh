#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID

mapfile -t expected_services < <(
  awk '/^services:/{services=1; next} services && /^  - hostname:/{print $3}' "$ROOT_DIR/import.yaml"
)
[[ ${#expected_services[@]} -gt 0 ]] || die 'the first-class recipe defines no services'

response=$(mktemp)
api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"
mapfile -t missing < <(
  for service in "${expected_services[@]}"; do
    jq -e --arg service "$service" '.list | any(.name == $service)' "$response" >/dev/null \
      || printf '%s\n' "$service"
  done
)
rm "$response"

if (( ${#missing[@]} > 0 )); then
  die "the current project does not match import.yaml; missing services: ${missing[*]}"
fi
log "validated ${#expected_services[@]} live services against the publishable first-class recipe"
