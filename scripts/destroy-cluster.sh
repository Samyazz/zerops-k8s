#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
load_zerops_env
require_env K8S_AGENT_TOKEN

failed=0
pids=()
# shellcheck disable=SC2153 # NODES is declared by scripts/lib.sh.
nodes=("${NODES[@]}")
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
for node in "${optional_workers[@]}"; do
  if service_exists "$node"; then nodes+=("$node"); fi
done
for node in "${nodes[@]}"; do
  (
    wait_for_agent "$node"
    agent_request "$node" POST /v1/cluster/reset >/dev/null
  ) & pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done

if (( failed )); then
  set_cluster_state cleanup-failed "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}" || true
  die 'one or more nested nodes failed to reset; later deployments must remain blocked'
fi

set_cluster_state destroyed "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
log 'repository-managed nested Kubernetes cluster destroyed'
