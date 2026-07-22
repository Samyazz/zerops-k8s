#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env KUBECONFIG
require kubectl
[[ "$DSR_ENDPOINT" == _dsr.k8sedge.zerops:6443 ]] \
  || die "profile does not declare the reviewed Zerops DSR API endpoint: $DSR_ENDPOINT"

evidence=${1:-${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence/dsr-in-project-readyz.txt}
mkdir -p "$(dirname "$evidence")"

cleanup() {
  kubectl -n kube-system delete pod/dsr-api-proof \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: dsr-api-proof
  namespace: kube-system
  labels: {app.kubernetes.io/name: dsr-api-proof}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: busybox:1.37.0
      command: [sh, -ec]
      args:
        - 'test "\$(wget -qO- --no-check-certificate https://${DSR_ENDPOINT}/readyz)" = ok; printf "dsr-endpoint=%s readyz=ok\\n" "${DSR_ENDPOINT}"'
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true, runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532}
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
YAML
kubectl -n kube-system wait pod/dsr-api-proof \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m
kubectl -n kube-system logs pod/dsr-api-proof | tee "$evidence"
grep -Fqx "dsr-endpoint=${DSR_ENDPOINT} readyz=ok" "$evidence"
