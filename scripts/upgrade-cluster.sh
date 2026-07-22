#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID KUBECONFIG UPGRADE_CONFIRM_TARGET
require curl
require jq
require kubectl
require python3
require zcli

target_version=$KUBERNETES_VERSION
target="v${target_version}"
package_version=$KUBERNETES_PACKAGE_VERSION
plan_only=${UPGRADE_PLAN_ONLY:-true}
run_full_conformance=${RUN_FULL_CONFORMANCE:-true}
[[ "$plan_only" == true || "$plan_only" == false ]] || die 'UPGRADE_PLAN_ONLY must be true or false'
[[ "$run_full_conformance" == true || "$run_full_conformance" == false ]] \
  || die 'RUN_FULL_CONFORMANCE must be true or false'
[[ "$UPGRADE_CONFIRM_TARGET" == "$target" ]] \
  || die "confirmation must exactly match the reviewed repository target $target"
[[ "$package_version" == "${target_version}-"* ]] \
  || die 'KUBERNETES_PACKAGE_VERSION does not match KUBERNETES_VERSION'
if [[ "$NODE_IMAGE_MODE" == local && "$plan_only" != true ]]; then
  die "applied version upgrades are not supported by Kubernetes profile '$K8S_PROFILE'; run the reviewed plan-only path"
fi

load_zerops_env
require_env K8S_AGENT_TOKEN K8S_RECOVERY_AGE_RECIPIENT
export ALLOW_UPGRADE_RECOVERY=true
assert_repository_cluster

target_minor=${target_version%.*}
jq -e \
  --arg minor "$target_minor" \
  --arg calico "$CALICO_VERSION" \
  --arg istio "$ISTIO_VERSION" \
  --arg longhorn "$LONGHORN_VERSION" \
  --arg gateway "$GATEWAY_API_VERSION" '
    .schemaVersion == 1
    and .approvedTargets[$minor].calico == $calico
    and .approvedTargets[$minor].istio == $istio
    and .approvedTargets[$minor].longhorn == $longhorn
    and .approvedTargets[$minor].gatewayApi == $gateway
  ' "$ROOT_DIR/upgrade-policy.json" >/dev/null \
  || die "upgrade-policy.json does not approve the pinned add-on set for Kubernetes $target_minor"

