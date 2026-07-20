#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID

grep -Fq "K8S_VERSION: v${KUBERNETES_VERSION}" "$ROOT_DIR/import.yaml" \
  || die 'import.yaml K8S_VERSION differs from versions.env'
grep -Fq "K8S_NODE_IMAGE: zerops-k8s-node:v${KUBERNETES_VERSION}" "$ROOT_DIR/import.yaml" \
  || die 'import.yaml node image differs from versions.env'
grep -Fq "K8S_IMAGE_OBJECT: node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz" \
  "$ROOT_DIR/import.yaml" || die 'import.yaml node-image object differs from versions.env'
object_storage_size=$(awk '
  $0 ~ /^  - hostname: k8sbackups$/ {service=1; next}
  service && $1 == "objectStorageSize:" {print $2; exit}
' "$ROOT_DIR/import.yaml")
[[ "$object_storage_size" =~ ^[0-9]+$ && "$object_storage_size" -ge 25 ]] \
  || die 'the publishable recipe must provision at least 25 GB for Kubernetes recovery objects'
grep -Fq "K8S_BACKUP_QUOTA_GB: \"${object_storage_size}\"" "$ROOT_DIR/import.yaml" \
  || die 'the backup quota project variable must match the recipe object-storage size'
target_minor=${KUBERNETES_VERSION%.*}
jq -e --arg minor "$target_minor" --arg calico "$CALICO_VERSION" \
  --arg istio "$ISTIO_VERSION" --arg longhorn "$LONGHORN_VERSION" \
  --arg gateway "$GATEWAY_API_VERSION" '
    .schemaVersion == 1
    and .approvedTargets[$minor].calico == $calico
    and .approvedTargets[$minor].istio == $istio
    and .approvedTargets[$minor].longhorn == $longhorn
    and .approvedTargets[$minor].gatewayApi == $gateway
  ' "$ROOT_DIR/upgrade-policy.json" >/dev/null \
  || die 'upgrade-policy.json does not approve the pinned Kubernetes/add-on combination'
python3 -m unittest discover -s "$ROOT_DIR/scripts/tests" >/dev/null

mapfile -t expected_services < <(
  awk '/^services:/{services=1; next} services && /^  - hostname:/{print $3}' "$ROOT_DIR/import.yaml"
)
[[ ${#expected_services[@]} -gt 0 ]] || die 'the first-class recipe defines no services'

response=$(mktemp)
api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"
mapfile -t missing < <(
  for service in "${expected_services[@]}"; do
    jq -e --arg service "$service" '.list | any(.name == $service)' "$response" >/dev/null \
      || printf '%s\n' "$service"
  done
)
rm "$response"

if (( ${#missing[@]} > 0 )); then
  die "the current project does not match import.yaml; missing services: ${missing[*]}"
fi
log "validated ${#expected_services[@]} live services against the publishable first-class recipe"
