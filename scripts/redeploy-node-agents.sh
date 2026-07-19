#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_PROJECT_ID
require zcli

version_name="github-${GITHUB_RUN_ID:-local}-${GITHUB_SHA:-working}-node-recovery"
source_args=(--workspace-state all)
if [[ ! -d "$ROOT_DIR/.git" ]]; then
  source_args=(--no-git)
fi

while read -r service setup; do
  log "deploying restart-safe node agent to $service"
  deployed=false
  for attempt in 1 2 3; do
    if zcli push "$service" -P "$ZEROPS_PROJECT_ID" --setup "$setup" \
      --version-name "$version_name" --working-dir "$ROOT_DIR" "${source_args[@]}"; then
      deployed=true
      break
    fi
    log "node-agent deployment failed on attempt $attempt; retrying $service"
    sleep 5
  done
  [[ "$deployed" == true ]] || die "node-agent deployment failed after three attempts: $service"
  wait_for_agent "$service"
done <<'EOF'
k8sworker1 worker1
k8sworker2 worker2
k8sworker3 worker3
k8scp2 controlplane2
k8scp3 controlplane3
k8scp1 controlplane1
EOF
