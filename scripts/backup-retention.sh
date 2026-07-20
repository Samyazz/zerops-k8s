#!/usr/bin/env bash
# shellcheck disable=SC2154 # Object-storage values are loaded from Zerops at runtime.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

phase=${1:-post-backup}
[[ "$phase" =~ ^[a-z0-9-]+$ ]] || die 'retention phase contains unsupported characters'

require_env ZEROPS_PROJECT_ID K8S_IMAGE_STORAGE_ENDPOINT K8S_IMAGE_STORAGE_BUCKET \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
require curl
require jq
require python3

backup_region=${K8S_BACKUP_REGION:-us-west-1}
recent=${K8S_ETCD_RETENTION_RECENT:-28}
daily=${K8S_ETCD_RETENTION_DAILY:-7}
weekly=${K8S_ETCD_RETENTION_WEEKLY:-4}
monthly=${K8S_ETCD_RETENTION_MONTHLY:-3}
warn_percent=${K8S_BACKUP_WARN_PERCENT:-70}
fail_percent=${K8S_BACKUP_FAIL_PERCENT:-95}
desired_quota_gb=${K8S_BACKUP_QUOTA_GB:-25}
for value in "$recent" "$daily" "$weekly" "$monthly" "$warn_percent" "$fail_percent" "$desired_quota_gb"; do
  [[ "$value" =~ ^[0-9]+$ ]] || die 'backup retention and capacity settings must be integers'
done
(( recent >= 2 )) || die 'K8S_ETCD_RETENTION_RECENT must be at least 2'
(( desired_quota_gb >= 5 )) || die 'K8S_BACKUP_QUOTA_GB must be at least 5'
(( warn_percent > 0 && warn_percent < fail_percent && fail_percent <= 100 )) \
  || die 'capacity thresholds must satisfy 0 < warning < failure <= 100'

work_dir=$(mktemp -d)
inventory=$work_dir/inventory.json
verified_inventory=$work_dir/verified-inventory.json
plan=$work_dir/retention-plan.json
evidence_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/backups
mkdir -p "$evidence_dir"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT INT TERM

