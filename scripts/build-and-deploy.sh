#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops object-storage variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/node-agent-artifact.sh"

require_env ZEROPS_PROJECT_ID
require curl
require zcli

artifact_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}
mkdir -p "$artifact_dir"
archive="$artifact_dir/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"
checksum="$archive.sha256"
image="zerops-k8s-node:v${KUBERNETES_VERSION}"
object="node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"

load_zerops_env
if [[ "${RECONCILE_EXISTING:-false}" != true && "$NODE_IMAGE_MODE" == object-storage ]]; then
  if [[ -z "${K8S_IMAGE_STORAGE_ENDPOINT:-}" ]]; then
    load_backup_env
  fi
  require docker
  log "building nested node image $image"
  docker build --pull \
    --build-arg "KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
    --build-arg "KUBERNETES_MINOR=${KUBERNETES_VERSION%.*}" \
    --build-arg "KUBERNETES_PACKAGE_VERSION=${KUBERNETES_PACKAGE_VERSION}" \
    -t "$image" -f "$ROOT_DIR/node/Dockerfile" "$ROOT_DIR"
  docker save "$image" | gzip -n -1 > "$archive"
  digest=$(sha256sum "$archive" | awk '{print $1}')
  printf '%s  node-image.tar.gz\n' "$digest" > "$checksum"

  require_env K8S_IMAGE_STORAGE_ENDPOINT K8S_IMAGE_STORAGE_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/$K8S_IMAGE_STORAGE_BUCKET"
  curl -fsS --retry 3 --aws-sigv4 aws:amz:us-west-1:s3 \
    --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    -T "$archive" "$s3_base/$object"
  curl -fsS --retry 3 --aws-sigv4 aws:amz:us-west-1:s3 \
    --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    -T "$checksum" "$s3_base/$object.sha256"
fi

version_name="github-${GITHUB_RUN_ID:-local}-${GITHUB_SHA:-working}"
deploy_with_build() {
  local service=$1 setup=$2 attempt
  local source_args=(--workspace-state all)
  if [[ ! -d "$ROOT_DIR/.git" ]]; then
    source_args=(--no-git)
  elif [[ "${GITHUB_ACTIONS:-false}" == true ]]; then
    # Acceptance deploys must upload exactly the checked-out revision. Using
    # the clean Git archive also avoids packaging runner-only workspace state.
    source_args=(--workspace-state clean)
  fi
  log "deploying $service with setup $setup"
  for attempt in 1 2 3; do
    set +e
    timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli push "$service" -P "$ZEROPS_PROJECT_ID" --setup "$setup" \
      --version-name "$version_name" --working-dir "$ROOT_DIR" "${source_args[@]}"
    result=$?
    set -e
    if (( result == 0 )); then
      return 0
    fi
    (( result != 124 )) || die "Zerops deployment timed out for $service; recover its in-flight process through the destroy workflow"
    log "deployment upload for $service failed on attempt $attempt; retrying"
    sleep 5
  done
  die "deployment upload failed after three attempts: $service"
}

deploy_runtime_artifact() {
  local service=$1 setup=$2 attempt result
  log "deploying prebuilt runtime artifact to $service with setup $setup"
  for attempt in 1 2 3; do
    set +e
    timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli service deploy "$service" -P "$ZEROPS_PROJECT_ID" \
      --setup "$setup" --version-name "${NODE_AGENT_VERSION_NAME}-${service}-${attempt}" \
      --working-dir "$NODE_AGENT_ARTIFACT_DIR" --path-to-file-or-dir .
    result=$?
    set -e
    (( result == 0 )) && return 0
    (( result != 124 )) || die "Zerops prebuilt runtime deployment timed out for $service"
    log "prebuilt runtime deployment failed on attempt $attempt; retrying $service"
    sleep 5
  done
  die "prebuilt runtime deployment failed after three attempts: $service"
}

if [[ "$EDGE_ENABLED" == true || "${RECONCILE_EXISTING:-false}" != true ]]; then
  # The reviewed artifact is built and tested on the Actions runner, then sent
  # directly to each runtime. This avoids depending on a Zerops build container
  # for the critical node-agent delivery path.
  prepare_node_agent_artifact
fi

if [[ "$EDGE_ENABLED" == true ]]; then
  edge_setup=$(jq -er --arg hostname "$EDGE_HOSTNAME" \
    '.services[] | select(.hostname == $hostname) | .setup' "$PROFILE_FILE")
  deploy_runtime_artifact "$EDGE_HOSTNAME" "$edge_setup"
fi

if [[ "${RECONCILE_EXISTING:-false}" != true ]]; then
  while IFS=$'\t' read -r service setup; do
    deploy_runtime_artifact "$service" "$setup"
  done < <(jq -r '.services[] | select(.type | startswith("docker@")) | [.hostname,.setup] | @tsv' "$PROFILE_FILE")
else
  log 'preserving running nested node state during in-place reconciliation'
fi

if [[ $(profile_json '.addons.observability') == advanced ]]; then
  deploy_with_build prometheus prometheus
  deploy_with_build grafana grafana
fi
