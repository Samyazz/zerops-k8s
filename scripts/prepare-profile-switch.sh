#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

source_profile=${1:?usage: prepare-profile-switch.sh <source-profile>}
export K8S_PROFILE=$source_profile
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require curl
require age
require jq
require kubectl
require sha256sum
load_zerops_env
require_env K8S_AGENT_TOKEN

assert_repository_cluster
evidence_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/profile-switch
mkdir -p "$evidence_dir"

export KUBECONFIG=${KUBECONFIG:-${RUNNER_TEMP:-$ROOT_DIR/artifacts}/source-kubeconfig}
agent_request k8scp1 GET /v1/cluster/kubeconfig >"$KUBECONFIG"
sed -i "s#^[[:space:]]*server:.*#    server: https://${CONTROL_PLANE_ENDPOINT}#" "$KUBECONFIG"
chmod 0600 "$KUBECONFIG"
kubectl get --raw=/readyz >"$evidence_dir/source-readyz.txt"

if profile_capability backup; then
  log "taking and restoring a fresh recovery point before leaving profile $source_profile"
  "$ROOT_DIR/scripts/backup-cluster.sh"
  "$ROOT_DIR/scripts/restore-drill.sh"

  # Preserve the newest control-plane recovery pair in the workflow evidence
  # before a target such as staging removes the source object-storage service.
  # Longhorn recovery is proved by the restore drill above; copying an entire
  # volume store into a short-lived Actions artifact would be unbounded.
  etcd_metadata="$evidence_dir/../backups/etcd-backup.json"
  control_metadata="$evidence_dir/../backups/control-plane-recovery.json"
  [[ -s "$etcd_metadata" && -s "$control_metadata" ]] \
    || die 'fresh recovery metadata is missing after the pre-switch backup'
  etcd_object=$(jq -er .object "$etcd_metadata")
  etcd_sha=$(jq -er .sha256 "$etcd_metadata")
  control_object=$(jq -er .object "$control_metadata")
  control_sha=$(jq -er .sha256 "$control_metadata")
  s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/${K8S_IMAGE_STORAGE_BUCKET}"
  s3_args=(--fail --silent --show-error --retry 3 \
    --aws-sigv4 "aws:amz:${K8S_BACKUP_REGION:-us-west-1}:s3" \
    --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")
  source_etcd_plain=$(mktemp)
  curl "${s3_args[@]}" -o "$source_etcd_plain" "$s3_base/$etcd_object"
  curl "${s3_args[@]}" -o "$evidence_dir/source-control-plane.tar.age" "$s3_base/$control_object"
  printf '%s  %s\n' "$etcd_sha" "$source_etcd_plain" | sha256sum -c -
  printf '%s  %s\n' "$control_sha" "$evidence_dir/source-control-plane.tar.age" | sha256sum -c -
  age -r "$K8S_RECOVERY_AGE_RECIPIENT" -o "$evidence_dir/source-etcd.db.age" "$source_etcd_plain"
  rm -f "$source_etcd_plain"
  chmod 0600 "$evidence_dir/source-etcd.db.age" "$evidence_dir/source-control-plane.tar.age"
else
  log "profile $source_profile has no durable backup capability; treating its cluster state as disposable"
fi

kubectl get nodes -o wide >"$evidence_dir/source-nodes.txt"
kubectl get pods -A -o wide >"$evidence_dir/source-pods.txt"
"$ROOT_DIR/scripts/destroy-cluster.sh"
log "source profile $source_profile was cleanly stopped and reset"
