#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID KUBECONFIG
require curl
require jq
require kubectl
require zcli

cp_cpu=${CONTROL_PLANE_CPU:-4}
cp_ram=${CONTROL_PLANE_RAM_GB:-8}
cp_disk=${CONTROL_PLANE_DISK_GB:-20}
worker_cpu=${WORKER_CPU:-4}
worker_ram=${WORKER_RAM_GB:-12}
worker_disk=${WORKER_DISK_GB:-50}
desired_workers=${DESIRED_WORKERS:-3}

validate_integer() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
  (( value >= minimum && value <= maximum )) || die "$name must be between $minimum and $maximum"
}
validate_integer CONTROL_PLANE_CPU "$cp_cpu" 4 32
validate_integer CONTROL_PLANE_RAM_GB "$cp_ram" 8 128
validate_integer CONTROL_PLANE_DISK_GB "$cp_disk" 20 500
validate_integer WORKER_CPU "$worker_cpu" 4 32
validate_integer WORKER_RAM_GB "$worker_ram" 12 128
validate_integer WORKER_DISK_GB "$worker_disk" 50 1000
[[ "$desired_workers" == 3 || "$desired_workers" == 4 ]] \
  || die 'DESIRED_WORKERS must be 3 or 4; three is the HA and Longhorn replica floor'

current_node=
current_cordoned=false
restore_cordon() {
  if [[ "$current_cordoned" == true && -n "$current_node" ]]; then
    kubectl uncordon "$current_node" >/dev/null 2>&1 || true
  fi
}
trap restore_cordon EXIT INT TERM

service_inventory=$(mktemp)
payload_file=$(mktemp)
api_response=$(mktemp)
trap 'restore_cordon; rm -f "$service_inventory" "$payload_file" "$api_response"' EXIT INT TERM
api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$service_inventory"

service_present() {
  jq -e --arg name "$1" '.list | any(.name == $name)' "$service_inventory" >/dev/null
}

refresh_inventory() {
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$service_inventory"
}

scale_node() {
  local node=$1 cpu=$2 ram=$3 disk=$4 service_id current_disk process_id
  service_id=$(jq -er --arg node "$node" '.list[] | select(.name == $node) | .id' "$service_inventory")
  current_disk=$(jq -er --arg node "$node" '
    .list[] | select(.name == $node)
    | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling).minResource.diskGBytes
  ' "$service_inventory")
  jq -en --argjson requested "$disk" --argjson current "$current_disk" '$requested >= $current' >/dev/null \
    || die "disk downsizing is not supported by Zerops: $node currently has ${current_disk}GB"

  if jq -e --arg node "$node" --argjson cpu "$cpu" --argjson ram "$ram" --argjson disk "$disk" '
    .list[] | select(.name == $node)
    | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling) as $v
    | $v.cpuMode == "DEDICATED"
      and $v.minResource.cpuCoreCount == $cpu and $v.maxResource.cpuCoreCount == $cpu
      and $v.startCpuCoreCount == $cpu
      and $v.minResource.memoryGBytes == $ram and $v.maxResource.memoryGBytes == $ram
      and $v.minResource.diskGBytes == $disk and $v.maxResource.diskGBytes == $disk
  ' "$service_inventory" >/dev/null; then
    log "resources already match for $node"
    return 0
  fi

  current_node=$node
  wait_longhorn_healthy
  kubectl cordon "$node" >/dev/null
  current_cordoned=true
  safe_drain "$node"

  jq -cn --argjson cpu "$cpu" --argjson ram "$ram" --argjson disk "$disk" '{
    customAutoscaling:{
      verticalAutoscaling:{
        cpuMode:"DEDICATED",
        minResource:{cpuCoreCount:$cpu,memoryGBytes:$ram,diskGBytes:$disk},
        maxResource:{cpuCoreCount:$cpu,memoryGBytes:$ram,diskGBytes:$disk},
        startCpuCoreCount:$cpu,
        swapEnabled:false
      },
      horizontalAutoscaling:{minContainerCount:1,maxContainerCount:1}
    }
  }' >"$payload_file"
  log "resizing $node to ${cpu} CPU, ${ram}GB RAM, ${disk}GB disk"
  api_request_file PUT "/service-stack/${service_id}/autoscaling" "$(<"$payload_file")" "$api_response"
  process_id=$(jq -r '.process.id // empty' "$api_response")
  [[ -z "$process_id" ]] || wait_public_process "$process_id"
  wait_for_agent "$node"
  agent_request "$node" POST /v1/node/start >/dev/null
  kubectl wait "node/$node" --for=condition=Ready --timeout=15m
  recover_terminating_node_pods "$node"
  kubectl uncordon "$node" >/dev/null
  current_cordoned=false
  wait_longhorn_healthy
  refresh_inventory
}

