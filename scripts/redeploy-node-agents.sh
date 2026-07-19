#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_PROJECT_ID
require zcli
require curl
require jq

if [[ -z "${K8S_AGENT_TOKEN:-}" ]]; then
  load_zerops_env
fi
require_env K8S_AGENT_TOKEN

declare -A setups=(
  [k8sworker1]=worker1
  [k8sworker2]=worker2
  [k8sworker3]=worker3
  [k8scp2]=controlplane2
  [k8scp3]=controlplane3
  [k8scp1]=controlplane1
)
order=(k8sworker1 k8sworker2 k8sworker3 k8scp2 k8scp3 k8scp1)
targets=("${order[@]}")
if (( $# )); then
  targets=("$@")
fi
for service in "${targets[@]}"; do
  [[ -v "setups[$service]" ]] || die "refusing to deploy an unknown node agent: $service"
done

version_name="github-${GITHUB_RUN_ID:-local}-${GITHUB_SHA:-working}-node-recovery"
source_args=(--workspace-state all)
if [[ ! -d "$ROOT_DIR/.git" ]]; then
  source_args=(--no-git)
fi

for service in "${order[@]}"; do
  [[ " ${targets[*]} " == *" $service "* ]] || continue
  setup=${setups[$service]}
  restart_node=false
  if curl --fail --silent --connect-timeout 3 --max-time 5 "http://${service}:18080/healthz" >/dev/null; then
    node_state=$(agent_request "$service" GET /v1/state | jq -er '.status')
    if [[ "$node_state" == running ]]; then
      log "stopping nested node before deploying its agent: $service"
      agent_request "$service" POST /v1/node/stop >/dev/null
      restart_node=true
    fi
  fi

  log "deploying restart-safe node agent to $service"
  deployed=false
  for attempt in 1 2 3; do
    set +e
    timeout "${ZEROPS_DEPLOY_TIMEOUT:-35m}" zcli push "$service" -P "$ZEROPS_PROJECT_ID" --setup "$setup" \
      --version-name "$version_name" --working-dir "$ROOT_DIR" "${source_args[@]}"
    result=$?
    set -e
    if (( result == 0 )); then
      deployed=true
      break
    fi
    (( result != 124 )) || die "Zerops node-agent deployment timed out for $service"
    log "node-agent deployment failed on attempt $attempt; retrying $service"
    sleep 5
  done
  [[ "$deployed" == true ]] || die "node-agent deployment failed after three attempts: $service"
  wait_for_agent "$service"
  if [[ "$restart_node" == true ]]; then
    log "restarting nested node after deploying its agent: $service"
    agent_request "$service" POST /v1/node/start >/dev/null
    if [[ -n "${KUBECONFIG:-}" && -s "${KUBECONFIG:-}" ]] && kubectl get "node/$service" >/dev/null 2>&1; then
      kubectl wait "node/$service" --for=condition=Ready --timeout=15m
      recover_terminating_node_pods "$service"
    fi
  fi
done
