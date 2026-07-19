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
current_node=
current_cordoned=false
cleanup() {
  if [[ "$current_cordoned" == true && -n "$current_node" ]]; then
    kubectl uncordon "$current_node" >/dev/null 2>&1 || true
  fi
  rm -f "$response" "$payload_file" "$api_response"
  [[ -z "${node_contract:-}" ]] || rm -f "$node_contract"
}
trap cleanup EXIT INT TERM

api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"

cp_cpu=$(cluster_tag_value cp-cpu); cp_cpu=${cp_cpu:-4}
cp_ram=$(cluster_tag_value cp-ram); cp_ram=${cp_ram:-8}
cp_disk=$(cluster_tag_value cp-disk); cp_disk=${cp_disk:-20}
worker_cpu=$(cluster_tag_value worker-cpu); worker_cpu=${worker_cpu:-4}
worker_ram=$(cluster_tag_value worker-ram); worker_ram=${worker_ram:-12}
worker_disk=$(cluster_tag_value worker-disk); worker_disk=${worker_disk:-50}

node_contract=$(mktemp)
printf '%s %s %s %s\n' \
  k8sworker1 "$worker_cpu" "$worker_ram" "$worker_disk" \
  k8sworker2 "$worker_cpu" "$worker_ram" "$worker_disk" \
  k8sworker3 "$worker_cpu" "$worker_ram" "$worker_disk" \
  k8scp2 "$cp_cpu" "$cp_ram" "$cp_disk" \
  k8scp3 "$cp_cpu" "$cp_ram" "$cp_disk" \
  k8scp1 "$cp_cpu" "$cp_ram" "$cp_disk" >"$node_contract"
if jq -e '.list | any(.name == "k8sworker4")' "$response" >/dev/null; then
  sed -i "1i k8sworker4 $worker_cpu $worker_ram $worker_disk" "$node_contract"
fi

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
  if [[ -n "${KUBECONFIG:-}" && -s "$KUBECONFIG" ]] && kubectl get "node/$hostname" >/dev/null 2>&1; then
    current_node=$hostname
    wait_longhorn_healthy
    kubectl cordon "$hostname" >/dev/null
    current_cordoned=true
    safe_drain "$hostname"
  fi
  api_request_file PUT "/service-stack/${service_id}/autoscaling" "$(<"$payload_file")" "$api_response"
  process_id=$(jq -r '.process.id // empty' "$api_response")
  [[ -z "$process_id" ]] || wait_public_process "$process_id"

  if [[ -n "${KUBECONFIG:-}" && -s "$KUBECONFIG" ]]; then
    wait_for_agent "$hostname"
    agent_request "$hostname" POST /v1/node/start >/dev/null
    kubectl wait "node/$hostname" --for=condition=Ready --timeout=15m
    recover_terminating_node_pods "$hostname"
    if [[ "$current_cordoned" == true ]]; then
      kubectl uncordon "$hostname" >/dev/null
      current_cordoned=false
      wait_longhorn_healthy
    fi
  fi

  # Refresh after every potentially restarting Docker service so subsequent
  # decisions use the authoritative post-operation state.
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"
done <"$node_contract"

"$ROOT_DIR/scripts/verify-node-resources.sh" >/dev/null