evidence_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/upgrade
mkdir -p "$evidence_dir"
current_node=
current_cordoned=false
upgrade_started=false
finish() {
  status=$?
  trap - EXIT INT TERM
  if [[ "$current_cordoned" == true && -n "$current_node" ]]; then
    kubectl uncordon "$current_node" >/dev/null 2>&1 || true
  fi
  if (( status != 0 )) && [[ "$upgrade_started" == true ]]; then
    set +e
    set_cluster_state upgrade-failed "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
    set -e
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expected_workers=$(cluster_tag_value workers)
expected_workers=${expected_workers:-${#WORKERS[@]}}
workers=("${WORKERS[@]}")
mapfile -t optional_workers < <(profile_json '.topology.optionalWorkers[]?')
if (( expected_workers > ${#WORKERS[@]} )); then workers+=("${optional_workers[@]}"); fi
if [[ "$K8S_PROFILE" == production ]]; then
  # Keep the compact-production data plane serving while workers roll, then
  # accept the documented API outage when its single control plane is last.
  upgrade_order=("${workers[@]}" "${CONTROL_PLANES[@]}")
else
  upgrade_order=("${CONTROL_PLANES[@]}" "${workers[@]}")
fi

versions_json=$(kubectl get nodes -o json | jq \
  '[.items[] | {name:.metadata.name,version:.status.nodeInfo.kubeletVersion}] | sort_by(.name)')
python3 - "$target" "$expected_workers" "${#CONTROL_PLANES[@]}" "$versions_json" <<'PY'
import json
import re
import sys

target_text, expected_workers, expected_control_planes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
nodes = json.loads(sys.argv[4])
pattern = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')

def parse(value):
    match = pattern.fullmatch(value)
    if not match:
        raise SystemExit(f'non-canonical Kubernetes version: {value}')
    return tuple(map(int, match.groups()))

target = parse(target_text)
if len(nodes) != expected_workers + expected_control_planes:
    raise SystemExit('live node count does not match the Zerops-side worker contract')
for node in nodes:
    current = parse(node['version'])
    if current[0] != target[0] or current[1] > target[1] or target[1] > current[1] + 1:
        raise SystemExit(f"unsupported upgrade path for {node['name']}: {node['version']} -> {target_text}")
    if current[1] == target[1] and current[2] > target[2]:
        raise SystemExit(f"downgrade refused for {node['name']}: {node['version']} -> {target_text}")
PY
jq -n --arg target "$target" --arg packageVersion "$package_version" \
  --argjson nodes "$versions_json" --slurpfile compatibility "$ROOT_DIR/upgrade-policy.json" \
  '{target:$target,packageVersion:$packageVersion,nodesBefore:$nodes,
    compatibilityApproval:$compatibility[0].approvedTargets[($target | ltrimstr("v") | split(".") | .[0:2] | join("."))]}' \
  >"$evidence_dir/preflight.json"

payload() {
  jq -cn --arg mode "$1" --arg target "$target" --arg package "$package_version" \
    '{mode:$mode,targetVersion:$target,packageVersion:$package}'
}

endpoint_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -X POST -H "Authorization: Bearer $K8S_AGENT_TOKEN" -H 'Content-Type: application/json' \
  --data "$(payload preflight)" http://k8scp1:18080/v1/cluster/upgrade || true)
backup_taken=false
if [[ "$endpoint_status" == 404 ]]; then
  die 'the installed node agent predates the state-preserving upgrade endpoint; perform a reviewed clean profile replacement rather than redeploying a stateful outer runtime'
elif [[ "$endpoint_status" != 200 ]]; then
  die "k8scp1 upgrade preflight endpoint returned HTTP $endpoint_status"
fi

: >"$evidence_dir/agent-preflight.ndjson"
for node in "${upgrade_order[@]}"; do
  agent_request "$node" POST /v1/cluster/upgrade "$(payload preflight)" \
    | jq -c --arg node "$node" '{node:$node,status,currentVersion,targetVersion}' \
    >>"$evidence_dir/agent-preflight.ndjson"
done
jq -s '.' "$evidence_dir/agent-preflight.ndjson" >"$evidence_dir/agent-preflight.json"

remaining=$(kubectl get nodes -o json | jq --arg target "$target" \
  '[.items[] | select(.status.nodeInfo.kubeletVersion != $target)] | length')
if (( remaining == 0 )); then
  log "all nodes already run the reviewed target $target; the controlled upgrade is a verified no-op"
  export SKIP_DISRUPTION_TESTS=true RUN_FULL_CONFORMANCE=false
  "$ROOT_DIR/scripts/acceptance.sh"
  set_cluster_state running "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
  log "verified no-op upgrade cleared any prior upgrade recovery lock"
  exit 0
fi

if profile_capability backup && [[ "$backup_taken" != true ]]; then
  log 'taking the mandatory verified recovery point before the version plan'
  "$ROOT_DIR/scripts/backup-cluster.sh"
fi
if profile_capability restore; then
  log 'proving that the fresh recovery point is restorable before changing Kubernetes'
  "$ROOT_DIR/scripts/restore-drill.sh"
fi
if [[ "$NODE_IMAGE_MODE" == object-storage ]]; then
  log 'building and uploading the exact replacement node image before changing Kubernetes'
  "$ROOT_DIR/scripts/build-node-image.sh"
fi

agent_request k8scp1 POST /v1/cluster/upgrade "$(payload plan)" \
  | jq '{status,currentVersion,targetVersion}' >"$evidence_dir/kubeadm-plan.json"
if [[ "$plan_only" == true ]]; then
  log "kubeadm accepted the reviewed plan for $target; plan-only run leaves the control plane unchanged"
  exit 0
fi

set_cluster_state upgrading "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
upgrade_started=true
: >"$evidence_dir/node-upgrades.ndjson"
for node in "${upgrade_order[@]}"; do
  live_version=$(kubectl get "node/$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
  if [[ "$live_version" == "$target" ]]; then
    jq -cn --arg node "$node" --arg version "$live_version" \
      '{node:$node,status:"already-current",version:$version}' >>"$evidence_dir/node-upgrades.ndjson"
    continue
  fi
  wait_longhorn_healthy
  current_node=$node
  current_cordoned=true
  log "cordoning and draining $node for its controlled Kubernetes upgrade"
  kubectl cordon "$node" >/dev/null
  safe_drain "$node"
  response=$(agent_request "$node" POST /v1/cluster/upgrade "$(payload apply)")
  kubectl wait "node/$node" --for=condition=Ready --timeout=15m
  [[ $(kubectl get "node/$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}') == "$target" ]] \
    || die "$node did not report target kubelet version $target"
  recover_terminating_node_pods "$node"
  kubectl uncordon "$node" >/dev/null
  current_cordoned=false
  kubectl get --raw=/readyz >/dev/null
  wait_longhorn_healthy
  jq -c --arg node "$node" '{node:$node,status,currentVersion,targetVersion}' <<<"$response" \
    >>"$evidence_dir/node-upgrades.ndjson"
done
jq -s '.' "$evidence_dir/node-upgrades.ndjson" >"$evidence_dir/node-upgrades.json"

log 'persisting the upgraded release and replacement-image contract in Zerops project variables'
store_project_variable K8S_VERSION "$target"
store_project_variable K8S_NODE_IMAGE "zerops-k8s-node:$target"
store_project_variable K8S_IMAGE_OBJECT "node-images/zerops-k8s-node-${target}.tar.gz"
store_project_variable K8S_IMAGE_SHA256_OBJECT "node-images/zerops-k8s-node-${target}.tar.gz.sha256"
set_cluster_tag version "$target_version"

log 'reconciling the compatibility-approved add-ons and validating the upgraded cluster'
"$ROOT_DIR/scripts/cluster-bootstrap.sh"
kubectl wait --for=condition=Ready nodes --all --timeout=10m
wait_longhorn_healthy
export SKIP_DISRUPTION_TESTS=true RUN_FULL_CONFORMANCE="$run_full_conformance"
"$ROOT_DIR/scripts/acceptance.sh"
set_cluster_state running "${GITHUB_REPOSITORY:-Samyazz/zerops-k8s}" "${GITHUB_RUN_ID:-local}"
upgrade_started=false
log "controlled Kubernetes upgrade to $target completed and passed acceptance"