s3_base="${K8S_IMAGE_STORAGE_ENDPOINT%/}/${K8S_IMAGE_STORAGE_BUCKET}"
s3_args=(--fail --silent --show-error --retry 3 --retry-all-errors \
  --aws-sigv4 "aws:amz:${backup_region}:s3" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY")

list_inventory() {
  local output=$1 token='' page=$work_dir/page.xml ndjson=$work_dir/inventory.ndjson truncated
  local -a request
  : >"$ndjson"
  while true; do
    request=("${s3_args[@]}" --get --data-urlencode 'list-type=2' --data-urlencode 'max-keys=1000')
    [[ -z "$token" ]] || request+=(--data-urlencode "continuation-token=$token")
    curl "${request[@]}" -o "$page" "$s3_base"
    python3 - "$page" >>"$ndjson" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for item in root.findall('.//{*}Contents'):
    print(json.dumps({
        'Key': item.findtext('{*}Key', default=''),
        'LastModified': item.findtext('{*}LastModified', default=''),
        'Size': int(item.findtext('{*}Size', default='0')),
    }, separators=(',', ':')))
PY
    read -r truncated token < <(python3 - "$page" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
truncated = root.findtext('{*}IsTruncated', default='false').lower()
token = root.findtext('{*}NextContinuationToken', default='')
print(truncated, token)
PY
)
    [[ "$truncated" == true ]] || break
    [[ -n "$token" ]] || die 'S3 inventory was truncated without a continuation token'
  done
  jq -s '.' "$ndjson" >"$output"
}

annotate_verified_sets() {
  local input=$1 output=$2 metadata_object snapshot relative recovery
  local snapshot_metadata=$work_dir/snapshot-metadata.json
  local recovery_metadata=$work_dir/recovery-metadata.json
  local verified=$work_dir/verified-snapshots.ndjson
  : >"$verified"

  while IFS= read -r metadata_object; do
    snapshot=${metadata_object%.json}
    relative=${snapshot#etcd/}
    relative=${relative%.db}
    recovery="control-plane/${relative}.tar.age"
    jq -e --arg recovery "$recovery" \
      'any(.[]; .Key == $recovery) and any(.[]; .Key == ($recovery + ".json"))' \
      "$input" >/dev/null || continue
    curl "${s3_args[@]}" -o "$snapshot_metadata" "$s3_base/$metadata_object" || continue
    curl "${s3_args[@]}" -o "$recovery_metadata" "$s3_base/$recovery.json" || continue
    jq -e --arg snapshot "$snapshot" --arg recovery "$recovery" '
      .verified == true and .object == $snapshot and .recoveryBundleObject == $recovery
      and (.bytes | type == "number" and . > 0)
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$snapshot_metadata" >/dev/null || continue
    jq -e --arg snapshot "$snapshot" --arg recovery "$recovery" '
      .verified == true and .object == $recovery and .etcdObject == $snapshot
      and .encryption == "age-x25519"
      and (.bytes | type == "number" and . > 0)
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$recovery_metadata" >/dev/null || continue
    jq -cn --arg key "$snapshot" '{key:$key}' >>"$verified"
  done < <(jq -r '.[] | .Key | select(test("^etcd/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]+\\.db\\.json$"))' "$input")

  jq --slurpfile verified "$verified" '
    ($verified | map(.key)) as $verifiedKeys
    | map(. + {VerifiedSet:(.Key as $key | $verifiedKeys | index($key) != null)})
  ' "$input" >"$output"
}

object_storage_settings() {
  local services=$work_dir/services.json settings=$work_dir/object-storage-settings.json service_id
  require_env ZEROPS_TOKEN
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?nameContains=k8sbackups&limit=100" '' "$services"
  service_id=$(jq -er '.list[] | select(.name == "k8sbackups") | .id' "$services") \
    || die 'could not find the k8sbackups service in the Zerops project'
  api_request_file GET "/service-stack/${service_id}/object-storage-size" '' "$settings"
  jq -e --arg serviceId "$service_id" '. + {serviceId:$serviceId}' "$settings"
}

read_zerops_quota_env() {
  local quota
  quota=$(zcli project env -P "$ZEROPS_PROJECT_ID" \
    --template '{{if eq .Key "k8sbackups_quotaGBytes"}}{{.Value}}{{end}}' 2>/dev/null \
    | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '"[:space:]')
  [[ "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 ]] \
    || die 'could not determine the k8sbackups object-storage quota'
  printf '%s\n' "$quota"
}

ensure_object_storage_quota() {
  local settings current service_id payload response deadline
  settings=$(object_storage_settings)
  current=$(read_zerops_quota_env)
  (( current < desired_quota_gb )) || return 0

  service_id=$(jq -er '.serviceId' <<<"$settings")
  payload=$(jq -c --argjson diskGBytes "$desired_quota_gb" '
    {
      diskGBytes:$diskGBytes,
      policy:(.policy // "private"),
      rawPolicy:(.rawPolicy // null),
      cdnEnabled:(.cdnEnabled // false)
    }
  ' <<<"$settings")
  response=$work_dir/object-storage-resize.json
  log "increasing the k8sbackups quota in place from ${current} GB to ${desired_quota_gb} GB"
  api_request_file PUT "/service-stack/${service_id}/object-storage-size" "$payload" "$response"

  deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    current=$(read_zerops_quota_env)
    (( current >= desired_quota_gb )) && return 0
    sleep 5
  done
  die "k8sbackups quota did not reach ${desired_quota_gb} GB within 20 minutes"
}

read_quota_gb() {
  read_zerops_quota_env
}

ensure_object_storage_quota
log "applying verified etcd retention policy before the $phase capacity check"
list_inventory "$inventory"
annotate_verified_sets "$inventory" "$verified_inventory"
python3 "$ROOT_DIR/scripts/retention_policy.py" \
  --recent "$recent" --daily "$daily" --weekly "$weekly" --monthly "$monthly" \
  <"$verified_inventory" >"$plan"

deleted=0
while IFS= read -r object; do
  [[ -n "$object" ]] || continue
  curl "${s3_args[@]}" -X DELETE "$s3_base/$object"
  deleted=$((deleted + 1))
done < <(jq -r '.deleteObjects[]' "$plan")

list_inventory "$inventory"
used_bytes=$(jq '[.[].Size] | add // 0' "$inventory")
object_count=$(jq 'length' "$inventory")
quota_gb=$(read_quota_gb)
quota_bytes=$((quota_gb * 1000 * 1000 * 1000))
used_percent=$(((used_bytes * 100 + quota_bytes - 1) / quota_bytes))

jq -n \
  --arg phase "$phase" \
  --argjson usedBytes "$used_bytes" \
  --argjson quotaBytes "$quota_bytes" \
  --argjson usedPercent "$used_percent" \
  --argjson objectCount "$object_count" \
  --argjson deletedObjects "$deleted" \
  --argjson warningPercent "$warn_percent" \
  --argjson failurePercent "$fail_percent" \
  --slurpfile retention "$plan" \
  '{phase:$phase,usedBytes:$usedBytes,quotaBytes:$quotaBytes,usedPercent:$usedPercent,
    objectCount:$objectCount,deletedObjects:$deletedObjects,
    thresholds:{warningPercent:$warningPercent,failurePercent:$failurePercent},
    retention:$retention[0]}' \
  >"$evidence_dir/capacity-${phase}.json"

if (( used_percent >= fail_percent )); then
  die "backup bucket is ${used_percent}% full after safe pruning; increase its quota before another backup"
fi
if (( used_percent >= warn_percent )); then
  log "WARNING: backup bucket is ${used_percent}% full after safe pruning"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    printf '::warning title=Zerops backup capacity::Backup bucket is %s%% full after safe pruning.\n' "$used_percent"
  fi
fi
log "backup retention retained verified recovery points and left the bucket ${used_percent}% full"
