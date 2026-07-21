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
identity_before=$(kubectl get namespace kube-system -o json | jq -c \
  --argjson nodes "$(kubectl get nodes -o json)" \
  '{clusterUid:.metadata.uid,nodes:($nodes.items | map({name:.metadata.name,uid:.metadata.uid}) | sort_by(.name))}')
mapfile -t unexpected_versions < <(
  kubectl get nodes -o json | jq -r --arg expected "$expected" \
    '.items[] | select(.status.nodeInfo.kubeletVersion != $expected) | [.metadata.name,.status.nodeInfo.kubeletVersion] | @tsv'
)
if (( ${#unexpected_versions[@]} > 0 )); then
  printf 'Node versions differ from versions.env; use a reviewed kubeadm version-upgrade change first:\n%s\n' \
    "${unexpected_versions[*]}" >&2
  exit 1
fi

if profile_capability backup; then
  log 'taking mandatory pre-update etcd and Longhorn backups'
  "$ROOT_DIR/scripts/backup-cluster.sh"
else
  log "profile $K8S_PROFILE has no durable backup capability; maintenance will exercise stop/start recovery only"
fi
set_cluster_state updating "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"

log 'rolling the nested Kubernetes node restart one node at a time'
# A Zerops runtime deployment creates a new outer container and replaces its
# filesystem. The kubeadm/etcd/Longhorn state belongs to the nested node on
# that filesystem, so maintenance must restart the nested container through
# the already-deployed agent rather than redeploying the outer runtime.
PUSH_AGENT_CODE=false "$ROOT_DIR/scripts/redeploy-node-agents.sh"

log 'reconciling pinned Kubernetes add-ons after the node rollout'
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
wait_longhorn_healthy

export SKIP_DISRUPTION_TESTS=true
export RUN_FULL_CONFORMANCE=false
"$ROOT_DIR/scripts/acceptance.sh"
identity_after=$(kubectl get namespace kube-system -o json | jq -c \
  --argjson nodes "$(kubectl get nodes -o json)" \
  '{clusterUid:.metadata.uid,nodes:($nodes.items | map({name:.metadata.name,uid:.metadata.uid}) | sort_by(.name))}')
jq -en --argjson before "$identity_before" --argjson after "$identity_after" \
  '$before == $after' >/dev/null \
  || die 'rolling maintenance changed the Kubernetes cluster or node identities'
mkdir -p "${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/maintenance"
jq -n --argjson before "$identity_before" --argjson after "$identity_after" \
  '{preserved:($before == $after),before:$before,after:$after}' \
  >"${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/maintenance/identity.json"
set_cluster_state running "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
log 'rolling update completed with cluster identity, readiness, storage health, and acceptance evidence preserved'
