#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID GITHUB_REPOSITORY GITHUB_RUN_ID

state=$(cluster_tag_value state)
repository=$(cluster_tag_value repository)
owner_run=$(cluster_tag_value run)
operation=$(cluster_tag_value operation)
attempt=$(cluster_tag_value attempt)

if [[ "$state" == destroyed && "${repository,,}" == "${GITHUB_REPOSITORY,,}" \
      && "$attempt" == "$GITHUB_RUN_ID" \
      && ( "$operation" == create || "$operation" == switch ) ]]; then
  log 'failed clean creation owns partial outer services; removing them before any retry'
  if ! "$ROOT_DIR/scripts/reconcile-profile-services.sh" purge; then
    set_cluster_state cleanup-failed "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" || true
    die 'partial outer-service cleanup failed; later deployments are blocked'
  fi
  set_cluster_tag operation cleaned
  set_cluster_tag attempt complete
  log 'failed clean creation converged to zero recipe-owned services'
  exit 0
fi

if [[ "$state" != deploying || "${repository,,}" != "${GITHUB_REPOSITORY,,}" || "$owner_run" != "$GITHUB_RUN_ID" ]]; then
  log "cleanup skipped because this run does not own the active deployment lock"
  exit 0
fi

if [[ "$operation" == reconcile ]]; then
  set_cluster_state reconcile-failed "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  log 'cleanup preserved the pre-existing cluster; reconciliation did not create partial infrastructure'
  exit 0
fi

zcli vpn up -P "$ZEROPS_PROJECT_ID" --auto-disconnect --mtu "${ZEROPS_VPN_MTU:-1280}"
trap 'zcli vpn down >/dev/null 2>&1 || true' EXIT
"$ROOT_DIR/scripts/destroy-cluster.sh"
