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
  if [[ "$success" != true && "$cluster_touched" == true && "${RECONCILE_EXISTING:-false}" != true ]]; then
    log 'deployment failed or was canceled; destroying partial nested infrastructure'
    "$ROOT_DIR/scripts/destroy-cluster.sh" || true
  fi
  if [[ "$vpn_connected" == true ]]; then zcli vpn down >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT INT TERM

shellcheck "$ROOT_DIR"/scripts/*.sh
(cd "$ROOT_DIR" && go test ./... && go vet ./...)
"$ROOT_DIR/scripts/validate-recipe.sh"
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

if [[ -n "$project_state" && "$project_state" != destroyed ]]; then
  export RECONCILE_EXISTING=true
  set_cluster_tag operation reconcile
  log 'existing repository-managed cluster detected; reconciling it in place'
else
  export RECONCILE_EXISTING=false
  set_cluster_tag operation create
fi

zcli vpn up -P "$ZEROPS_PROJECT_ID" --auto-disconnect --mtu "${ZEROPS_VPN_MTU:-1280}"
vpn_connected=true
if [[ "$RECONCILE_EXISTING" == true ]]; then
  export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/pre-reconcile-kubeconfig"
  agent_request k8scp1 GET /v1/cluster/kubeconfig > "$KUBECONFIG"
  sed -i 's#^[[:space:]]*server:.*#    server: https://k8sedge.zerops:6443#' "$KUBECONFIG"
  chmod 0600 "$KUBECONFIG"
  kubectl get --raw=/readyz >/dev/null
fi

set_cluster_state deploying "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"

cluster_touched=true
"$ROOT_DIR/scripts/provision-observability.sh"
if [[ "$RECONCILE_EXISTING" == true ]]; then
  "$ROOT_DIR/scripts/redeploy-node-agents.sh"
fi
"$ROOT_DIR/scripts/reconcile-node-resources.sh"
"$ROOT_DIR/scripts/build-and-deploy.sh"

export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubeconfig"
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
"$ROOT_DIR/scripts/configure-retention.sh"
"$ROOT_DIR/scripts/backup-cluster.sh"
"$ROOT_DIR/scripts/acceptance.sh"
"$ROOT_DIR/scripts/store-credentials.sh"
set_cluster_state running "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"

success=true
log 'clean-room deployment completed; the validated cluster remains running'
