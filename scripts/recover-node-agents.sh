#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_PROJECT_ID
require curl

unhealthy=()
for service in "${NODES[@]}"; do
  if curl --fail --silent --connect-timeout 3 --max-time 5 "http://${service}:18080/healthz" >/dev/null; then
    log "reusing healthy node agent during teardown: $service"
  else
    unhealthy+=("$service")
  fi
done

if (( ${#unhealthy[@]} == 0 )); then
  log 'all node agents are healthy; no recovery deployment is required'
  exit 0
fi

log "recovering unhealthy node agents: ${unhealthy[*]}"
"$ROOT_DIR/scripts/redeploy-node-agents.sh" "${unhealthy[@]}"
