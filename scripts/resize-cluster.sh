#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/node-agent-artifact.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID KUBECONFIG
require curl
require jq
require kubectl
require zcli

cp_mode=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.cpuMode' "$PROFILE_FILE")
cp_min_cpu=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")
cp_min_ram=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")
cp_min_disk=$(jq -er --arg node "${CONTROL_PLANES[0]}" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")
worker_mode=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpuMode' "$PROFILE_FILE")
worker_min_cpu=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.cpu' "$PROFILE_FILE")
worker_min_ram=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.ramGb' "$PROFILE_FILE")
worker_min_disk=$(jq -er --arg node "${WORKERS[0]}" '.services[] | select(.hostname == $node) | .resources.diskGb' "$PROFILE_FILE")
cp_cpu=${CONTROL_PLANE_CPU:-$cp_min_cpu}
cp_ram=${CONTROL_PLANE_RAM_GB:-$cp_min_ram}
cp_disk=${CONTROL_PLANE_DISK_GB:-$cp_min_disk}
worker_cpu=${WORKER_CPU:-$worker_min_cpu}
worker_ram=${WORKER_RAM_GB:-$worker_min_ram}
worker_disk=${WORKER_DISK_GB:-$worker_min_disk}
baseline_workers=${#WORKERS[@]}
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
max_workers=$((baseline_workers + ${#optional_workers[@]}))
desired_workers=${DESIRED_WORKERS:-$baseline_workers}

validate_integer() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
  (( value >= minimum && value <= maximum )) || die "$name must be between $minimum and $maximum"
}
validate_integer CONTROL_PLANE_CPU "$cp_cpu" "$cp_min_cpu" 32
validate_integer CONTROL_PLANE_RAM_GB "$cp_ram" "$cp_min_ram" 128
validate_integer CONTROL_PLANE_DISK_GB "$cp_disk" "$cp_min_disk" 500
validate_integer WORKER_CPU "$worker_cpu" "$worker_min_cpu" 32
validate_integer WORKER_RAM_GB "$worker_ram" "$worker_min_ram" 128
validate_integer WORKER_DISK_GB "$worker_disk" "$worker_min_disk" 1000
validate_integer DESIRED_WORKERS "$desired_workers" "$baseline_workers" "$max_workers"
if (( desired_workers != baseline_workers )); then
  profile_capability horizontalResize \
    || die "horizontal resize is not supported by Kubernetes profile '$K8S_PROFILE'"
fi

wait_cluster_api() {
  local context=${1:-operation} deadline=$((SECONDS + 600))
  until kubectl --request-timeout=10s get --raw=/readyz >/dev/null 2>&1; do
    (( SECONDS < deadline )) \
      || die "Kubernetes API did not recover after $context"
    sleep 3
  done
}

# Zerops CPU/RAM changes restart the existing runtime and must retain its
# filesystem. Record the repository profile's permanent Kubernetes identities
# so a resize can never silently replace the cluster while still ending Ready.
required_node_names=$(printf '%s\n' "${NODES[@]}" | jq -Rsc 'split("\n")[:-1]')
identity_before=$(kubectl get namespace kube-system -o json | jq -c \
  --argjson nodes "$(kubectl get nodes -o json)" \
  --argjson required "$required_node_names" '
    {clusterUid:.metadata.uid,
     nodes:($nodes.items
       | map(select(.metadata.name as $name | $required | index($name)))
       | map({name:.metadata.name,uid:.metadata.uid})
       | sort_by(.name))}')
[[ $(jq '.nodes | length' <<<"$identity_before") -eq ${#NODES[@]} ]] \
  || die 'one or more permanent profile nodes are absent before resize'

current_node=
current_cordoned=false
partial_optional_worker=false
current_optional_worker=
restore_cordon() {
  local deadline
  if [[ "$current_cordoned" == true && -n "$current_node" ]]; then
    if [[ "$current_node" == k8scp* ]]; then
      deadline=$((SECONDS + 300))
      until kubectl get --raw=/readyz >/dev/null 2>&1; do
        (( SECONDS >= deadline )) && break
        sleep 3
      done
    fi
    kubectl uncordon "$current_node" >/dev/null 2>&1 || true
  fi
  if [[ "$partial_optional_worker" == true && -n "$current_optional_worker" ]]; then
    log "removing a partially provisioned optional worker after resize failure or cancellation: $current_optional_worker"
    zcli service delete "$current_optional_worker" -P "$ZEROPS_PROJECT_ID" --confirm >/dev/null 2>&1 || true
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
  local node=$1 cpu_mode=$2 cpu=$3 ram=$4 disk=$5 service_id current_disk process_id deadline
  service_id=$(jq -er --arg node "$node" '.list[] | select(.name == $node) | .id' "$service_inventory")
  current_disk=$(jq -er --arg node "$node" '
    .list[] | select(.name == $node)
    | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling).minResource.diskGBytes
  ' "$service_inventory")
  jq -en --argjson requested "$disk" --argjson current "$current_disk" '$requested >= $current' >/dev/null \
    || die "disk downsizing is not supported by Zerops: $node currently has ${current_disk}GB"

  if jq -e --arg node "$node" --arg cpu_mode "$cpu_mode" --argjson cpu "$cpu" --argjson ram "$ram" --argjson disk "$disk" '
    .list[] | select(.name == $node)
    | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling) as $v
    | $v.cpuMode == $cpu_mode
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

  jq -cn --arg cpu_mode "$cpu_mode" --argjson cpu "$cpu" --argjson ram "$ram" --argjson disk "$disk" '{
    customAutoscaling:{
      verticalAutoscaling:{
        cpuMode:$cpu_mode,
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
  if [[ "$node" == k8scp* ]]; then
    wait_cluster_api "$node Zerops resize restart"
  fi
  kubectl wait "node/$node" --for=condition=Ready --timeout=15m
  recover_terminating_node_pods "$node"
  kubectl uncordon "$node" >/dev/null
  current_cordoned=false
  wait_longhorn_healthy
  refresh_inventory
}

add_optional_worker() {
  local node=$1 import_file init_response ca_hash deadline setup
  log "horizontally scaling from $baseline_workers workers to $max_workers"
  prepare_node_agent_artifact
  import_file=$(mktemp)
  sed -n '1,1p' "$ROOT_DIR/import.yaml" >"$import_file"
  {
    printf 'services:\n'
    printf '  - hostname: %s\n' "$node"
    printf '    type: docker@26.1.5\n'
    printf '    minContainers: 1\n'
    printf '    maxContainers: 1\n'
    printf '    verticalAutoscaling:\n'
    printf '      cpuMode: %s\n' "$worker_mode"
    printf '      minCpu: %s\n' "$worker_cpu"
    printf '      maxCpu: %s\n' "$worker_cpu"
    printf '      startCpuCoreCount: %s\n' "$worker_cpu"
    printf '      minRam: %s\n' "$worker_ram"
    printf '      maxRam: %s\n' "$worker_ram"
    printf '      minDisk: %s\n' "$worker_disk"
    printf '      maxDisk: %s\n' "$worker_disk"
    printf '      swapEnabled: false\n'
  } >>"$import_file"
  partial_optional_worker=true
  current_optional_worker=$node
  zcli project service-import "$import_file" -P "$ZEROPS_PROJECT_ID"
  rm -f "$import_file"

  setup="worker${node#k8sworker}"
  [[ "$K8S_PROFILE" == full ]] || setup="${setup}-${K8S_PROFILE}"
  zcli service deploy "$node" -P "$ZEROPS_PROJECT_ID" --setup "$setup" \
    --version-name "${NODE_AGENT_VERSION_NAME}-${node}" \
    --working-dir "$NODE_AGENT_ARTIFACT_DIR" --path-to-file-or-dir .
  wait_for_agent "$node"
  agent_request "$node" POST /v1/node/start >/dev/null
  init_response=$(agent_request k8scp1 POST /v1/cluster/init)
  ca_hash=$(jq -er .caHash <<<"$init_response")
  agent_request "$node" POST /v1/cluster/join "$(jq -cn --arg hash "$ca_hash" '{caHash:$hash}')" >/dev/null
  deadline=$((SECONDS + 300))
  until kubectl get "node/$node" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "$node did not register after joining the cluster"
    sleep 3
  done
  kubectl label node "$node" node-role.kubernetes.io/worker='' --overwrite
  [[ $(profile_json '.addons.storage') != longhorn ]] \
    || kubectl label node "$node" node.longhorn.io/create-default-disk=true --overwrite
  kubectl wait "node/$node" --for=condition=Ready --timeout=15m
  kubectl -n calico-system wait pod -l k8s-app=calico-node \
    --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
  if [[ $(profile_json '.addons.serviceMesh') == true ]]; then
    kubectl -n istio-system wait pod -l k8s-app=istio-cni-node \
      --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
    kubectl -n istio-system wait pod -l app=ztunnel \
      --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
  fi
  if profile_capability storageHealth; then
    kubectl -n longhorn-system wait pod -l app=longhorn-manager \
      --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
    wait_longhorn_disk_ready "$node"
    wait_longhorn_healthy
  fi
  partial_optional_worker=false
  current_optional_worker=
  refresh_inventory
}

remove_optional_worker() {
  local node=$1 deadline replicas
  log "horizontally scaling from $max_workers workers to the $baseline_workers-worker profile floor"
  profile_capability storageHealth && wait_longhorn_healthy
  if profile_capability storageHealth && kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1; then
    kubectl -n longhorn-system patch "nodes.longhorn.io/$node" --type=merge \
      -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null
    deadline=$((SECONDS + 1800))
    while (( SECONDS < deadline )); do
      replicas=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq \
        --arg node "$node" '[.items[] | select(.spec.nodeID == $node)] | length')
      [[ "$replicas" -eq 0 ]] && break
      sleep 10
    done
    [[ ${replicas:-0} -eq 0 ]] || die "Longhorn replica eviction from $node timed out"
  fi
  current_node=$node
  kubectl cordon "$node" >/dev/null
  current_cordoned=true
  safe_drain "$node"
  agent_request "$node" POST /v1/cluster/reset >/dev/null
  kubectl delete "node/$node" --ignore-not-found >/dev/null
  profile_capability storageHealth \
    && kubectl -n longhorn-system delete "nodes.longhorn.io/$node" --ignore-not-found >/dev/null
  zcli service delete "$node" -P "$ZEROPS_PROJECT_ID" --confirm
  current_cordoned=false
  current_node=
  refresh_inventory
  profile_capability storageHealth && wait_longhorn_healthy
}

if profile_capability backup; then
  log 'taking mandatory pre-resize backups'
  "$ROOT_DIR/scripts/backup-cluster.sh"
fi

optional_worker=${optional_workers[0]:-}
if (( desired_workers > baseline_workers )) && [[ -n "$optional_worker" ]] && ! service_present "$optional_worker"; then
  add_optional_worker "$optional_worker"
fi

for node in "${WORKERS[@]}"; do
  scale_node "$node" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk"
done
if [[ -n "$optional_worker" ]] && service_present "$optional_worker"; then
  scale_node "$optional_worker" "$worker_mode" "$worker_cpu" "$worker_ram" "$worker_disk"
fi
for node in "${CONTROL_PLANES[@]}"; do
  scale_node "$node" "$cp_mode" "$cp_cpu" "$cp_ram" "$cp_disk"
done

if (( desired_workers == baseline_workers )) && [[ -n "$optional_worker" ]] && service_present "$optional_worker"; then
  remove_optional_worker "$optional_worker"
fi

set_cluster_tag workers "$desired_workers"
set_cluster_tag cp-cpu "$cp_cpu"
set_cluster_tag cp-ram "$cp_ram"
set_cluster_tag cp-disk "$cp_disk"
set_cluster_tag worker-cpu "$worker_cpu"
set_cluster_tag worker-ram "$worker_ram"
set_cluster_tag worker-disk "$worker_disk"

# The Zerops VPN resolver can briefly lag the recovered control plane even
# after the first successful readyz probe. Treat that as recovery time, not as
# a failed resize, before running the final identity and resource assertions.
wait_cluster_api 'the completed resize and Zerops setting updates'
kubectl wait --for=condition=Ready nodes --all --timeout=10m
[[ $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l) -eq ${#CONTROL_PLANES[@]} ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/worker -o name | wc -l) -eq "$desired_workers" ]]
identity_after=$(kubectl get namespace kube-system -o json | jq -c \
  --argjson nodes "$(kubectl get nodes -o json)" \
  --argjson required "$required_node_names" '
    {clusterUid:.metadata.uid,
     nodes:($nodes.items
       | map(select(.metadata.name as $name | $required | index($name)))
       | map({name:.metadata.name,uid:.metadata.uid})
       | sort_by(.name))}')
jq -en --argjson before "$identity_before" --argjson after "$identity_after" \
  '$before == $after' >/dev/null \
  || die 'resize changed the Kubernetes cluster or permanent node identities'
mkdir -p "${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize"
jq -n --argjson before "$identity_before" --argjson after "$identity_after" \
  '{preserved:($before == $after),before:$before,after:$after}' \
  >"${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize/identity.json"
"$ROOT_DIR/scripts/verify-node-resources.sh" "${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize/resources.json"
kubectl get nodes -o wide >"${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/resize/nodes.txt"
log 'vertical and horizontal resize completed with all nodes Ready and permanent identities preserved'
