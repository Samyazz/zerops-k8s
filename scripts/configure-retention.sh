#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops Elasticsearch variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

if [[ $(profile_json '.addons.observability') != advanced ]]; then
  log "dedicated observability retention is not applicable to profile $K8S_PROFILE"
  exit 0
fi

load_zerops_env
require_env ELASTICSEARCH_PASSWORD
auth=(-u "elastic:$ELASTICSEARCH_PASSWORD")
base=http://elkstorage.zerops:9200

for attempt in {1..120}; do
  if curl --fail --silent "${auth[@]}" "$base/_cluster/health" >/dev/null; then break; fi
  (( attempt < 120 )) || die 'Elasticsearch did not become ready'
  sleep 5
done

curl --fail --silent --show-error "${auth[@]}" -X PUT "$base/_ilm/policy/zerops-demo-4h" \
  -H 'Content-Type: application/json' \
  --data '{"policy":{"phases":{"hot":{"actions":{}},"delete":{"min_age":"4h","actions":{"delete":{}}}}}}' >/dev/null
curl --fail --silent --show-error "${auth[@]}" -X PUT "$base/_index_template/zerops-demo-4h" \
  -H 'Content-Type: application/json' \
  --data '{"index_patterns":["logstash-*"],"priority":500,"template":{"settings":{"index.lifecycle.name":"zerops-demo-4h"}}}' >/dev/null

# Elastic APM and the Kubernetes log pipeline use data streams. Their existing
# composable templates must remain authoritative, so configure native
# data-stream lifecycle instead of shadowing those templates.
for pattern in 'logs-*' 'metrics-*' 'traces-*'; do
  curl --fail --silent --show-error "${auth[@]}" -X PUT "$base/_data_stream/$pattern/_lifecycle" \
    -H 'Content-Type: application/json' --data '{"data_retention":"4h"}' >/dev/null
done
log 'configured four-hour Elasticsearch/ELK retention'
