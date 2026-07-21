#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

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
"$ROOT_DIR/scripts/validate-recipe.sh" "$K8S_PROFILE"
project_state=$(cluster_tag_value state)
project_repository=$(cluster_tag_value repository)
project_profile=$(cluster_tag_value profile)
project_operation=$(cluster_tag_value operation)
project_owner_run=$(cluster_tag_value run)
if [[ -z "$project_profile" && -n "$project_state" && "$project_state" != destroyed ]]; then
  project_profile=full
fi
if [[ "$project_state" == cleanup-failed ]]; then
  die 'the Zerops-side lock is cleanup-failed; run the explicit destroy workflow successfully before deploying'
fi
if [[ -n "$project_repository" && "$project_repository" != unknown && "${project_repository,,}" != "${GITHUB_REPOSITORY,,}" ]]; then
  die "this project is already managed by $project_repository"
fi
if [[ -n "$project_state" && "$project_state" != destroyed ]]; then
  load_zerops_env
  require_env K8S_AGENT_TOKEN K8S_BOOTSTRAP_TOKEN K8S_CERTIFICATE_KEY K8S_ENCRYPTION_KEY
fi

zcli vpn up -P "$ZEROPS_PROJECT_ID" --auto-disconnect --mtu "${ZEROPS_VPN_MTU:-1280}"
vpn_connected=true

if [[ "$project_state" == deploying && "$project_owner_run" != "$GITHUB_RUN_ID" \
      && ( "$project_operation" == create || "$project_operation" == switch ) ]]; then
  log "removing recipe-owned services abandoned by clean deployment run $project_owner_run before retry"
  "$ROOT_DIR/scripts/reconcile-profile-services.sh" purge
  set_cluster_state destroyed "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  project_state=destroyed
  project_profile=
fi

set_cluster_tag attempt "$GITHUB_RUN_ID"

set_profile_resource_tags() {
  local cp worker
  cp=${CONTROL_PLANES[0]}
  worker=${WORKERS[0]}
  store_project_variable K8S_MANAGED true
  store_project_variable K8S_REPOSITORY "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}"
  store_project_variable K8S_PROFILE "$K8S_PROFILE"
  store_project_variable K8S_VERSION "v${KUBERNETES_VERSION}"
  store_project_variable K8S_NODE_IMAGE "zerops-k8s-node:v${KUBERNETES_VERSION}"
  store_project_variable K8S_CONTROL_PLANE_ENDPOINT "$CONTROL_PLANE_ENDPOINT"
  store_project_variable K8S_POD_CIDR 10.244.0.0/16
  store_project_variable K8S_SERVICE_CIDR 10.96.0.0/16
  if [[ "$NODE_IMAGE_MODE" == object-storage ]]; then
    store_project_variable K8S_IMAGE_OBJECT "node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"
    store_project_variable K8S_IMAGE_SHA256_OBJECT "node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz.sha256"
    store_project_variable K8S_BACKUP_QUOTA_GB "$(profile_json '.topology.backup.quotaGb')"
  fi
  set_cluster_tag profile "$K8S_PROFILE"
  set_cluster_tag workers "${#WORKERS[@]}"
  set_cluster_tag cp-cpu "$(jq -er --arg node "$cp" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")"
  set_cluster_tag cp-ram "$(jq -er --arg node "$cp" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")"
  set_cluster_tag cp-disk "$(jq -er --arg node "$cp" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")"
  set_cluster_tag worker-cpu "$(jq -er --arg node "$worker" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")"
  set_cluster_tag worker-ram "$(jq -er --arg node "$worker" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")"
  set_cluster_tag worker-disk "$(jq -er --arg node "$worker" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")"
}

if [[ -n "$project_state" && "$project_state" != destroyed && "$project_profile" != "$K8S_PROFILE" ]]; then
  set_cluster_tag operation switch
  log "switching repository-managed cluster profile from $project_profile to $K8S_PROFILE by clean replacement"
  "$ROOT_DIR/scripts/prepare-profile-switch.sh" "$project_profile"
  export RECONCILE_EXISTING=false
  RECREATE_TARGET_RUNTIME_SERVICES=true \
    "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  set_profile_resource_tags
elif [[ -n "$project_state" && "$project_state" != destroyed ]]; then
  export RECONCILE_EXISTING=true
  set_cluster_tag operation reconcile
  PRESERVE_OPTIONAL_WORKERS=true "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  log "existing repository-managed $K8S_PROFILE cluster detected; reconciling it in place"
else
  export RECONCILE_EXISTING=false
  set_cluster_tag operation create
  RECREATE_TARGET_RUNTIME_SERVICES=true \
    "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  set_profile_resource_tags
fi

if [[ "$RECONCILE_EXISTING" == true ]]; then
  ensure_project_cluster_secrets
else
  rotate_project_cluster_secrets
fi

if [[ "$RECONCILE_EXISTING" == true ]]; then
  export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/pre-reconcile-kubeconfig"
  agent_request k8scp1 GET /v1/cluster/kubeconfig > "$KUBECONFIG"
  sed -i "s#^[[:space:]]*server:.*#    server: https://${CONTROL_PLANE_ENDPOINT}#" "$KUBECONFIG"
  chmod 0600 "$KUBECONFIG"
  kubectl get --raw=/readyz >/dev/null
fi

set_cluster_state deploying "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"

cluster_touched=true
"$ROOT_DIR/scripts/provision-observability.sh"
if [[ "$RECONCILE_EXISTING" == true ]]; then
  PUSH_AGENT_CODE=true "$ROOT_DIR/scripts/redeploy-node-agents.sh"
fi
"$ROOT_DIR/scripts/reconcile-node-resources.sh"
"$ROOT_DIR/scripts/build-and-deploy.sh"

export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubeconfig"
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
"$ROOT_DIR/scripts/configure-retention.sh"
if profile_capability backup; then "$ROOT_DIR/scripts/backup-cluster.sh"; fi
"$ROOT_DIR/scripts/acceptance.sh"
"$ROOT_DIR/scripts/store-credentials.sh"
set_cluster_tag profile "$K8S_PROFILE"
set_cluster_state running "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
set_cluster_tag attempt complete

success=true
log 'clean-room deployment completed; the validated cluster remains running'
