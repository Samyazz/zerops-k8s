#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID ZEROPS_CLIENT_ID
success=false
cluster_touched=false
vpn_connected=false

finish() {
  status=$?
  if [[ "$success" != true && "$cluster_touched" == true ]]; then
    log 'deployment failed or was canceled; destroying partial nested infrastructure'
    "$ROOT_DIR/scripts/destroy-cluster.sh" || true
  fi
  if [[ "$vpn_connected" == true ]]; then zcli vpn down >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT INT TERM

load_zerops_env
require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
project_state=$(cluster_tag_value state)
project_repository=$(cluster_tag_value repository)
if [[ "$project_state" == cleanup-failed ]]; then
  die 'the Zerops-side lock is cleanup-failed; run the explicit destroy workflow successfully before deploying'
fi
if [[ -n "$project_repository" && "$project_repository" != unknown && "${project_repository,,}" != "${GITHUB_REPOSITORY,,}" ]]; then
  die "this project is already managed by $project_repository"
fi

set_cluster_state deploying "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"

"$ROOT_DIR/scripts/provision-observability.sh"
"$ROOT_DIR/scripts/build-and-deploy.sh"

zcli vpn up -P "$ZEROPS_PROJECT_ID" --auto-disconnect
vpn_connected=true
cluster_touched=true

"$ROOT_DIR/scripts/cluster-bootstrap.sh"
"$ROOT_DIR/scripts/configure-retention.sh"
"$ROOT_DIR/scripts/acceptance.sh"
"$ROOT_DIR/scripts/store-credentials.sh"

success=true
log 'clean-room deployment completed; the validated cluster remains running'
