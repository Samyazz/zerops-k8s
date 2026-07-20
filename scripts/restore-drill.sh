#!/usr/bin/env bash
# shellcheck disable=SC2154 # Object-storage values are loaded from Zerops at runtime.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_PROJECT_ID KUBECONFIG K8S_RECOVERY_AGE_IDENTITY
require age
require curl
require docker
require jq
require kubectl
require python3
require tar

if [[ -z "${K8S_IMAGE_STORAGE_ENDPOINT:-}" ]]; then
  load_zerops_env
fi
require_env K8S_IMAGE_STORAGE_ENDPOINT K8S_IMAGE_STORAGE_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
grep -q '^AGE-SECRET-KEY-' <<<"$K8S_RECOVERY_AGE_IDENTITY" \
  || die 'K8S_RECOVERY_AGE_IDENTITY does not contain a native age identity'
assert_repository_cluster

backup_region=${K8S_BACKUP_REGION:-us-west-1}
evidence_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/restore-drill
work_dir=$(mktemp -d)
identity=$work_dir/identity.txt
snapshot=$work_dir/etcd.db
metadata=$work_dir/etcd.json
bundle=$work_dir/control-plane.tar.age
bundle_metadata=$work_dir/control-plane.json
bundle_plain=$work_dir/control-plane.tar.gz
recovery_manifest=$work_dir/recovery-manifest.json
list_xml=$work_dir/list.xml
inventory=$work_dir/inventory.json
restored_dir=$work_dir/restored-etcd
run_suffix=$(tr '[:upper:]_' '[:lower:]-' <<<"${GITHUB_RUN_ID:-local}" | tr -cd 'a-z0-9-' | tail -c 21)
restore_volume="restore-drill-${run_suffix:-local}"
restore_pv="${restore_volume}-pv"
restore_pvc="${restore_volume}-pvc"
restore_pod="${restore_volume}-reader"
etcd_container="zerops-etcd-restore-${run_suffix:-local}"
mkdir -p "$evidence_dir"
printf '%s\n' "$K8S_RECOVERY_AGE_IDENTITY" >"$identity"
chmod 0600 "$identity"

