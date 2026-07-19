#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require curl
require jq

output=${1:-}
response=$(mktemp)
evidence=$(mktemp)
trap 'rm -f "$response" "$evidence"' EXIT

api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"

cp_cpu=$(cluster_tag_value cp-cpu); cp_cpu=${cp_cpu:-4}
cp_ram=$(cluster_tag_value cp-ram); cp_ram=${cp_ram:-8}
cp_disk=$(cluster_tag_value cp-disk); cp_disk=${cp_disk:-20}
worker_cpu=$(cluster_tag_value worker-cpu); worker_cpu=${worker_cpu:-4}
worker_ram=$(cluster_tag_value worker-ram); worker_ram=${worker_ram:-12}
worker_disk=$(cluster_tag_value worker-disk); worker_disk=${worker_disk:-50}
workers=$(cluster_tag_value workers); workers=${workers:-3}
node_contract=$(mktemp)
trap 'rm -f "$response" "$evidence" "$node_contract"' EXIT
printf '%s %s %s %s\n' \
  k8scp1 "$cp_cpu" "$cp_ram" "$cp_disk" \
  k8scp2 "$cp_cpu" "$cp_ram" "$cp_disk" \
  k8scp3 "$cp_cpu" "$cp_ram" "$cp_disk" \
  k8sworker1 "$worker_cpu" "$worker_ram" "$worker_disk" \
  k8sworker2 "$worker_cpu" "$worker_ram" "$worker_disk" \
  k8sworker3 "$worker_cpu" "$worker_ram" "$worker_disk" >"$node_contract"
if [[ "$workers" == 4 ]]; then
  printf '%s %s %s %s\n' k8sworker4 "$worker_cpu" "$worker_ram" "$worker_disk" >>"$node_contract"
fi

while read -r hostname cpu ram disk; do
  jq -cer \
    --arg hostname "$hostname" \
    --argjson cpu "$cpu" \
    --argjson ram "$ram" \
    --argjson disk "$disk" '
      .list[]
      | select(.name == $hostname)
      | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling) as $v
      | (.currentAutoscaling.horizontalAutoscaling // .customAutoscaling.horizontalAutoscaling) as $h
      | {
          hostname: .name,
          serviceId: .id,
          cpuMode: $v.cpuMode,
          minCpu: $v.minResource.cpuCoreCount,
          maxCpu: $v.maxResource.cpuCoreCount,
          startCpu: $v.startCpuCoreCount,
          minRamGB: $v.minResource.memoryGBytes,
          maxRamGB: $v.maxResource.memoryGBytes,
          minDiskGB: $v.minResource.diskGBytes,
          maxDiskGB: $v.maxResource.diskGBytes,
          minInstances: $h.minContainerCount,
          maxInstances: $h.maxContainerCount
        }
      | select(
          .cpuMode == "DEDICATED"
          and .minCpu == $cpu and .maxCpu == $cpu and .startCpu == $cpu
          and .minRamGB == $ram and .maxRamGB == $ram
          and .minDiskGB == $disk and .maxDiskGB == $disk
          and .minInstances == 1 and .maxInstances == 1
        )
    ' "$response" >> "$evidence" \
    || die "Zerops node resources do not match the dedicated fixed-size contract: $hostname"
done <"$node_contract"

result=$(jq -s --arg projectId "$ZEROPS_PROJECT_ID" \
  '{projectId:$projectId,verified:true,nodes:sort_by(.hostname)}' "$evidence")
if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$result" > "$output"
else
  printf '%s\n' "$result"
fi
log "verified $((workers + 3)) single-instance Zerops nodes match the persisted dedicated resource contract"
