#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env KUBECONFIG
require kubectl
require openssl

evidence=${1:-${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/vrrp-api-certificate.txt}
mkdir -p "$(dirname "$evidence")"
expected_endpoint="${VRRP_VIP}:6443"
[[ "$CONTROL_PLANE_ENDPOINT" == "$expected_endpoint" ]] \
  || die "control-plane endpoint is $CONTROL_PLANE_ENDPOINT, expected VRRP endpoint $expected_endpoint"

expected_server="https://${CONTROL_PLANE_ENDPOINT}"
actual_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ "$actual_server" == "$expected_server" ]] \
  || die "kubeconfig server is $actual_server, expected $expected_server"
tls_override=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.tls-server-name}')
[[ -z "$tls_override" ]] \
  || die 'kubeconfig unexpectedly relies on a tls-server-name override'

certificate=$(mktemp)
trap 'rm -f "$certificate"' EXIT
timeout 15 openssl s_client -connect "$CONTROL_PLANE_ENDPOINT" \
  -servername "$VRRP_VIP" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM >"$certificate"
openssl x509 -in "$certificate" -noout -checkip "$VRRP_VIP" >/dev/null
kubectl --request-timeout=15s get --raw=/readyz >/dev/null
{
  printf 'vrrp-server=%s\n' "$actual_server"
  printf 'vrrp-vip=%s\n' "$VRRP_VIP"
  printf 'vrrp-virtual-router-id=%s\n' "$VRRP_VIRTUAL_ROUTER_ID"
  printf 'tls-server-name-override=absent\n'
  openssl x509 -in "$certificate" -noout -subject -issuer -dates -ext subjectAltName
} >"$evidence"
