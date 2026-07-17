#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env ZEROPS_TOKEN ZEROPS_PROJECT_ID ZEROPS_CLIENT_ID

prometheus_payload=$(jq -cn \
  --arg project "$ZEROPS_PROJECT_ID" \
  '{forwardMetricsFromProjectId:$project,prometheusProjectId:$project,projectCorePackage:"SERIOUS"}')
elk_payload=$(jq -cn \
  --arg project "$ZEROPS_PROJECT_ID" \
  '{elkProjectId:$project,forwardLogsFromProjectId:$project,includeLogstash:true,includeApm:true,projectCorePackage:"SERIOUS"}')

if api_put "/client/${ZEROPS_CLIENT_ID}/first-class-recipe/prometheus" "$prometheus_payload" \
  && api_put "/client/${ZEROPS_CLIENT_ID}/first-class-recipe/elk" "$elk_payload"; then
  log 'Zerops first-class Prometheus/Grafana and ELK recipes are configured'
  exit 0
fi

log 'First-class endpoint was unavailable to this project-scoped token; using the official recipe service import fallback'
if ! service_exists prometheus; then
  zcli project service-import "$ROOT_DIR/infrastructure/observability.import.yaml" -P "$ZEROPS_PROJECT_ID" >/dev/null
fi
