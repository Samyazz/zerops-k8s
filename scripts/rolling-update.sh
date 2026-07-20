#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID KUBECONFIG
load_zerops_env
require_env K8S_AGENT_TOKEN

expected="v${KUBERNETES_VERSION}"
mapfile -t unexpected_versions < <(
  kubectl get nodes -o json | jq -r --arg expected "$expected" \
    '.items[] | select(.status.nodeInfo.kubeletVersion != $expected) | [.metadata.name,.status.nodeInfo.kubeletVersion] | @tsv'
)
if (( ${#unexpected_versions[@]} > 0 )); then
  printf 'Node versions differ from versions.env; use a reviewed kubeadm version-upgrade change first:\n%s\n' \
    "${unexpected_versions[*]}" >&2
  exit 1
fi

log 'taking mandatory pre-update etcd and Longhorn backups'
"$ROOT_DIR/scripts/backup-cluster.sh"
set_cluster_state updating "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"

log 'rolling the nested Kubernetes node restart one node at a time'
PUSH_AGENT_CODE=true "$ROOT_DIR/scripts/redeploy-node-agents.sh"

log 'reconciling pinned Kubernetes add-ons after the node rollout'
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
wait_longhorn_healthy

export SKIP_DISRUPTION_TESTS=true
export RUN_FULL_CONFORMANCE=false
"$ROOT_DIR/scripts/acceptance.sh"
set_cluster_state running "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
log 'rolling update completed with backups, readiness, storage health, and acceptance evidence'
