#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

disrupt=false
case "${1:-}" in
  '') ;;
  --disrupt) disrupt=true ;;
  *) die 'usage: verify-vrrp-failover.sh [--disrupt]' ;;
esac

require getent
require ssh
require curl
[[ -n "$VRRP_VIP" ]] || resolve_vrrp_topology

mapfile -t edge_addresses < <(
  getent ahostsv4 "${EDGE_HOSTNAME}.zerops" | awk '{print $1}' | sort -u
)
[[ ${#edge_addresses[@]} -eq 2 ]] \
  || die "expected two ${EDGE_HOSTNAME} replica addresses, found ${#edge_addresses[@]}"

known_hosts=$(mktemp)
trap 'rm -f "$known_hosts"' EXIT
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)

vip_owner() {
  local address owner='' owners=0
  for address in "${edge_addresses[@]}"; do
    # VRRP_VIP is derived by the validated IPv4-only library function.
    # shellcheck disable=SC2029
    if ssh "${ssh_options[@]}" "zerops@$address" \
        "ip address show | grep -Fq 'inet ${VRRP_VIP}/32 '"; then
      owner=$address
      ((owners += 1))
    fi
  done
  [[ $owners -eq 1 ]] || return 1
  printf '%s\n' "$owner"
}

wait_for_owner() {
  local rejected=${1:-} deadline owner
  deadline=$((SECONDS + 20))
  until owner=$(vip_owner); do
    (( SECONDS < deadline )) || die "VRRP did not converge to exactly one owner of $VRRP_VIP"
    sleep 1
  done
  while [[ -n "$rejected" && "$owner" == "$rejected" ]]; do
    (( SECONDS < deadline )) || die "VRRP VIP did not move away from failed replica $rejected"
    sleep 1
    owner=$(vip_owner) || continue
  done
  printf '%s\n' "$owner"
}

probe_api() {
  [[ $(curl --insecure --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 "https://${VRRP_VIP}:${CONTROL_PLANE_PORT}/readyz") == ok ]]
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl --request-timeout=15s get --raw=/readyz >/dev/null
  fi
}

initial_owner=$(wait_for_owner)
probe_api
if [[ "$disrupt" != true ]]; then
  jq -n --arg vip "$VRRP_VIP" --arg owner "$initial_owner" \
    --argjson replicas "$(printf '%s\n' "${edge_addresses[@]}" | jq -R . | jq -s .)" \
    '{vip:$vip,owner:$owner,replicas:$replicas,exactlyOneOwner:true,apiReady:true,disrupted:false}'
  exit 0
fi

started=$SECONDS
ssh "${ssh_options[@]}" "zerops@$initial_owner" 'sudo pkill -TERM keepalived'
replacement_owner=$(wait_for_owner "$initial_owner")
probe_api
elapsed=$((SECONDS - started))
jq -n --arg vip "$VRRP_VIP" --arg initial "$initial_owner" \
  --arg replacement "$replacement_owner" --argjson seconds "$elapsed" \
  '{vip:$vip,initialOwner:$initial,replacementOwner:$replacement,failoverSeconds:$seconds,exactlyOneOwner:true,apiReady:true,disrupted:true}'
