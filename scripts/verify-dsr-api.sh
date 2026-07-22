#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env KUBECONFIG
require kubectl
require openssl

evidence=${1:-${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/dsr-api-certificate.txt}
mkdir -p "$(dirname "$evidence")"
expected_server="https://${CONTROL_PLANE_ENDPOINT}"
actual_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[[ "$actual_server" == "$expected_server" ]] \
  || die "kubeconfig server is $actual_server, expected $expected_server"
tls_override=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.tls-server-name}')
[[ -z "$tls_override" ]] \
  || die 'kubeconfig unexpectedly relies on a tls-server-name override'

dsr_host=${DSR_ENDPOINT%:*}
dsr_port=${DSR_ENDPOINT##*:}
[[ "$dsr_host" == _dsr.k8sedge.zerops && "$dsr_port" == 6443 ]] \
  || die "profile does not declare the reviewed Zerops DSR API endpoint: $DSR_ENDPOINT"
[[ "$CONTROL_PLANE_ENDPOINT" == k8sedge.zerops:6443 ]] \
  || die "profile does not use the VPN-compatible HAProxy endpoint: $CONTROL_PLANE_ENDPOINT"

certificate=$(mktemp)
trap 'rm -f "$certificate"' EXIT
timeout 15 openssl s_client -connect "$CONTROL_PLANE_ENDPOINT" -servername "$dsr_host" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM >"$certificate"
openssl x509 -in "$certificate" -noout -checkhost "$dsr_host" >/dev/null
kubectl --request-timeout=15s get --raw=/readyz >/dev/null
{
  printf 'vpn-server=%s\n' "$actual_server"
  printf 'in-project-dsr-server=https://%s\n' "$DSR_ENDPOINT"
  printf 'tls-server-name-override=absent\n'
  openssl x509 -in "$certificate" -noout -subject -issuer -dates -ext subjectAltName
} >"$evidence"
