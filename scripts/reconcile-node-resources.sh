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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

node_contract=$(mktemp)
for node in "${WORKERS[@]}"; do
  printf '%s %s %s %s %s\n' "$node" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk" >>"$node_contract"
done
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
for node in "${optional_workers[@]}"; do
  if jq -e --arg name "$node" '.list | any(.name == $name)' "$response" >/dev/null; then
    printf '%s %s %s %s %s\n' "$node" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk" >>"$node_contract"
  fi
done
for ((index=${#CONTROL_PLANES[@]}-1; index>=0; index--)); do
  printf '%s %s %s %s %s\n' "${CONTROL_PLANES[index]}" "$cp_mode" "$cp_cpu" "$cp_ram" "$cp_disk" >>"$node_contract"
done

while read -r hostname cpu_mode cpu ram disk; do
  service_id=$(jq -er --arg hostname "$hostname" '.list[] | select(.name == $hostname) | .id' "$response") \
    || die "required Zerops node service is missing: $hostname"

  if jq -e \
    --arg hostname "$hostname" \
    --arg cpu_mode "$cpu_mode" \
    --argjson cpu "$cpu" \
    --argjson ram "$ram" \
    --argjson disk "$disk" '
      .list[]
      | select(.name == $hostname)
      | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling) as $v
      | (.currentAutoscaling.horizontalAutoscaling // .customAutoscaling.horizontalAutoscaling) as $h
      | $v.cpuMode == $cpu_mode
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
    --argjson disk "$disk" \
    --arg cpu_mode "$cpu_mode" '{
      customAutoscaling: {
        verticalAutoscaling: {
          cpuMode: $cpu_mode,
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
