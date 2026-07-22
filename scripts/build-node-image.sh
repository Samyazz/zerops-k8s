#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops object-storage variables are loaded dynamically.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_PROJECT_ID
require curl
require docker
require zcli

if [[ -z "${K8S_IMAGE_STORAGE_ENDPOINT:-}" ]]; then
  load_zerops_env
fi
if [[ -z "${K8S_IMAGE_STORAGE_ENDPOINT:-}" ]]; then
  load_backup_env
fi
require_env K8S_IMAGE_STORAGE_ENDPOINT K8S_IMAGE_STORAGE_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

artifact_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/node-image
mkdir -p "$artifact_dir"
archive="$artifact_dir/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"
checksum="$archive.sha256"
downloaded_checksum="$artifact_dir/remote.sha256"
image="zerops-k8s-node:v${KUBERNETES_VERSION}"
object="node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz"

log "building durable replacement image $image"
docker build --pull \
  --build-arg "KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
  --build-arg "KUBERNETES_MINOR=${KUBERNETES_VERSION%.*}" \
  --build-arg "KUBERNETES_PACKAGE_VERSION=${KUBERNETES_PACKAGE_VERSION}" \
  --build-arg "CRI_TOOLS_PACKAGE_VERSION=${CRI_TOOLS_PACKAGE_VERSION}" \
  -t "$image" -f "$ROOT_DIR/node/Dockerfile" "$ROOT_DIR"
docker save "$image" | gzip -n -1 >"$archive"
digest=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  node-image.tar.gz\n' "$digest" >"$checksum"

s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/${K8S_IMAGE_STORAGE_BUCKET}"
s3_args=(--fail --silent --show-error --retry 3 --retry-all-errors \
  --aws-sigv4 "aws:amz:${K8S_BACKUP_REGION:-us-west-1}:s3" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")
curl "${s3_args[@]}" -T "$archive" "$s3_base/$object"
curl "${s3_args[@]}" -T "$checksum" "$s3_base/$object.sha256"
curl "${s3_args[@]}" -o "$downloaded_checksum" "$s3_base/$object.sha256"
[[ $(awk 'NR == 1 {print $1}' "$downloaded_checksum") == "$digest" ]] \
  || die 'uploaded node-image checksum object did not round-trip'

jq -n --arg image "$image" --arg object "$object" --arg sha256 "$digest" \
  --argjson bytes "$(stat -c %s "$archive")" \
  '{image:$image,object:$object,sha256:$sha256,bytes:$bytes,verified:true}' \
  >"$artifact_dir/evidence.json"
log "uploaded and verified the pinned replacement image metadata for $image"
