#!/usr/bin/env bash
# shellcheck disable=SC2154 # Zerops service variables are loaded dynamically by load_zerops_env.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

require_env KUBECONFIG ZEROPS_PROJECT_ID ZEROPS_TOKEN
artifact_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence
mkdir -p "$artifact_dir"

restore_nodes=()
restore_stopped_nodes() {
  local node
  for node in "${restore_nodes[@]}"; do agent_request "$node" POST /v1/node/start >/dev/null || true; done
}
trap restore_stopped_nodes EXIT INT TERM

wait_node_unready() {
  local node=$1 deadline=$((SECONDS + 180)) ready
  while (( SECONDS < deadline )); do
    ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" != True ]] && return 0
    sleep 2
  done
  die "node did not leave Ready=True within three minutes: $node"
}

wait_node_dataplane_ready() {
  local node=$1
  kubectl -n calico-system wait pod -l k8s-app=calico-node \
    --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
  kubectl -n istio-system wait pod -l k8s-app=istio-cni-node \
    --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
  kubectl -n istio-system wait pod -l app=ztunnel \
    --field-selector "spec.nodeName=$node" --for=condition=Ready --timeout=10m
}

wait_all_workload_pods_ready() {
  local deadline=$((SECONDS + 900)) count
  while (( SECONDS < deadline )); do
    count=$(kubectl get pods -A -o json | jq \
      '[.items[] | select(.status.phase != "Succeeded") | select(.metadata.deletionTimestamp != null or .status.phase != "Running" or any(.status.containerStatuses[]?; (.ready != true and (.state.terminated.exitCode // -1) != 0)))] | length')
    [[ "$count" -eq 0 ]] && return 0
    sleep 10
  done
  die 'not all non-job Pods became Running and Ready within 15 minutes'
}

