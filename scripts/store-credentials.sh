#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env KUBECONFIG ZEROPS_PROJECT_ID
load_zerops_env
require_env ZEROPS_TOKEN

token() {
  kubectl -n headlamp get secret "$1-token" -o jsonpath='{.data.token}' | base64 -d
}

kubeconfig_b64=$(base64 -w0 < "$KUBECONFIG")
run_id=${GITHUB_RUN_ID:-local}
key_suffix=$(tr '[:lower:]-' '[:upper:]_' <<<"$run_id" | tr -cd 'A-Z0-9_')
[[ -n "$key_suffix" ]] || key_suffix=LOCAL

if [[ $(profile_json '.addons.dashboard') == true ]]; then
  admin=$(token headlamp-admin)
  operator=$(token headlamp-operator)
  developer=$(token headlamp-developer)
  readonly_token=$(token headlamp-readonly)
  store_project_secret "HEADLAMP_ADMIN_TOKEN_RUN_${key_suffix}" "$admin"
  store_project_secret "HEADLAMP_OPERATOR_TOKEN_RUN_${key_suffix}" "$operator"
  store_project_secret "HEADLAMP_DEVELOPER_TOKEN_RUN_${key_suffix}" "$developer"
  store_project_secret "HEADLAMP_READONLY_TOKEN_RUN_${key_suffix}" "$readonly_token"
fi
store_project_secret "K8S_ADMIN_KUBECONFIG_B64_RUN_${key_suffix}" "$kubeconfig_b64"
set_cluster_state ready "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "$run_id"
log "credentials stored as sensitive Zerops project variables with suffix RUN_${key_suffix}"
