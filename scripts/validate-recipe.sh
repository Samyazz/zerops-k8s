#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

profile=${K8S_PROFILE:-full}
live=false
for argument in "$@"; do
  case "$argument" in
    full|production|staging) profile=$argument ;;
    --live) live=true ;;
    *) printf 'usage: %s [full|production|staging] [--live]\n' "$0" >&2; exit 2 ;;
  esac
done
export K8S_PROFILE=$profile

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

case "$K8S_PROFILE" in
  full) import_file="$ROOT_DIR/import.yaml" ;;
  production) import_file="$ROOT_DIR/import.production.yaml" ;;
  staging) import_file="$ROOT_DIR/import.staging.yaml" ;;
esac
[[ -s "$import_file" ]] || die "profile import is missing: $import_file"

grep -Fq "K8S_PROFILE: ${K8S_PROFILE}" "$import_file" \
  || die "$import_file does not select profile $K8S_PROFILE"
grep -Fq -- "- zerops-k8s-profile-${K8S_PROFILE}" "$import_file" \
  || die "$import_file is missing its profile ownership tag"
grep -Fq "K8S_VERSION: v${KUBERNETES_VERSION}" "$import_file" \
  || die "$import_file K8S_VERSION differs from versions.env"
grep -Fq "K8S_NODE_IMAGE: zerops-k8s-node:v${KUBERNETES_VERSION}" "$import_file" \
  || die "$import_file node image differs from versions.env"
[[ $(profile_json '.topology.controlPlaneEndpoint.mode') == vrrp ]] \
  || die "$PROFILE_FILE control-plane endpoint is not VRRP"
[[ "$CONTROL_PLANE_PORT" == 6443 ]] \
  || die "$PROFILE_FILE control-plane endpoint port is not 6443"
grep -Fq "K8S_VRRP_PREFIX_LENGTH: \"${VRRP_PREFIX_LENGTH}\"" "$import_file" \
  || die "$import_file VRRP prefix differs from the profile descriptor"
grep -Fq "K8S_VRRP_HOST_OCTET: \"${VRRP_HOST_OCTET}\"" "$import_file" \
  || die "$import_file VRRP host octet differs from the profile descriptor"
grep -Fq "K8S_VRRP_VIRTUAL_ROUTER_ID: \"${VRRP_VIRTUAL_ROUTER_ID}\"" "$import_file" \
  || die "$import_file VRRP virtual-router ID differs from the profile descriptor"
! grep -Eq '^[[:space:]]+K8S_(CONTROL_PLANE_ENDPOINT|VRRP_VIP):' "$import_file" \
  || die "$import_file hard-codes a project-specific VRRP address"
core_package=$(profile_json '.project.corePackage')
grep -Fq "corePackage: ${core_package}" "$import_file" \
  || die "$import_file core package differs from the profile descriptor"

mapfile -t descriptor_services < <(profile_json '.services[].hostname')
mapfile -t import_services < <(
  awk '/^services:/{services=1; next} services && /^  - hostname:/{print $3}' "$import_file"
)
[[ ${#descriptor_services[@]} -gt 0 ]] || die "profile $K8S_PROFILE defines no services"
[[ "${descriptor_services[*]}" == "${import_services[*]}" ]] \
  || die "$import_file service inventory/order differs from the profile descriptor"

if [[ "$NODE_IMAGE_MODE" == object-storage ]]; then
  grep -Fq "K8S_IMAGE_OBJECT: node-images/zerops-k8s-node-v${KUBERNETES_VERSION}.tar.gz" \
    "$import_file" || die "$import_file node-image object differs from versions.env"
  object_storage_size=$(awk '
    $0 ~ /^  - hostname: k8sbackups$/ {service=1; next}
    service && $1 == "objectStorageSize:" {print $2; exit}
  ' "$import_file")
  expected_quota=$(profile_json '.topology.backup.quotaGb')
  [[ "$object_storage_size" =~ ^[0-9]+$ && "$object_storage_size" -eq "$expected_quota" ]] \
    || die "$import_file backup quota differs from the profile descriptor"
  grep -Fq "K8S_BACKUP_QUOTA_GB: \"${object_storage_size}\"" "$import_file" \
    || die "$import_file backup quota variable differs from object-storage size"
else
  ! grep -Eq 'K8S_IMAGE_(OBJECT|SHA256_OBJECT)|K8S_BACKUP_QUOTA_GB|hostname: k8sbackups' "$import_file" \
    || die "$import_file local-image profile contains an object-storage dependency"
fi

# zeropsSetup without buildFromGit is rejected by the Zerops import API. The
# reusable workflow selects the setup explicitly from the profile descriptor.
if ! awk '
  function validate_service() {
    if (has_setup && !has_git) exit 1
    has_setup=0
    has_git=0
  }
  /^  - hostname:/ {validate_service(); in_service=1; next}
  in_service && /^    zeropsSetup:/ {has_setup=1; next}
  in_service && /^    buildFromGit:/ {has_git=1; next}
  END {validate_service()}
' "$import_file"; then
  die "$import_file uses zeropsSetup without a git-backed recipe build"
fi

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

if [[ $(profile_json '.addons.gateway') == traefik ]]; then
  [[ "$TRAEFIK_CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die 'Traefik chart version is not pinned'
  [[ "$TRAEFIK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die 'Traefik application version is not pinned'
  [[ "$TRAEFIK_IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die 'Traefik image digest is not pinned'
fi

python3 -m unittest discover -s "$ROOT_DIR/scripts/tests" >/dev/null
log "static profile/import validation passed for $K8S_PROFILE"

[[ "$live" == true ]] || exit 0
require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID

response=$(mktemp)
trap 'rm -f "$response"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"

# Limit the equality check to the repository-owned service universe. A zcp
# service or any other unrelated user service is intentionally preserved.
expected=$(profile_json '[.services[].hostname] | sort')
actual=$(jq -c --slurpfile full "$ROOT_DIR/profiles/full.json" \
  --slurpfile production "$ROOT_DIR/profiles/production.json" \
  --slurpfile staging "$ROOT_DIR/profiles/staging.json" '
    ([$full[0], $production[0], $staging[0]]
      | map((.services[].hostname), (.topology.optionalWorkers[]?))
      | unique) as $owned
    | [.list[].name | select(. as $name | $owned | index($name))] | sort
  ' "$response")
jq -en --argjson expected "$expected" --argjson actual "$actual" '$actual == $expected' >/dev/null \
  || die "live recipe-owned service inventory does not exactly match profile $K8S_PROFILE"

jq -e --argjson expected "$expected" '
  [.list[]
    | select(.name as $name | $expected | index($name))
    | [
        .status?, .state?, .serviceStackStatus?, .serviceStatus?,
        .serviceStackStatusInfo?.status?, .serviceStackStatusInfo?.state?
      ]
    | map(select(type == "string") | ascii_upcase)
    | .[]
    | select(test("FAILED|ERROR|CREATING|DELETING|PENDING|PARTIAL"))
  ] | length == 0
' "$response" >/dev/null || die 'a selected profile service is failed or transitional'

log "live recipe-owned service inventory exactly matches $K8S_PROFILE (${#descriptor_services[@]} services)"
