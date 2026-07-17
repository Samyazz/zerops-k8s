#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops object-storage variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_PROJECT_ID
require docker
require aws
require zcli

artifact_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}
mkdir -p "$artifact_dir"
archive="$artifact_dir/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"
checksum="$archive.sha256"
image="zerops-k8s-node:v${KUBERNETES_VERSION}"
object="node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"

log "building nested node image $image"
docker build --pull \
  --build-arg "KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
  --build-arg "KUBERNETES_MINOR=${KUBERNETES_VERSION%.*}" \
  --build-arg "KUBERNETES_PACKAGE_VERSION=${KUBERNETES_PACKAGE_VERSION}" \
  -t "$image" -f "$ROOT_DIR/node/Dockerfile" "$ROOT_DIR"
docker save "$image" | gzip -n -1 > "$archive"
digest=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  node-image.tar.gz\n' "$digest" > "$checksum"

load_zerops_env
require_env k8sbackups_apiUrl k8sbackups_accessKeyId k8sbackups_secretAccessKey k8sbackups_bucketName
export AWS_ACCESS_KEY_ID=$k8sbackups_accessKeyId
export AWS_SECRET_ACCESS_KEY=$k8sbackups_secretAccessKey
export AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url "$k8sbackups_apiUrl" s3 cp "$archive" "s3://$k8sbackups_bucketName/$object" --only-show-errors
aws --endpoint-url "$k8sbackups_apiUrl" s3 cp "$checksum" "s3://$k8sbackups_bucketName/$object.sha256" --only-show-errors

version_name="github-${GITHUB_RUN_ID:-local}-${GITHUB_SHA:-working}"
deploy_one() {
  local service=$1 setup=$2
  log "deploying $service with setup $setup"
  zcli push "$service" -P "$ZEROPS_PROJECT_ID" --setup "$setup" --version-name "$version_name" --working-dir "$ROOT_DIR" --workspace-state all
}

deploy_one k8sedge edge

for batch in 'k8scp1:controlplane1 k8scp2:controlplane2 k8scp3:controlplane3' \
             'k8sworker1:worker1 k8sworker2:worker2 k8sworker3:worker3'; do
  pids=()
  for pair in $batch; do
    deploy_one "${pair%%:*}" "${pair##*:}" & pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
done

deploy_one prometheus prometheus
deploy_one grafana grafana