wait_metric() {
  local check=$1 operator=$2 expected=$3 query=$4 attempt response observed
  for attempt in {1..60}; do
    response=$(curl --fail --silent --get --data-urlencode "query=$query" \
      http://prometheus.zerops:9090/api/v1/query || true)
    observed=$(jq -er '.data.result[0].value[1]' <<<"$response" 2>/dev/null || true)
    if [[ -n "$observed" ]]; then
      if [[ "$operator" == eq ]] \
        && jq -en --argjson actual "$observed" --argjson expected "$expected" \
          '$actual == $expected' >/dev/null; then
        jq -cn --arg check "$check" --arg operator "$operator" --argjson expected "$expected" \
          --argjson observed "$observed" --arg query "$query" \
          '{check:$check,operator:$operator,expected:$expected,observed:$observed,query:$query}' \
          >> "$metric_evidence"
        return 0
      fi
      if [[ "$operator" == ge ]] \
        && jq -en --argjson actual "$observed" --argjson expected "$expected" \
          '$actual >= $expected' >/dev/null; then
        jq -cn --arg check "$check" --arg operator "$operator" --argjson expected "$expected" \
          --argjson observed "$observed" --arg query "$query" \
          '{check:$check,operator:$operator,expected:$expected,observed:$observed,query:$query}' \
          >> "$metric_evidence"
        return 0
      fi
    fi
    (( attempt < 60 )) || die "fresh metric check failed: $check ($operator $expected, observed ${observed:-none})"
    sleep 10
  done
}

load_zerops_env
require_env K8S_AGENT_TOKEN ELASTICSEARCH_PASSWORD

log 'checking Zerops node resource contract'
"$ROOT_DIR/scripts/verify-node-resources.sh" "$artifact_dir/zerops-node-resources.json"

log 'validating repository manifests'
kubeconform -strict -summary -ignore-missing-schemas \
  -ignore-filename-pattern '.*-values\.yaml$' "$ROOT_DIR/kubernetes" \
  | tee "$artifact_dir/kubeconform.txt"

log 'checking six-node HA topology and core add-ons'
kubectl get nodes -o wide | tee "$artifact_dir/nodes.txt"
[[ $(kubectl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length') -eq 6 ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l) -eq 3 ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/worker -o name | wc -l) -eq 3 ]]
kubectl wait --for=condition=Ready nodes --all --timeout=5m
wait_all_workload_pods_ready
kubectl get pods -A -o wide | tee "$artifact_dir/pods.txt"
kubectl get --raw=/readyz?verbose | tee "$artifact_dir/apiserver-readyz.txt"

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: network-proof, namespace: workloads}
spec:
  selector: {matchLabels: {app: network-proof}}
  template:
    metadata: {labels: {app: network-proof}}
    spec:
      automountServiceAccountToken: false
      nodeSelector: {node-role.kubernetes.io/worker: ""}
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: netexec
          image: registry.k8s.io/e2e-test-images/agnhost:2.54
          args: [netexec, --http-port=8080]
          ports: [{name: http, containerPort: 8080}]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true, runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532}
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
YAML
kubectl -n workloads rollout status daemonset/network-proof --timeout=10m
mapfile -t proof_pods < <(kubectl -n workloads get pods -l app=network-proof -o json | jq -r '.items | sort_by(.spec.nodeName)[] | .metadata.name')
[[ ${#proof_pods[@]} -eq 3 ]]
source_pod=${proof_pods[0]}
target_ip=$(kubectl -n workloads get pod "${proof_pods[1]}" -o jsonpath='{.status.podIP}')
kubectl -n workloads exec "$source_pod" -- wget -qO- "http://$target_ip:8080/hostname" | tee "$artifact_dir/cross-node-network.txt"
kubectl -n workloads exec "$source_pod" -- getent hosts kubernetes.default.svc.cluster.local | tee "$artifact_dir/dns.txt"

curl --fail --silent http://k8sedge:8080/healthz | tee "$artifact_dir/ingress.txt"
curl --fail --silent http://k8sedge:18081/ >/dev/null

if [[ "${SKIP_DISRUPTION_TESTS:-false}" != true ]]; then
  log 'disrupting one non-primary control plane and proving API failover'
  restore_nodes+=(k8scp2)
  agent_request k8scp2 POST /v1/node/stop >/dev/null
  wait_node_unready k8scp2
  kubectl get --raw=/readyz >/dev/null
  agent_request k8scp2 POST /v1/node/start >/dev/null
  kubectl wait node/k8scp2 --for=condition=Ready --timeout=10m
  wait_node_dataplane_ready k8scp2
  recover_terminating_node_pods k8scp2
  wait_all_workload_pods_ready
  restore_nodes=()

  log 'disrupting a worker and proving workload rescheduling'
  victim=$(kubectl -n workloads get pods -l app=demo -o json | jq -er '.items[0].spec.nodeName')
  restore_nodes+=("$victim")
  agent_request "$victim" POST /v1/node/stop >/dev/null
  wait_node_unready "$victim"
  deadline=$((SECONDS + 900))
  until [[ $(kubectl -n workloads get deployment demo -o jsonpath='{.status.availableReplicas}') == 2 ]] \
    && [[ $(kubectl -n workloads get pods -l app=demo -o json | jq --arg node "$victim" '[.items[] | select(.spec.nodeName != $node and any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length') -eq 2 ]]; do
    (( SECONDS < deadline )) || die 'demo workload did not reschedule after worker failure'
    sleep 10
  done
  agent_request "$victim" POST /v1/node/start >/dev/null
  kubectl wait "node/$victim" --for=condition=Ready --timeout=10m
  wait_node_dataplane_ready "$victim"
  recover_terminating_node_pods "$victim"
  wait_all_workload_pods_ready
  restore_nodes=()
fi

log 'proving fresh telemetry ingestion'
marker="zerops-telemetry-${GITHUB_RUN_ID:-local}-$(date +%s)"
synthetic_token="proof-token-${GITHUB_RUN_ID:-local}-$(date +%s)-secret"
synthetic_email="proof-${GITHUB_RUN_ID:-local}@example.invalid"
synthetic_ip='203.0.113.47'
audit_marker="zerops-audit-${GITHUB_RUN_ID:-local}-$(date +%s)"
kubectl -n workloads delete pod telemetry-proof --ignore-not-found --wait=true >/dev/null
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: telemetry-proof, namespace: workloads}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: proof
      image: busybox:1.37.0
      command: [sh, -c, "echo '$marker Authorization: Bearer $synthetic_token email=$synthetic_email client_ip=$synthetic_ip'; sleep 30"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true, runAsNonRoot: true, runAsUser: 65532}
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
YAML
kubectl -n workloads wait pod/telemetry-proof --for=condition=Ready --timeout=3m
for _ in {1..50}; do curl --fail --silent http://k8sedge:8080/hostname >/dev/null; done
audit_selector=$(jq -rn --arg value "zerops-audit-marker=$audit_marker" '$value | @uri')
kubectl get --raw="/api/v1/namespaces?labelSelector=$audit_selector" >/dev/null

metric_evidence="$artifact_dir/prometheus-proof.ndjson"
: > "$metric_evidence"
wait_metric nodes eq 6 'count(max by (exported_node) (timestamp(kube_node_info)) > time() - 120)'
wait_metric kubelet eq 6 'count(timestamp(up{job="kubelet"} == 1) > time() - 120)'
wait_metric cadvisor eq 6 'count(timestamp(up{job="cadvisor"} == 1) > time() - 120)'
wait_metric etcd eq 3 'count(timestamp(up{job="etcd"} == 1) > time() - 120)'
wait_metric apiserver eq 3 'count(timestamp(up{job="apiserver"} == 1) > time() - 120)'
wait_metric controller_manager eq 3 'count(timestamp(up{job="controller-manager"} == 1) > time() - 120)'
wait_metric scheduler eq 3 'count(timestamp(up{job="scheduler"} == 1) > time() - 120)'
wait_metric kube_proxy eq 6 'count(timestamp(up{job="kube-proxy"} == 1) > time() - 120)'
wait_metric calico ge 9 'count(timestamp(up{job="prometheus.scrape.pods",namespace="calico-system"} == 1) > time() - 120)'
wait_metric istio_system ge 13 'count(timestamp(up{job="prometheus.scrape.pods",namespace="istio-system"} == 1) > time() - 120)'
wait_metric istio_ingress ge 2 'count(timestamp(up{job="prometheus.scrape.pods",namespace="istio-ingress"} == 1) > time() - 120)'
wait_metric cert_manager ge 3 'count(timestamp(up{job="prometheus.scrape.pods",namespace="cert-manager"} == 1) > time() - 120)'
wait_metric node_exporter eq 6 'count(timestamp(up{job="prometheus.scrape.services",namespace="observability",service="node-exporter-prometheus-node-exporter"} == 1) > time() - 120)'
wait_metric kube_state_metrics eq 1 'count(timestamp(up{job="prometheus.scrape.services",namespace="observability",service="kube-state-metrics"} == 1) > time() - 120)'
wait_metric alloy eq 6 'count(timestamp(up{job="prometheus.scrape.services",namespace="observability",service="alloy"} == 1) > time() - 120)'
wait_metric fluent_bit eq 6 'count(timestamp(up{job="prometheus.scrape.pods",namespace="observability",pod=~"fluent-bit-.*"} == 1) > time() - 120)'
wait_metric longhorn ge 3 'count(timestamp(up{job="prometheus.scrape.services",namespace="longhorn-system",service="longhorn-backend"} == 1) > time() - 120)'
jq -s '.' "$metric_evidence" > "$artifact_dir/prometheus-proof.json"
rm -f "$metric_evidence"

log_query=$(jq -cn --arg marker "$marker" '{
  size:20,
  sort:[{"@timestamp":{order:"desc"}}],
  query:{bool:{filter:[
    {range:{"@timestamp":{gte:"now-10m"}}},
    {match:{message:{query:$marker,operator:"and"}}}
  ]}}
}')
for attempt in {1..60}; do
  log_response=$(curl --fail --silent -u "elastic:$ELASTICSEARCH_PASSWORD" \
    -H 'Content-Type: application/json' --data "$log_query" \
    'http://elkstorage.zerops:9200/_search' || true)
  if jq -e --arg token "$synthetic_token" --arg email "$synthetic_email" --arg ip "$synthetic_ip" '
    (.hits.total.value > 0)
    and ([.hits.hits[]._source | tostring | contains($token)] | any | not)
    and ([.hits.hits[]._source | tostring | contains($email)] | any | not)
    and ([.hits.hits[]._source | tostring | contains($ip)] | any | not)
    and ([.hits.hits[]._source | tostring | contains("[REDACTED")] | any)
  ' <<<"$log_response" >/dev/null 2>&1; then
    log_hits=$(jq -r '.hits.total.value' <<<"$log_response")
    log_latest=$(jq -r '.hits.hits[0]._source["@timestamp"] // ""' <<<"$log_response")
    jq -n --arg marker "$marker" --argjson hits "$log_hits" --arg latest "$log_latest" \
      '{marker:$marker,hits:$hits,latestTimestamp:$latest,redactionVerified:true,window:"10m"}' \
      > "$artifact_dir/elk-proof.json"
    break
  fi
  (( attempt < 60 )) || die 'fresh redacted Kubernetes log was not found in Zerops ELK'
  sleep 10
done

audit_query=$(jq -cn --arg marker "$audit_marker" '{
  size:20,
  sort:[{"@timestamp":{order:"desc"}}],
  query:{bool:{filter:[
    {range:{"@timestamp":{gte:"now-10m"}}},
    {match:{message:{query:$marker,operator:"and"}}}
  ]}}
}')
for attempt in {1..60}; do
  audit_response=$(curl --fail --silent -u "elastic:$ELASTICSEARCH_PASSWORD" \
    -H 'Content-Type: application/json' --data "$audit_query" \
    'http://elkstorage.zerops:9200/_search' || true)
  if jq -e '.hits.total.value > 0' <<<"$audit_response" >/dev/null 2>&1; then
    audit_hits=$(jq -r '.hits.total.value' <<<"$audit_response")
    audit_latest=$(jq -r '.hits.hits[0]._source["@timestamp"] // ""' <<<"$audit_response")
    jq -n --arg marker "$audit_marker" --argjson hits "$audit_hits" --arg latest "$audit_latest" \
      '{marker:$marker,hits:$hits,latestTimestamp:$latest,window:"10m"}' \
      > "$artifact_dir/audit-proof.json"
    break
  fi
  (( attempt < 60 )) || die 'fresh Kubernetes audit event was not found in Zerops ELK'
  sleep 10
done

trace_query=$(jq -cn '{
  size:20,
  sort:[{"@timestamp":{order:"desc"}}],
  query:{bool:{filter:[
    {range:{"@timestamp":{gte:"now-10m"}}},
    {terms:{"processor.event":["transaction","span"]}},
    {term:{"service.name":"public-gateway-istio_istio-ingress"}}
  ]}}
}')
for attempt in {1..60}; do
  trace_response=$(curl --fail --silent -u "elastic:$ELASTICSEARCH_PASSWORD" \
    -H 'Content-Type: application/json' --data "$trace_query" \
    'http://elkstorage.zerops:9200/traces-*/_search' || true)
  if jq -e '.hits.total.value > 0' <<<"$trace_response" >/dev/null 2>&1; then
    trace_hits=$(jq -r '.hits.total.value' <<<"$trace_response")
    trace_latest=$(jq -r '.hits.hits[0]._source["@timestamp"] // ""' <<<"$trace_response")
    jq -n --argjson hits "$trace_hits" --arg latest "$trace_latest" \
      '{serviceName:"public-gateway-istio_istio-ingress",hits:$hits,latestTimestamp:$latest,window:"10m"}' \
      > "$artifact_dir/trace-proof.json"
    break
  fi
  (( attempt < 60 )) || die 'fresh trace was not found in Zerops APM/ELK'
  sleep 10
done

curl --fail --silent http://grafana.zerops:3000/api/health | tee "$artifact_dir/grafana-health.json"
curl --fail --silent http://kibana.zerops:5601/api/status | jq '{status:.status.overall.level}' | tee "$artifact_dir/kibana-health.json"

log 'running report-only security scans'
kubectl -n workloads delete pod/telemetry-proof --ignore-not-found --wait=true >/dev/null
kubescape_raw=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubescape-raw.json
kubescape scan framework nsa,mitre,cis-v1.10.0 --format json --output "$kubescape_raw" || true
if [[ -s "$kubescape_raw" ]]; then
  jq 'del(.resources)' "$kubescape_raw" > "$artifact_dir/kubescape.json"
else
  jq -n '{scanStatus:"report unavailable"}' > "$artifact_dir/kubescape.json"
fi
rm -f "$kubescape_raw"

if [[ "${RUN_FULL_CONFORMANCE:-true}" == true ]]; then
  log 'running full CNCF certified-conformance suite; this can take several hours'
  sonobuoy delete --wait >/dev/null 2>&1 || true
  sonobuoy run --mode certified-conformance --wait
  sonobuoy retrieve "$artifact_dir"
  result=$(find "$artifact_dir" -maxdepth 1 -name '*sonobuoy*.tar.gz' -o -name '*.tar.gz' | head -n1)
  [[ -n "$result" ]] || die 'Sonobuoy result archive was not created'
  sonobuoy results "$result" | tee "$artifact_dir/sonobuoy-results.txt"
  sonobuoy results "$result" --mode=detailed | tee "$artifact_dir/sonobuoy-detailed.txt"
  grep -q 'Status: passed' "$artifact_dir/sonobuoy-results.txt" || die 'CNCF conformance suite did not pass'
  rm -f "$result"
  sonobuoy delete >/dev/null 2>&1 || true
fi

recover_all_terminating_pods 60
kubectl wait --for=delete namespace/sonobuoy --timeout=3m 2>/dev/null || true
wait_all_workload_pods_ready
kubectl get pods -A -o wide | tee "$artifact_dir/pods-final.txt"
kubectl version -o yaml > "$artifact_dir/kubernetes-version.yaml"
kubectl get gateways,httproutes -A -o yaml > "$artifact_dir/gateway-api.yaml"
kubectl get storageclass,pv,pvc -A -o yaml > "$artifact_dir/storage.yaml"
kubectl auth can-i --list --as system:serviceaccount:headlamp:headlamp-readonly > "$artifact_dir/headlamp-readonly-access.txt"
kubectl -n workloads delete daemonset/network-proof pod/telemetry-proof --ignore-not-found >/dev/null
log 'all requested acceptance checks passed'
