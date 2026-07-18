#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID GITHUB_REPOSITORY GITHUB_RUN_ID

state=$(cluster_tag_value state)
repository=$(cluster_tag_value repository)
owner_run=$(cluster_tag_value run)

if [[ "$state" != deploying || "${repository,,}" != "${GITHUB_REPOSITORY,,}" || "$owner_run" != "$GITHUB_RUN_ID" ]]; then
  log "cleanup skipped because this run does not own the active deployment lock"
  exit 0
fi

zcli vpn up -P "$ZEROPS_PROJECT_ID" --auto-disconnect
trap 'zcli vpn down >/dev/null 2>&1 || true' EXIT
"$ROOT_DIR/scripts/destroy-cluster.sh"
