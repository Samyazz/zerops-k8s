#!/usr/bin/env bash
# shellcheck disable=SC2154 # Object-storage values are loaded from Zerops at runtime.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_PROJECT_ID KUBECONFIG
require curl
require jq
require kubectl
require python3
require age
require tar

if [[ -z "${K8S_IMAGE_STORAGE_ENDPOINT:-}" ]]; then
  load_zerops_env
fi
require_env K8S_IMAGE_STORAGE_ENDPOINT K8S_IMAGE_STORAGE_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
  K8S_RECOVERY_AGE_RECIPIENT
[[ "$K8S_RECOVERY_AGE_RECIPIENT" =~ ^age1[0-9a-z]+$ ]] \
  || die 'K8S_RECOVERY_AGE_RECIPIENT is not a native age recipient'
assert_repository_cluster

backup_region=${K8S_BACKUP_REGION:-us-west-1}
backup_prefix=${K8S_BACKUP_PREFIX:-longhorn}
evidence_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/backups
work_dir=$(mktemp -d)
snapshot=$work_dir/etcd.db
downloaded=$work_dir/etcd-remote.db
metadata=$work_dir/metadata.json
recovery_manifest=$work_dir/recovery-manifest.json
recovery_bundle=$work_dir/control-plane.tar.age
recovery_downloaded=$work_dir/control-plane-remote.tar.age
recovery_metadata=$work_dir/control-plane.json
list_xml=$work_dir/list.xml
object=
recovery_object=
s3_base=
s3_args=()
recovery_set_committed=false
system_backup="zerops-$(date -u +%Y%m%d%H%M%S)-${GITHUB_RUN_ID:-local}"
system_backup=${system_backup:0:63}
reader_pod="etcd-backup-reader-${GITHUB_RUN_ID:-local}"
reader_pod=$(tr '[:upper:]_' '[:lower:]-' <<<"$reader_pod" | tr -cd 'a-z0-9-' | cut -c1-63)
etcd_snapshot_name="etcd-${GITHUB_RUN_ID:-local}-$(date -u +%s).db"
etcd_snapshot_path="/var/lib/etcd/zerops-backups/$etcd_snapshot_name"
mkdir -p "$evidence_dir"
cleanup() {
  local status=$? partial
  kubectl -n kube-system exec "$reader_pod" -- rm -f "/backup/$etcd_snapshot_name" >/dev/null 2>&1 || true
  kubectl -n kube-system delete pod "$reader_pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if (( status != 0 )) && [[ "$recovery_set_committed" != true && -n "$s3_base" ]]; then
    for partial in "$object" "$object.json" "$recovery_object" "$recovery_object.json"; do
      [[ -n "$partial" && "$partial" != .json ]] || continue
      curl "${s3_args[@]}" -X DELETE "$s3_base/$partial" >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

stream_pod_file() {
  local namespace=$1 pod=$2 remote_path=$3 destination=$4
  local block_size=1048576 chunk_blocks=8 remote_size total_blocks block blocks
  local expected received attempt part="${destination}.part" copied=false
  remote_size=$(kubectl -n "$namespace" exec "$pod" -- stat -c %s "$remote_path")
  [[ "$remote_size" =~ ^[0-9]+$ && "$remote_size" -gt 0 ]] \
    || die "could not determine the remote backup size: $remote_path"
  total_blocks=$(((remote_size + block_size - 1) / block_size))
  : >"$destination"
  for ((block = 0; block < total_blocks; block += chunk_blocks)); do
    blocks=$chunk_blocks
    (( block + blocks <= total_blocks )) || blocks=$((total_blocks - block))
    expected=$((remote_size - block * block_size))
    (( expected <= blocks * block_size )) || expected=$((blocks * block_size))
    copied=false
    for attempt in 1 2 3 4 5; do
      if kubectl -n "$namespace" exec "$pod" -- \
        dd "if=$remote_path" "bs=$block_size" "skip=$block" "count=$blocks" 2>/dev/null >"$part"; then
        received=$(stat -c %s "$part")
        if (( received == expected )); then
          cat "$part" >>"$destination"
          copied=true
          break
        fi
      fi
      log "retrying interrupted etcd snapshot chunk $((block / chunk_blocks + 1)) (attempt $attempt)"
      sleep "$attempt"
    done
    [[ "$copied" == true ]] || die "could not stream a verified etcd snapshot chunk from $pod"
  done
  rm -f "$part"
  [[ $(stat -c %s "$destination") -eq "$remote_size" ]] \
    || die 'the streamed etcd snapshot size did not match the immutable source'
}

log 'cluster lock and recovery encryption settings validated; enforcing backup capacity'
"$ROOT_DIR/scripts/backup-retention.sh" pre-backup

log 'ensuring the nested workers expose the Longhorn iSCSI frontend prerequisite'
kubectl apply -f "$ROOT_DIR/kubernetes/longhorn-node-prerequisites.yaml" >/dev/null
kubectl -n kube-system rollout status daemonset/longhorn-node-prerequisites --timeout=10m

mapfile -t interrupted_backups < <(
  kubectl -n longhorn-system get systembackups.longhorn.io -o json | jq -r \
    '.items[] | select(.status.state != "Ready") | .metadata.name'
)
if (( ${#interrupted_backups[@]} > 0 )); then
  log 'removing Longhorn proof resources left by an interrupted backup run'
  kubectl -n zerops-backup-validation delete deployment longhorn-backup-proof \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n longhorn-system delete systembackups.longhorn.io "${interrupted_backups[@]}" \
    --wait=true --timeout=5m >/dev/null
  kubectl -n zerops-backup-validation delete pvc longhorn-backup-proof \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
fi

log 'configuring the Longhorn backup target from Zerops object-storage variables'
kubectl -n longhorn-system create secret generic zerops-s3-backups \
  --from-literal="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
  --from-literal="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
  --from-literal="AWS_ENDPOINTS=$K8S_IMAGE_STORAGE_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

target_url="s3://${K8S_IMAGE_STORAGE_BUCKET}@${backup_region}/${backup_prefix}/"
target_patch=$(jq -cn \
  --arg url "$target_url" \
  --arg synced "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{spec:{backupTargetURL:$url,credentialSecret:"zerops-s3-backups",pollInterval:"1m",syncRequestedAt:$synced}}')
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge -p "$target_patch" >/dev/null
kubectl -n longhorn-system patch settings.longhorn.io allow-recurring-job-while-volume-detached \
  --type=merge -p '{"value":"true"}' >/dev/null
kubectl apply -f "$ROOT_DIR/kubernetes/longhorn-backups.yaml" >/dev/null
kubectl -n zerops-backup-validation wait pvc/longhorn-backup-proof \
  --for=jsonpath='{.status.phase}'=Bound --timeout=10m
kubectl -n zerops-backup-validation rollout status deployment/longhorn-backup-proof --timeout=10m
proof_sha=$(kubectl -n zerops-backup-validation exec deployment/longhorn-backup-proof \
  -- sha256sum /data/proof.txt | awk '{print $1}')
[[ "$proof_sha" =~ ^[0-9a-f]{64}$ ]] || die 'could not checksum the Longhorn proof payload'

deadline=$((SECONDS + 600))
until [[ $(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}') == true ]]; do
  (( SECONDS < deadline )) || {
    kubectl -n longhorn-system get backuptargets.longhorn.io default -o json \
      | jq '{status}' >"$evidence_dir/longhorn-target.json"
    die 'Longhorn backup target did not become available'
  }
  sleep 5
done

log 'creating and verifying an on-demand Longhorn system and volume backup'
kubectl -n longhorn-system create -f - >/dev/null <<EOF
apiVersion: longhorn.io/v1beta2
kind: SystemBackup
metadata:
  name: $system_backup
spec:
  volumeBackupPolicy: always
EOF

deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  state=$(kubectl -n longhorn-system get systembackups.longhorn.io "$system_backup" -o jsonpath='{.status.state}')
  case "$state" in
    Ready) break ;;
    Error)
      kubectl -n longhorn-system get systembackups.longhorn.io "$system_backup" -o json \
        | jq '{metadata:{name:.metadata.name},status}' >"$evidence_dir/longhorn-system-backup.json"
      die 'Longhorn system backup failed'
      ;;
  esac
  sleep 10
done
[[ ${state:-} == Ready ]] || die 'Longhorn system backup did not become Ready within 30 minutes'

proof_volume=$(kubectl -n zerops-backup-validation get pvc longhorn-backup-proof -o jsonpath='{.spec.volumeName}')
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  completed=$(kubectl -n longhorn-system get backups.longhorn.io -o json | jq \
    --arg volume "$proof_volume" '[.items[] | select(.status.volumeName == $volume and .status.state == "Completed")] | length')
  (( completed > 0 )) && break
  sleep 10
done
(( ${completed:-0} > 0 )) || die 'Longhorn did not produce a completed backup for the proof volume'

longhorn_retain=${K8S_LONGHORN_SYSTEM_BACKUP_RETAIN:-8}
[[ "$longhorn_retain" =~ ^[0-9]+$ && "$longhorn_retain" -ge 2 ]] \
  || die 'K8S_LONGHORN_SYSTEM_BACKUP_RETAIN must be an integer of at least 2'
mapfile -t expired_system_backups < <(
  kubectl -n longhorn-system get systembackups.longhorn.io -o json | jq -r \
    --argjson retain "$longhorn_retain" '
      [.items[] | select(.metadata.name | startswith("zerops-")) | select(.status.state == "Ready")]
      | sort_by(.metadata.creationTimestamp) | reverse | .[$retain:][]?.metadata.name
    '
)
if (( ${#expired_system_backups[@]} > 0 )); then
  kubectl -n longhorn-system delete systembackups.longhorn.io \
    "${expired_system_backups[@]}" --wait=true --timeout=10m >/dev/null
fi
jq -n --argjson retained "$longhorn_retain" \
  --argjson pruned "${#expired_system_backups[@]}" \
  '{retainedLimit:$retained,prunedReadySystemBackups:$pruned}' \
  >"$evidence_dir/longhorn-retention.json"

kubectl -n longhorn-system get backuptargets.longhorn.io default -o json \
  | jq '{metadata:{name:.metadata.name},spec:{pollInterval:.spec.pollInterval},status:{available:.status.available,lastSyncedAt:.status.lastSyncedAt}}' \
  >"$evidence_dir/longhorn-target.json"
kubectl -n longhorn-system get systembackups.longhorn.io "$system_backup" -o json \
  | jq '{metadata:{name:.metadata.name},spec,status}' >"$evidence_dir/longhorn-system-backup.json"
kubectl -n longhorn-system get backups.longhorn.io -o json \
  | jq --arg volume "$proof_volume" \
    '{backups:[.items[] | select(.status.volumeName == $volume) | {name:.metadata.name,state:.status.state,progress:.status.progress,createdAt:.status.backupCreatedAt,size:.status.size}]}' \
  >"$evidence_dir/longhorn-volume-backups.json"

log 'creating and validating a consistent etcd snapshot on k8scp1'
kubectl -n kube-system delete pod "$reader_pod" --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $reader_pod
  namespace: kube-system
  labels:
    app.kubernetes.io/name: zerops-etcd-backup-reader
spec:
  nodeName: k8scp1
  restartPolicy: Never
  automountServiceAccountToken: false
  tolerations:
    - operator: Exists
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: reader
      image: busybox:1.36.1
      command: [sh, -c, "sleep 1800"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
          # The persisted kubeadm directory is 0700 and owned by the nested
          # node UID. Grant read/traverse only; the hostPath remains read-only.
          add: [DAC_READ_SEARCH]
      resources:
        requests: {cpu: 5m, memory: 8Mi}
        limits: {cpu: 50m, memory: 32Mi}
      volumeMounts:
        - name: backup
          mountPath: /backup
        - name: control-plane
          mountPath: /control-plane
          readOnly: true
  volumes:
    - name: backup
      hostPath:
        path: /var/lib/etcd/zerops-backups
        type: DirectoryOrCreate
    - name: control-plane
      hostPath:
        path: /etc/kubernetes
        type: Directory
EOF
kubectl -n kube-system wait pod/"$reader_pod" --for=condition=Ready --timeout=5m
etcd_pod=$(kubectl -n kube-system get pods -l component=etcd \
  --field-selector spec.nodeName=k8scp1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$etcd_pod" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save "$etcd_snapshot_path" >/dev/null
kubectl -n kube-system exec "$etcd_pod" -- etcdutl snapshot status \
  --write-out=json "$etcd_snapshot_path" \
  | jq '{hash,revision,totalKey,totalSize}' >"$evidence_dir/etcd-snapshot-status.json"
reader_sha=$(kubectl -n kube-system exec "$reader_pod" -- sha256sum "/backup/$etcd_snapshot_name" | awk '{print $1}')
stream_pod_file kube-system "$reader_pod" "/backup/$etcd_snapshot_name" "$snapshot"
[[ -s "$snapshot" ]] || die 'the etcd snapshot reader returned an empty file'
local_sha=$(sha256sum "$snapshot" | awk '{print $1}')
[[ "$local_sha" == "$reader_sha" ]] || die 'etcd snapshot checksum changed while streaming from k8scp1'

timestamp=$(date -u +%Y/%m/%d/%Y%m%dT%H%M%SZ)
object="etcd/${timestamp}-${GITHUB_RUN_ID:-local}.db"
recovery_object="control-plane/${timestamp}-${GITHUB_RUN_ID:-local}.tar.age"
s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/${K8S_IMAGE_STORAGE_BUCKET}"
s3_args=(--fail --silent --show-error --retry 3 --aws-sigv4 "aws:amz:${backup_region}:s3" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")
curl "${s3_args[@]}" -T "$snapshot" "$s3_base/$object"

jq -n \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repository "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" \
  --arg runId "${GITHUB_RUN_ID:-local}" \
  --arg kubernetesVersion "$(kubectl version -o json | jq -r '.serverVersion.gitVersion')" \
  --arg etcdImage "$(kubectl -n kube-system get pod "$etcd_pod" -o jsonpath='{.spec.containers[0].image}')" \
  --arg etcdObject "$object" \
  --argjson nodes "$(kubectl get nodes -o json | jq '[.items[] | {name:.metadata.name,kubeletVersion:.status.nodeInfo.kubeletVersion,containerRuntimeVersion:.status.nodeInfo.containerRuntimeVersion}] | sort_by(.name)')" \
  '{createdAt:$createdAt,repository:$repository,runId:$runId,
    kubernetesVersion:$kubernetesVersion,etcdImage:$etcdImage,etcdObject:$etcdObject,nodes:$nodes}' \
  >"$recovery_manifest"
kubectl -n kube-system exec -i "$reader_pod" -- sh -c \
  'umask 077; cat > /tmp/recovery-manifest.json' <"$recovery_manifest"

log 'encrypting the Kubernetes PKI, signing keys, manifests, and encryption configuration'
# shellcheck disable=SC2016 # The single-quoted program intentionally expands inside the reader Pod.
kubectl -n kube-system exec "$reader_pod" -- sh -ec '
  staging=/tmp/control-plane-recovery
  rm -rf "$staging"
  mkdir -p "$staging"
  for path in pki manifests admin.conf controller-manager.conf scheduler.conf kubelet.conf encryption-config.yaml audit-policy.yaml; do
    test -e "/control-plane/$path"
    cp -R "/control-plane/$path" "$staging/"
  done
  if test -f /control-plane/zerops-init.yaml; then cp /control-plane/zerops-init.yaml "$staging/"; fi
  cp /tmp/recovery-manifest.json "$staging/"
  chmod -R go-rwx "$staging"
  tar -C "$staging" -czf - .
' | age -r "$K8S_RECOVERY_AGE_RECIPIENT" -o "$recovery_bundle"
[[ -s "$recovery_bundle" ]] || die 'encrypted control-plane recovery bundle is empty'
recovery_sha=$(sha256sum "$recovery_bundle" | awk '{print $1}')
curl "${s3_args[@]}" -T "$recovery_bundle" "$s3_base/$recovery_object"

jq -cn --arg object "$object" --arg sha256 "$local_sha" \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson bytes "$(stat -c %s "$snapshot")" \
  --arg recoveryBundleObject "$recovery_object" \
  '{object:$object,sha256:$sha256,bytes:$bytes,createdAt:$createdAt,
    recoveryBundleObject:$recoveryBundleObject,verified:true}' >"$metadata"
jq -cn --arg object "$recovery_object" --arg sha256 "$recovery_sha" \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg etcdObject "$object" --argjson bytes "$(stat -c %s "$recovery_bundle")" \
  '{object:$object,sha256:$sha256,bytes:$bytes,createdAt:$createdAt,
    etcdObject:$etcdObject,encryption:"age-x25519",verified:true}' >"$recovery_metadata"

log 'downloading the new etcd and encrypted recovery objects and comparing them byte-for-byte'
curl "${s3_args[@]}" -o "$downloaded" "$s3_base/$object"
remote_sha=$(sha256sum "$downloaded" | awk '{print $1}')
[[ "$remote_sha" == "$local_sha" ]] || die 'downloaded etcd backup checksum did not match'
curl "${s3_args[@]}" -o "$recovery_downloaded" "$s3_base/$recovery_object"
remote_recovery_sha=$(sha256sum "$recovery_downloaded" | awk '{print $1}')
[[ "$remote_recovery_sha" == "$recovery_sha" ]] \
  || die 'downloaded control-plane recovery bundle checksum did not match'
curl "${s3_args[@]}" -H 'Content-Type: application/json' \
  -T "$recovery_metadata" "$s3_base/$recovery_object.json"
curl "${s3_args[@]}" -H 'Content-Type: application/json' -T "$metadata" "$s3_base/$object.json"
recovery_set_committed=true
install -m 0600 "$metadata" "$evidence_dir/etcd-backup.json"
install -m 0600 "$recovery_metadata" "$evidence_dir/control-plane-recovery.json"

curl "${s3_args[@]}" -o "$list_xml" "$s3_base?list-type=2&prefix=${backup_prefix}%2F"
longhorn_objects=$(python3 - "$list_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
print(len(root.findall('.//{*}Contents')))
PY
)
(( longhorn_objects > 0 )) || die 'Longhorn reported completion but its S3 prefix is empty'
jq -cn --argjson longhornObjects "$longhorn_objects" --arg proofVolume "$proof_volume" \
  --arg proofSha256 "$proof_sha" \
  '{longhornObjects:$longhornObjects,proofVolume:$proofVolume,
    proofSha256:$proofSha256,verified:true}' \
  >"$evidence_dir/s3-longhorn-proof.json"

"$ROOT_DIR/scripts/backup-retention.sh" post-backup
log "verified bounded etcd, encrypted control-plane, and Longhorn backups in Zerops object storage"
