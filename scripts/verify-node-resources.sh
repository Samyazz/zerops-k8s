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

cp_mode=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.cpuMode' "$PROFILE_FILE")
cp_default_cpu=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")
cp_default_ram=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")
cp_default_disk=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")
worker_mode=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpuMode' "$PROFILE_FILE")
worker_default_cpu=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")
worker_default_ram=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")
worker_default_disk=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")
cp_cpu=$(cluster_tag_value cp-cpu); cp_cpu=${cp_cpu:-$cp_default_cpu}
cp_ram=$(cluster_tag_value cp-ram); cp_ram=${cp_ram:-$cp_default_ram}
cp_disk=$(cluster_tag_value cp-disk); cp_disk=${cp_disk:-$cp_default_disk}
worker_cpu=$(cluster_tag_value worker-cpu); worker_cpu=${worker_cpu:-$worker_default_cpu}
worker_ram=$(cluster_tag_value worker-ram); worker_ram=${worker_ram:-$worker_default_ram}
worker_disk=$(cluster_tag_value worker-disk); worker_disk=${worker_disk:-$worker_default_disk}
workers=$(cluster_tag_value workers); workers=${workers:-${#WORKERS[@]}}
node_contract=$(mktemp)
trap 'rm -f "$response" "$evidence" "$node_contract"' EXIT
for node in "${CONTROL_PLANES[@]}"; do
  printf '%s %s %s %s %s\n' "$node" "$cp_mode" "$cp_cpu" "$cp_ram" "$cp_disk" >>"$node_contract"
done
for node in "${WORKERS[@]}"; do
  printf '%s %s %s %s %s\n' "$node" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk" >>"$node_contract"
done
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
if (( workers > ${#WORKERS[@]} )); then
  for node in "${optional_workers[@]}"; do
    printf '%s %s %s %s %s\n' "$node" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk" >>"$node_contract"
  done
fi

while read -r hostname cpu_mode cpu ram disk; do
  jq -cer \
    --arg hostname "$hostname" \
    --arg cpu_mode "$cpu_mode" \
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
          .cpuMode == $cpu_mode
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
log "verified $((workers + ${#CONTROL_PLANES[@]})) single-instance Zerops nodes match the persisted $K8S_PROFILE resource contract"