add_fourth_worker() {
  local import_file version_name init_response ca_hash
  log 'horizontally scaling from three workers to four'
  import_file=$(mktemp)
  sed -n '1,1p' "$ROOT_DIR/import.yaml" >"$import_file"
  {
    printf 'services:\n'
    printf '  - hostname: k8sworker4\n'
    printf '    type: docker@26.1.5\n'
    printf '    startWithoutCode: true\n'
    printf '    minContainers: 1\n'
    printf '    maxContainers: 1\n'
    printf '    verticalAutoscaling:\n'
    printf '      cpuMode: DEDICATED\n'
    printf '      minCpu: %s\n' "$worker_cpu"
    printf '      maxCpu: %s\n' "$worker_cpu"
    printf '      startCpuCoreCount: %s\n' "$worker_cpu"
    printf '      minRam: %s\n' "$worker_ram"
    printf '      maxRam: %s\n' "$worker_ram"
    printf '      minDisk: %s\n' "$worker_disk"
    printf '      maxDisk: %s\n' "$worker_disk"
    printf '      swapEnabled: false\n'
  } >>"$import_file"
  zcli project service-import "$import_file" -P "$ZEROPS_PROJECT_ID"
  rm -f "$import_file"

  version_name="github-${GITHUB_RUN_ID:-local}-${GITHUB_SHA:-working}-worker4"
  zcli push k8sworker4 -P "$ZEROPS_PROJECT_ID" --setup worker4 \
    --version-name "$version_name" --working-dir "$ROOT_DIR" --workspace-state all
  wait_for_agent k8sworker4
  agent_request k8sworker4 POST /v1/node/start >/dev/null
  init_response=$(agent_request k8scp1 POST /v1/cluster/init)
  ca_hash=$(jq -er .caHash <<<"$init_response")
  agent_request k8sworker4 POST /v1/cluster/join "$(jq -cn --arg hash "$ca_hash" '{caHash:$hash}')" >/dev/null
  kubectl label node k8sworker4 node-role.kubernetes.io/worker='' node.longhorn.io/create-default-disk=true --overwrite
  kubectl wait node/k8sworker4 --for=condition=Ready --timeout=15m
  kubectl -n calico-system wait pod -l k8s-app=calico-node \
    --field-selector spec.nodeName=k8sworker4 --for=condition=Ready --timeout=10m
  kubectl -n istio-system wait pod -l k8s-app=istio-cni-node \
    --field-selector spec.nodeName=k8sworker4 --for=condition=Ready --timeout=10m
  kubectl -n istio-system wait pod -l app=ztunnel \
    --field-selector spec.nodeName=k8sworker4 --for=condition=Ready --timeout=10m
  kubectl -n longhorn-system wait pod -l app=longhorn-manager \
    --field-selector spec.nodeName=k8sworker4 --for=condition=Ready --timeout=10m
  wait_longhorn_healthy
  refresh_inventory
}

remove_fourth_worker() {
  local deadline replicas
  log 'horizontally scaling from four workers to the three-worker HA floor'
  wait_longhorn_healthy
  if kubectl -n longhorn-system get nodes.longhorn.io k8sworker4 >/dev/null 2>&1; then
    kubectl -n longhorn-system patch nodes.longhorn.io k8sworker4 --type=merge \
      -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null
    deadline=$((SECONDS + 1800))
    while (( SECONDS < deadline )); do
      replicas=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq \
        '[.items[] | select(.spec.nodeID == "k8sworker4")] | length')
      [[ "$replicas" -eq 0 ]] && break
      sleep 10
    done
    [[ ${replicas:-0} -eq 0 ]] || die 'Longhorn replica eviction from k8sworker4 timed out'
  fi
  current_node=k8sworker4
  kubectl cordon k8sworker4 >/dev/null
  current_cordoned=true
  safe_drain k8sworker4
  agent_request k8sworker4 POST /v1/cluster/reset >/dev/null
  kubectl delete node k8sworker4 --ignore-not-found >/dev/null
  kubectl -n longhorn-system delete nodes.longhorn.io k8sworker4 --ignore-not-found >/dev/null
  zcli service delete k8sworker4 -P "$ZEROPS_PROJECT_ID" --confirm
  current_cordoned=false
  current_node=
  refresh_inventory
  wait_longhorn_healthy
}

log 'taking mandatory pre-resize backups'
"$ROOT_DIR/scripts/backup-cluster.sh"

if [[ "$desired_workers" == 4 ]] && ! service_present k8sworker4; then
  add_fourth_worker
fi

for node in k8sworker1 k8sworker2 k8sworker3; do
  scale_node "$node" "$worker_cpu" "$worker_ram" "$worker_disk"
done
if service_present k8sworker4; then
  scale_node k8sworker4 "$worker_cpu" "$worker_ram" "$worker_disk"
fi
for node in k8scp2 k8scp3 k8scp1; do
  scale_node "$node" "$cp_cpu" "$cp_ram" "$cp_disk"
done

if [[ "$desired_workers" == 3 ]] && service_present k8sworker4; then
  remove_fourth_worker
fi

set_cluster_tag workers "$desired_workers"
set_cluster_tag cp-cpu "$cp_cpu"
set_cluster_tag cp-ram "$cp_ram"
set_cluster_tag cp-disk "$cp_disk"
set_cluster_tag worker-cpu "$worker_cpu"
set_cluster_tag worker-ram "$worker_ram"
set_cluster_tag worker-disk "$worker_disk"

kubectl wait --for=condition=Ready nodes --all --timeout=10m
[[ $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l) -eq 3 ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/worker -o name | wc -l) -eq "$desired_workers" ]]
"$ROOT_DIR/scripts/verify-node-resources.sh" "${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize/resources.json"
kubectl get nodes -o wide >"${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize/nodes.txt"
log 'vertical and horizontal resize completed with all nodes Ready'