cleanup() {
  docker rm -f "$etcd_container" >/dev/null 2>&1 || true
  kubectl -n zerops-backup-validation delete pod "$restore_pod" \
    --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || true
  kubectl -n zerops-backup-validation delete pvc "$restore_pvc" \
    --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || true
  kubectl delete pv "$restore_pv" --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || true
  kubectl -n longhorn-system delete volumes.longhorn.io "$restore_volume" \
    --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/${K8S_IMAGE_STORAGE_BUCKET}"
s3_args=(--fail --silent --show-error --retry 3 --retry-all-errors \
  --aws-sigv4 "aws:amz:${backup_region}:s3" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")

log 'selecting the newest verified etcd recovery point'
curl "${s3_args[@]}" --get --data-urlencode 'list-type=2' --data-urlencode 'max-keys=1000' \
  --data-urlencode 'prefix=etcd/' -o "$list_xml" "$s3_base"
python3 - "$list_xml" >"$inventory" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
items = []
for item in root.findall('.//{*}Contents'):
    items.append({
        'Key': item.findtext('{*}Key', default=''),
        'LastModified': item.findtext('{*}LastModified', default=''),
        'Size': int(item.findtext('{*}Size', default='0')),
    })
json.dump(items, sys.stdout, separators=(',', ':'))
PY
metadata_object=$(jq -er '[.[] | select(.Key | test("^etcd/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]+\\.db\\.json$"))] | sort_by(.Key) | last | .Key' "$inventory")
curl "${s3_args[@]}" -o "$metadata" "$s3_base/$metadata_object"
jq -e '.verified == true and (.object | type == "string") and (.recoveryBundleObject | type == "string")' \
  "$metadata" >/dev/null || die 'latest etcd metadata is not a verified complete recovery point'
snapshot_object=$(jq -r '.object' "$metadata")
bundle_object=$(jq -r '.recoveryBundleObject' "$metadata")
expected_snapshot_sha=$(jq -r '.sha256' "$metadata")
curl "${s3_args[@]}" -o "$snapshot" "$s3_base/$snapshot_object"
[[ $(sha256sum "$snapshot" | awk '{print $1}') == "$expected_snapshot_sha" ]] \
  || die 'restore-drill etcd download failed its recorded checksum'

curl "${s3_args[@]}" -o "$bundle_metadata" "$s3_base/$bundle_object.json"
jq -e --arg etcd "$snapshot_object" '.verified == true and .etcdObject == $etcd and .encryption == "age-x25519"' \
  "$bundle_metadata" >/dev/null || die 'control-plane recovery metadata does not match the etcd recovery point'
expected_bundle_sha=$(jq -r '.sha256' "$bundle_metadata")
curl "${s3_args[@]}" -o "$bundle" "$s3_base/$bundle_object"
[[ $(sha256sum "$bundle" | awk '{print $1}') == "$expected_bundle_sha" ]] \
  || die 'restore-drill control-plane bundle failed its recorded checksum'

log 'decrypting and validating the control-plane recovery identity bundle'
age --decrypt -i "$identity" -o "$bundle_plain" "$bundle"
for required in \
  ./pki/ca.key ./pki/sa.key ./pki/front-proxy-ca.key ./pki/etcd/ca.key \
  ./manifests/etcd.yaml ./encryption-config.yaml ./recovery-manifest.json; do
  tar -tzf "$bundle_plain" | grep -Fx "$required" >/dev/null \
    || die "control-plane recovery bundle is missing $required"
done
tar -xOzf "$bundle_plain" ./recovery-manifest.json >"$recovery_manifest"
jq -e --arg object "$snapshot_object" '.etcdObject == $object and (.nodes | length >= 6)' \
  "$recovery_manifest" >/dev/null || die 'recovery manifest does not describe the selected cluster snapshot'
etcd_image=$(jq -er '.etcdImage' "$recovery_manifest")
[[ "$etcd_image" =~ ^registry\.k8s\.io/etcd:[A-Za-z0-9._-]+$ ]] \
  || die 'recovery manifest contains an unsupported etcd image reference'

log 'restoring the etcd snapshot into an isolated disposable member'
mkdir -p "$restored_dir"
docker pull "$etcd_image" >/dev/null
docker run --rm --user 0:0 --entrypoint=/usr/local/bin/etcdutl \
  -v "$work_dir:/work" "$etcd_image" snapshot restore /work/etcd.db \
  --data-dir /work/restored-etcd --name restore-drill \
  --initial-cluster restore-drill=http://127.0.0.1:2380 \
  --initial-advertise-peer-urls http://127.0.0.1:2380 >/dev/null
docker run --rm -d --name "$etcd_container" \
  -p 127.0.0.1:23790:2379 -v "$restored_dir:/var/lib/etcd" \
  --entrypoint=/usr/local/bin/etcd "$etcd_image" \
  --name restore-drill --data-dir=/var/lib/etcd \
  --listen-client-urls=http://0.0.0.0:2379 \
  --advertise-client-urls=http://127.0.0.1:2379 \
  --listen-peer-urls=http://0.0.0.0:2380 >/dev/null
deadline=$((SECONDS + 120))
until docker exec "$etcd_container" etcdctl --endpoints=http://127.0.0.1:2379 endpoint health >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die 'isolated restored etcd member did not become healthy'
  sleep 2
done
restored_keys=$(docker exec "$etcd_container" etcdctl --endpoints=http://127.0.0.1:2379 \
  get /registry/ --prefix --keys-only | sed '/^$/d' | wc -l)
(( restored_keys > 100 )) || die 'isolated restored etcd member contains too few Kubernetes registry keys'
docker exec "$etcd_container" etcdctl --endpoints=http://127.0.0.1:2379 \
  get /registry/namespaces/default --keys-only | grep -Fx '/registry/namespaces/default' >/dev/null \
  || die 'restored etcd member does not contain the default namespace key'

log 'restoring the newest Longhorn proof backup as a separate volume'
proof_volume=$(kubectl -n zerops-backup-validation get pvc longhorn-backup-proof -o jsonpath='{.spec.volumeName}')
source_sha=$(kubectl -n zerops-backup-validation exec deployment/longhorn-backup-proof \
  -- sha256sum /data/proof.txt | awk '{print $1}')
backup_json=$(kubectl -n longhorn-system get backups.longhorn.io -o json | jq -c \
  --arg volume "$proof_volume" '
    [.items[] | select(.status.volumeName == $volume and .status.state == "Completed")]
    | sort_by(.status.backupCreatedAt) | last
  ')
backup_name=$(jq -er '.metadata.name' <<<"$backup_json")
backup_url=$(jq -er '.status.url' <<<"$backup_json")
volume_size=$(jq -er '.status.volumeSize' <<<"$backup_json")
[[ "$volume_size" =~ ^[0-9]+$ && "$volume_size" -gt 0 ]] \
  || die 'Longhorn backup reported an invalid volume size'

kubectl -n longhorn-system apply -f - >/dev/null <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $restore_volume
spec:
  size: "$volume_size"
  fromBackup: "$backup_url"
  numberOfReplicas: 3
  frontend: blockdev
  dataEngine: v1
EOF
deadline=$((SECONDS + 1200))
while (( SECONDS < deadline )); do
  restore_required=$(kubectl -n longhorn-system get volumes.longhorn.io "$restore_volume" \
    -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)
  restore_state=$(kubectl -n longhorn-system get volumes.longhorn.io "$restore_volume" \
    -o jsonpath='{.status.state}' 2>/dev/null || true)
  [[ "$restore_required" == false && "$restore_state" == detached ]] && break
  sleep 5
done
[[ "$restore_required" == false && "$restore_state" == detached ]] \
  || die 'Longhorn proof-volume restore did not complete while detached'

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $restore_pv
spec:
  capacity:
    storage: "$volume_size"
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    volumeHandle: $restore_volume
    fsType: ext4
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $restore_pvc
  namespace: zerops-backup-validation
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: "$volume_size"
  volumeName: $restore_pv
  storageClassName: longhorn
---
apiVersion: v1
kind: Pod
metadata:
  name: $restore_pod
  namespace: zerops-backup-validation
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: reader
      image: busybox:1.36.1
      command: [sh, -c, "test -s /data/proof.txt && sleep 1800"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      resources:
        requests: {cpu: 5m, memory: 8Mi}
        limits: {cpu: 50m, memory: 32Mi}
      volumeMounts:
        - {name: data, mountPath: /data, readOnly: true}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: $restore_pvc, readOnly: true}
EOF
kubectl -n zerops-backup-validation wait pod/"$restore_pod" --for=condition=Ready --timeout=10m
restored_sha=$(kubectl -n zerops-backup-validation exec "$restore_pod" -- sha256sum /data/proof.txt | awk '{print $1}')
[[ "$restored_sha" == "$source_sha" ]] || die 'restored Longhorn proof payload checksum differs from the live source'

jq -n \
  --arg etcdObject "$snapshot_object" \
  --arg recoveryBundleObject "$bundle_object" \
  --arg etcdImage "$etcd_image" \
  --argjson restoredRegistryKeys "$restored_keys" \
  --arg longhornBackup "$backup_name" \
  --arg sourceSha256 "$source_sha" \
  --arg restoredSha256 "$restored_sha" \
  '{verified:true,etcd:{object:$etcdObject,image:$etcdImage,healthy:true,
      restoredRegistryKeys:$restoredRegistryKeys,defaultNamespacePresent:true},
    controlPlane:{object:$recoveryBundleObject,decrypted:true,requiredIdentityFilesPresent:true},
    longhorn:{backup:$longhornBackup,sourceSha256:$sourceSha256,
      restoredSha256:$restoredSha256,contentMatched:true}}' \
  >"$evidence_dir/restore-drill.json"

log 'isolated etcd, encrypted control-plane bundle, and Longhorn content restore drills passed'
