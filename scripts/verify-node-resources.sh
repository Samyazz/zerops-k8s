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
done <<'EOF'
k8scp1 4 8 20
k8scp2 4 8 20
k8scp3 4 8 20
k8sworker1 4 12 50
k8sworker2 4 12 50
k8sworker3 4 12 50
EOF

result=$(jq -s --arg projectId "$ZEROPS_PROJECT_ID" \
  '{projectId:$projectId,verified:true,nodes:sort_by(.hostname)}' "$evidence")
if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$result" > "$output"
else
  printf '%s\n' "$result"
fi
log 'verified six single-instance Zerops nodes use dedicated 4-vCPU mode and fixed RAM/disk sizes'
