#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID
require jq
require zcli

mode=${1:-apply}
[[ "$mode" == plan || "$mode" == apply || "$mode" == purge ]] \
  || die 'usage: reconcile-profile-services.sh [plan|apply|purge]'

case "$K8S_PROFILE" in
  full) import_file="$ROOT_DIR/import.yaml" ;;
  production) import_file="$ROOT_DIR/import.production.yaml" ;;
  staging) import_file="$ROOT_DIR/import.staging.yaml" ;;
  *) die "unsupported profile: $K8S_PROFILE" ;;
esac
[[ -s "$import_file" ]] || die "profile import is missing: $import_file"

inventory=$(mktemp)
filtered_import=$(mktemp)
trap 'rm -f "$inventory" "$filtered_import"' EXIT INT TERM

refresh_inventory() {
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$inventory"
}

mapfile -t desired < <(profile_json '.services[].hostname')
if [[ "${PRESERVE_OPTIONAL_WORKERS:-false}" == true ]]; then
  persisted_workers=$(cluster_tag_value workers); persisted_workers=${persisted_workers:-${#WORKERS[@]}}
  if (( persisted_workers > ${#WORKERS[@]} )); then
    mapfile -t selected_optional < <(profile_json '.topology.optionalWorkers[]?')
    desired+=("${selected_optional[@]}")
  fi
fi
mapfile -t known < <(jq -sr '[.[] | (.services[].hostname), (.topology.optionalWorkers[]?)] | unique[]' "$ROOT_DIR"/profiles/*.json)
(( ${#desired[@]} > 0 )) || die "profile has no services: $K8S_PROFILE"

contains() {
  local needle=$1 item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

service_present() {
  jq -e --arg name "$1" '.list | any(.name == $name)' "$inventory" >/dev/null
}

service_failed_or_partial() {
  jq -e --arg name "$1" '
    .list[]
    | select(.name == $name)
    | [
        .status?, .state?, .serviceStackStatus?, .serviceStatus?,
        .serviceStackStatusInfo?.status?, .serviceStackStatusInfo?.state?
      ]
    | map(select(type == "string") | ascii_upcase)
    | any(test("FAILED|ERROR|CREATE_FAILED|DELETE_FAILED|PARTIAL"))
  ' "$inventory" >/dev/null
}

service_requires_recreate() {
  local name=$1 target_disk
  target_disk=$(jq -er --arg name "$name" \
    '.services[] | select(.hostname == $name) | .resources.diskGb // empty' \
    "$PROFILE_FILE" 2>/dev/null || true)
  [[ -n "$target_disk" ]] || return 1
  jq -e --arg name "$name" --argjson target "$target_disk" '
    .list[]
    | select(.name == $name)
    | (.currentAutoscaling.verticalAutoscaling // .customAutoscaling.verticalAutoscaling)
    | .minResource.diskGBytes > $target
  ' "$inventory" >/dev/null
}

wait_absent() {
  local name=$1 deadline=$((SECONDS + 1800))
  while (( SECONDS < deadline )); do
    refresh_inventory
    service_present "$name" || return 0
    sleep 5
  done
  die "Zerops service deletion did not finish within 30 minutes: $name"
}

delete_service() {
  local name=$1
  if [[ "$mode" == purge ]]; then
    log "deleting partial recipe-owned service from failed clean creation: $name"
  else
    log "deleting recipe-owned service not valid for target profile $K8S_PROFILE: $name"
  fi
  [[ "$mode" == apply || "$mode" == purge ]] || return 0
  zcli service delete "$name" -P "$ZEROPS_PROJECT_ID" --confirm
  wait_absent "$name"
}

refresh_inventory

# Dependents and runtimes are deleted before their managed backing services.
delete_order=(
  apmserver logstash kibana grafana prometheus
  k8sworker4 k8sworker3 k8sworker2 k8sworker1
  k8scp3 k8scp2 k8scp1 k8sedge
  grafanadb prometheusbackups elkstorage k8sbackups
)

if [[ "$mode" == purge ]]; then
  for name in "${delete_order[@]}"; do
    contains "$name" "${known[@]}" || continue
    service_present "$name" && delete_service "$name"
  done
  for name in "${known[@]}"; do
    service_present "$name" && delete_service "$name"
  done
  refresh_inventory
  leftovers=()
  for name in "${known[@]}"; do
    service_present "$name" && leftovers+=("$name")
  done
  (( ${#leftovers[@]} == 0 )) \
    || die "partial recipe-owned services remain after cleanup: ${leftovers[*]}"
  log 'all partial recipe-owned services from the failed clean creation were removed'
  exit 0
fi

for name in "${delete_order[@]}"; do
  contains "$name" "${known[@]}" || continue
  contains "$name" "${desired[@]}" && continue
  service_present "$name" && delete_service "$name"
done

# Catch future recipe-owned services not yet represented in delete_order.
for name in "${known[@]}"; do
  contains "$name" "${desired[@]}" && continue
  service_present "$name" && delete_service "$name"
done

refresh_inventory
if [[ "${RECREATE_FAILED_PROFILE_SERVICES:-true}" == true ]]; then
  for name in "${desired[@]}"; do
    if service_present "$name" && service_failed_or_partial "$name"; then
      [[ "$(cluster_tag_value state)" == destroyed ]] \
        || die "target service is failed/partial while a live cluster is recorded; destroy explicitly before replacement: $name"
      delete_service "$name"
    fi
  done
fi

if [[ "${RECREATE_TARGET_RUNTIME_SERVICES:-false}" == true ]]; then
  [[ "$(cluster_tag_value state)" == destroyed ]] \
    || die 'target runtimes may be recreated only after the nested cluster is destroyed'
  mapfile -t target_runtimes < <(profile_json '.services[] | select(.type != "object-storage") | .hostname')
  for name in "${target_runtimes[@]}"; do
    if service_present "$name"; then
      log "recreating target runtime for clean profile switch: $name"
      delete_service "$name"
    fi
  done
fi

if [[ "${RECREATE_INCOMPATIBLE_PROFILE_SERVICES:-true}" == true \
      && "$(cluster_tag_value state)" == destroyed ]]; then
  for name in "${desired[@]}"; do
    if service_present "$name" && service_requires_recreate "$name"; then
      log "recreating $name because Zerops disks cannot shrink to the $K8S_PROFILE contract"
      delete_service "$name"
    fi
  done
fi

refresh_inventory
missing=()
for name in "${desired[@]}"; do
  service_present "$name" || missing+=("$name")
done

if (( ${#missing[@]} > 0 )); then
  log "profile $K8S_PROFILE is missing services: ${missing[*]}"
  if [[ "$mode" == apply ]]; then
    names=$(IFS=,; printf '%s' "${missing[*]}")
    {
      head -n 1 "$import_file" | grep -q '^#.*Preprocessor=on' \
        && head -n 1 "$import_file" || printf '#zeropsPreprocessor=on\n'
      printf 'services:\n'
      awk -v names="$names" '
        BEGIN {
          count = split(names, values, ",")
          for (i = 1; i <= count; i++) wanted[values[i]] = 1
        }
        /^  - hostname:/ {
          emit = ($3 in wanted)
        }
        emit { print }
      ' "$import_file"
    } >"$filtered_import"
    for name in "${missing[@]}"; do
      grep -Fq "  - hostname: $name" "$filtered_import" \
        || die "could not render missing service from $import_file: $name"
    done
    import_succeeded=false
    for attempt in 1 2 3; do
      if zcli project service-import "$filtered_import" -P "$ZEROPS_PROJECT_ID"; then
        import_succeeded=true
        break
      fi
      log "profile service import failed on attempt $attempt; removing any partial target services before retry"
      refresh_inventory
      for name in "${missing[@]}"; do
        service_present "$name" && delete_service "$name"
      done
      (( attempt == 3 )) || sleep $((attempt * 5))
    done
    [[ "$import_succeeded" == true ]] \
      || die "profile service import failed after clean retries: $K8S_PROFILE"
  fi
fi

[[ "$mode" == apply ]] || exit 0

deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  refresh_inventory
  pending=0
  for name in "${desired[@]}"; do
    service_present "$name" || pending=$((pending + 1))
  done
  (( pending == 0 )) && break
  sleep 5
done
(( pending == 0 )) || die "profile services did not appear within 30 minutes: $K8S_PROFILE"

unexpected=()
for name in "${known[@]}"; do
  contains "$name" "${desired[@]}" && continue
  service_present "$name" && unexpected+=("$name")
done
(( ${#unexpected[@]} == 0 )) \
  || die "unexpected recipe-owned services remain for $K8S_PROFILE: ${unexpected[*]}"

log "exact recipe-owned Zerops service inventory reconciled for profile $K8S_PROFILE"
