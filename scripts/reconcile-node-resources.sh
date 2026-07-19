#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require curl
require jq

response=$(mktemp)
payload_file=$(mktemp)
api_response=$(mktemp)
trap 'rm -f "$response" "$payload_file" "$api_response"' EXIT

api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"

while read -r hostname cpu ram disk; do
  service_id=$(jq -er --arg hostname "$hostname" '.list[] | select(.name == $hostname) | .id' "$response") \
    || die "required Zerops node service is missing: $hostname"

  if jq -e \
    --arg hostname "$hostname" \
    --argjson cpu "$cpu" \
    --argjson ram "$ram" \
    --argjson disk "$disk" '
      .list[]
      | select(.name == $hostname)
      | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling) as $v
      | (.currentAutoscaling.horizontalAutoscaling // .customAutoscaling.horizontalAutoscaling) as $h
      | $v.cpuMode == "DEDICATED"
        and $v.minResource.cpuCoreCount == $cpu
        and $v.maxResource.cpuCoreCount == $cpu
        and $v.startCpuCoreCount == $cpu
        and $v.minResource.memoryGBytes == $ram
        and $v.maxResource.memoryGBytes == $ram
        and $v.minResource.diskGBytes == $disk
        and $v.maxResource.diskGBytes == $disk
        and $h.minContainerCount == 1
        and $h.maxContainerCount == 1
    ' "$response" >/dev/null; then
    log "Zerops node resources already match: $hostname"
    continue
  fi

  jq -cn \
    --argjson cpu "$cpu" \
    --argjson ram "$ram" \
    --argjson disk "$disk" '{
      customAutoscaling: {
        verticalAutoscaling: {
          cpuMode: "DEDICATED",
          minResource: {
            cpuCoreCount: $cpu,
            memoryGBytes: $ram,
            diskGBytes: $disk
          },
          maxResource: {
            cpuCoreCount: $cpu,
            memoryGBytes: $ram,
            diskGBytes: $disk
          },
          startCpuCoreCount: $cpu,
          swapEnabled: false
        },
        horizontalAutoscaling: {
          minContainerCount: 1,
          maxContainerCount: 1
        }
      }
    }' > "$payload_file"

  log "reconciling dedicated fixed resources for $hostname"
  api_request_file PUT "/service-stack/${service_id}/autoscaling" "$(<"$payload_file")" "$api_response"
  process_id=$(jq -r '.process.id // empty' "$api_response")
  [[ -z "$process_id" ]] || wait_public_process "$process_id"

  if [[ -n "${KUBECONFIG:-}" && -s "$KUBECONFIG" ]]; then
    wait_for_agent "$hostname"
    agent_request "$hostname" POST /v1/node/start >/dev/null
    kubectl wait "node/$hostname" --for=condition=Ready --timeout=15m
  fi

  # Refresh after every potentially restarting Docker service so subsequent
  # decisions use the authoritative post-operation state.
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"
done <<'EOF'
k8sworker1 4 12 50
k8sworker2 4 12 50
k8sworker3 4 12 50
k8scp2 4 8 20
k8scp3 4 8 20
k8scp1 4 8 20
EOF

"$ROOT_DIR/scripts/verify-node-resources.sh" >/dev/null
