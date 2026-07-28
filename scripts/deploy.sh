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
agents_deployed=false
vpn_connected=false
reconcile_created_services=none
pre_reconcile_endpoint=
edge_migration_required=false

finish() {
  status=$?
  trap - EXIT INT TERM
  if [[ "$success" != true && "$cluster_touched" == true && "${RECONCILE_EXISTING:-false}" != true ]]; then
    if [[ "$agents_deployed" == true ]]; then
      log 'deployment failed or was canceled after agent delivery; destroying partial nested infrastructure'
      "$ROOT_DIR/scripts/destroy-cluster.sh" || true
    else
      log 'deployment failed before agent delivery; purging disposable outer services directly'
      if "$ROOT_DIR/scripts/reconcile-profile-services.sh" purge; then
        set_cluster_state destroyed "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}" || true
      else
        set_cluster_state cleanup-failed "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}" || true
      fi
    fi
  fi
  if [[ "$vpn_connected" == true ]]; then zcli vpn down >/dev/null 2>&1 || true; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

shellcheck "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/edge/*.sh
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
  pre_reconcile_endpoint=${K8S_CONTROL_PLANE_ENDPOINT:-$CONTROL_PLANE_ENDPOINT}
  if [[ -z "${K8S_VRRP_VIP:-}" ]]; then
    edge_migration_required=true
  fi
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
  local cp worker inventory service address
  resolve_vrrp_topology
  inventory=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$inventory"
  while read -r service; do
    [[ -n "$service" ]] || continue
    while read -r address; do
      [[ "$address" != "$VRRP_VIP" ]] \
        || die "derived VRRP VIP $VRRP_VIP is already allocated to Zerops service $service"
    done < <(getent ahostsv4 "${service}.zerops" 2>/dev/null | awk '{print $1}' | sort -u)
  done < <(jq -r '.list[].name' "$inventory")
  rm -f "$inventory"
  cp=${CONTROL_PLANES[0]}
  worker=${WORKERS[0]}
  store_project_variable K8S_MANAGED true
  store_project_variable K8S_REPOSITORY "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}"
  store_project_variable K8S_PROFILE "$K8S_PROFILE"
  store_project_variable K8S_VERSION "v${KUBERNETES_VERSION}"
  store_project_variable K8S_NODE_IMAGE "zerops-k8s-node:v${KUBERNETES_VERSION}"
  store_project_variable K8S_CONTROL_PLANE_ENDPOINT "$CONTROL_PLANE_ENDPOINT"
  store_project_variable K8S_VRRP_VIP "$VRRP_VIP"
  store_project_variable K8S_VRRP_PREFIX_LENGTH "$VRRP_PREFIX_LENGTH"
  store_project_variable K8S_VRRP_HOST_OCTET "$VRRP_HOST_OCTET"
  store_project_variable K8S_VRRP_VIRTUAL_ROUTER_ID "$VRRP_VIRTUAL_ROUTER_ID"
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
  worker_count=$(cluster_tag_value workers)
  worker_count=${worker_count:-${#WORKERS[@]}}
  sync_edge_backend_variables "$worker_count"
  sync_alloy_scrape_targets "$worker_count"
}

if [[ "$edge_migration_required" == true ]]; then
  set_cluster_tag operation switch
  log 'migrating the legacy edge to VRRP by a backup-protected clean cluster replacement'
  "$ROOT_DIR/scripts/prepare-profile-switch.sh" "$project_profile"
  cluster_touched=true
  export RECONCILE_EXISTING=false
  RECREATE_TARGET_RUNTIME_SERVICES=true \
    "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  set_profile_resource_tags
elif [[ -n "$project_state" && "$project_state" != destroyed && "$project_profile" != "$K8S_PROFILE" ]]; then
  set_cluster_tag operation switch
  log "switching repository-managed cluster profile from $project_profile to $K8S_PROFILE by clean replacement"
  "$ROOT_DIR/scripts/prepare-profile-switch.sh" "$project_profile"
  cluster_touched=true
  export RECONCILE_EXISTING=false
  RECREATE_TARGET_RUNTIME_SERVICES=true \
    "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  set_profile_resource_tags
elif [[ -n "$project_state" && "$project_state" != destroyed ]]; then
  export RECONCILE_EXISTING=true
  set_cluster_tag operation reconcile
  set_cluster_tag reconcile-created none
  PRESERVE_OPTIONAL_WORKERS=true TRACK_RECONCILE_CREATED=true \
    "$ROOT_DIR/scripts/reconcile-profile-services.sh" apply
  set_profile_resource_tags
  reconcile_created_services=$(cluster_tag_value reconcile-created)
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
  [[ -n "$pre_reconcile_endpoint" ]] \
    || die 'existing cluster has no previous control-plane endpoint for migration checks'
  export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/pre-reconcile-kubeconfig"
  agent_request k8scp1 GET /v1/cluster/kubeconfig > "$KUBECONFIG"
  sed -i "s#^[[:space:]]*server:.*#    server: https://${pre_reconcile_endpoint}#" "$KUBECONFIG"
  chmod 0600 "$KUBECONFIG"
  kubectl get --raw=/readyz >/dev/null
fi

set_cluster_state deploying "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"

cluster_touched=true
"$ROOT_DIR/scripts/provision-observability.sh"
"$ROOT_DIR/scripts/reconcile-node-resources.sh"
if [[ "$RECONCILE_EXISTING" == true ]]; then
  if [[ "$reconcile_created_services" != none ]]; then
    TARGET_RUNTIME_SERVICES="$reconcile_created_services" \
      "$ROOT_DIR/scripts/build-and-deploy.sh"
  fi
  log 'preserving existing outer node runtimes and nested state; delivered agents only to newly created runtimes'
else
  "$ROOT_DIR/scripts/build-and-deploy.sh"
  agents_deployed=true
fi

export KUBECONFIG="${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubeconfig"
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
"$ROOT_DIR/scripts/configure-retention.sh"
if profile_capability backup; then "$ROOT_DIR/scripts/backup-cluster.sh"; fi
"$ROOT_DIR/scripts/acceptance.sh"
"$ROOT_DIR/scripts/store-credentials.sh"
set_cluster_tag profile "$K8S_PROFILE"
set_cluster_state running "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
set_cluster_tag reconcile-created none
set_cluster_tag attempt complete

success=true
log 'clean-room deployment completed; the validated cluster remains running'
