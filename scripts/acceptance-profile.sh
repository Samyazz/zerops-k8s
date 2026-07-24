#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

[[ "$K8S_PROFILE" != full ]] || die 'acceptance-profile.sh is only for production and staging'
require_env KUBECONFIG ZEROPS_PROJECT_ID ZEROPS_TOKEN
load_zerops_env
require_env K8S_AGENT_TOKEN

artifact_dir=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/evidence
mkdir -p "$artifact_dir"

restore_nodes=()
cleanup_objects=()
cleanup() {
  local node object
  for node in "${restore_nodes[@]}"; do
    agent_request "$node" POST /v1/node/start >/dev/null || true
  done
  for object in "${cleanup_objects[@]}"; do
    kubectl -n workloads delete "$object" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

wait_metrics_api() {
  local deadline=$((SECONDS + 300))
  until kubectl top nodes >/dev/null 2>&1 && kubectl -n workloads top pods >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die 'metrics-server did not provide node and workload metrics within five minutes'
    sleep 5
  done
  kubectl top nodes >"$artifact_dir/node-metrics.txt"
  kubectl -n workloads top pods >"$artifact_dir/workload-metrics.txt"
}

http_probe() {
  curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    --retry 2 --retry-delay 1 --retry-all-errors "$@"
}

assert_absent_namespace() {
  local namespace=$1
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    die "forbidden namespace exists in $K8S_PROFILE: $namespace"
  fi
}

assert_absent_crd() {
  local crd=$1
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    die "forbidden CRD exists in $K8S_PROFILE: $crd"
  fi
}

assert_profile_service_inventory() {
  local response expected actual
  response=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$response"
  expected=$(profile_json '[.services[].hostname] | sort')
  actual=$(jq -c '
    [ .list[].name
      | select(. as $name | [
          "k8scp1","k8scp2","k8scp3","k8sworker1","k8sworker2","k8sworker3","k8sworker4",
          "k8sedge","k8sbackups","grafanadb","prometheusbackups","grafana","prometheus",
          "elkstorage","kibana","logstash","apmserver"
        ] | index($name)) ] | sort
  ' "$response")
  jq -en --argjson expected "$expected" --argjson actual "$actual" '$actual == $expected' >/dev/null \
    || die "recipe-owned Zerops services do not exactly match profile $K8S_PROFILE"
  jq -e '[.list[] | select((.status // "") | test("FAILED|CREATING|DELETING|PENDING"))] | length == 0' \
    "$response" >/dev/null || die 'a Zerops service is failed or transitional'
  jq --argjson expected "$expected" \
    '[.list[] | select(.name as $name | $expected | index($name)) | {name,status,id,serviceStackTypeId}] | sort_by(.name)' \
    "$response" | "$ROOT_DIR/scripts/redact-evidence.sh" >"$artifact_dir/zerops-services.json"
  rm -f "$response"
}

collect_platform_log_evidence() {
  local inventory service id destination deadline latest_timestamp
  local fresh_after=$(( $(date -u +%s) - 300 ))
  inventory=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$inventory"

  for service in "${NODES[@]}"; do
    agent_request "$service" GET /v1/state >/dev/null
  done
  if [[ "$EDGE_ENABLED" == true ]]; then
    http_probe "http://${VRRP_VIP}:8080/healthz" >/dev/null
  fi

  while read -r service; do
    [[ -n "$service" ]] || continue
    id=$(jq -er --arg service "$service" '.list[] | select(.name == $service) | .id' "$inventory")
    destination="$artifact_dir/zerops-${service}-logs.ndjson"
    deadline=$((SECONDS + 120))
    until [[ -s "$destination" ]] || (( SECONDS >= deadline )); do
      if ! zcli service log -P "$ZEROPS_PROJECT_ID" -S "$id" --format JSONSTREAM --limit 20 \
        | "$ROOT_DIR/scripts/redact-evidence.sh" >"$destination"; then
        : >"$destination"
      fi
      [[ -s "$destination" ]] || sleep 5
    done
    [[ -s "$destination" ]] || die "Zerops returned no fresh runtime log evidence for $service"
    latest_timestamp=$(jq -sr '
      [.[] | .timestamp? | select(type == "string")
        | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601]
      | max // 0
    ' "$destination")
    (( latest_timestamp >= fresh_after )) \
      || die "Zerops returned runtime logs for $service, but none were fresh within five minutes"
  done < <(profile_json '.services[] | select(.type != "object-storage") | .hostname')
  rm -f "$inventory"
}

collect_platform_stats_evidence() {
  local inventory expected_ids response payload deadline actual_count=0 expected_count
  local backup_id backup_status backup_usage backup_quota
  local fresh_after=$(( $(date -u +%s) - 600 ))
  require_env ZEROPS_CLIENT_ID
  inventory=$(mktemp)
  expected_ids=$(mktemp)
  response=$(mktemp)
  api_request_file GET "/project/${ZEROPS_PROJECT_ID}/service-stack?limit=100" '' "$inventory"
  jq --argjson runtime_names "$(profile_json '[.services[] | select(.type != "object-storage") | .hostname]')" \
    '[.list[] | select(.name as $name | $runtime_names | index($name)) | .id] | sort' \
    "$inventory" >"$expected_ids"
  expected_count=$(jq 'length' "$expected_ids")
  (( expected_count > 0 )) || die 'profile has no runtime services for Zerops statistics evidence'

  deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    payload=$(jq -cn --arg client "$ZEROPS_CLIENT_ID" --arg project "$ZEROPS_PROJECT_ID" \
      '{
        search:[
          {name:"clientId",operator:"eq",value:$client},
          {name:"projectId",operator:"eq",value:$project}
        ],
        limit:20,timeZone:"UTC",
        groupBy:"serviceStackId",timeGroupBy:"1m"
      }')
    if api_request_file POST /stats-history/group-by-search "$payload" "$response"; then
      actual_count=$(jq --slurpfile expected "$expected_ids" --argjson fresh_after "$fresh_after" '
        [.items[]?
          | select(.serviceStackId as $id | $expected[0] | index($id))
          | select(try ((.till | fromdateiso8601) >= $fresh_after) catch false)
          | select(
              (.cpuLimit | type) == "number" and (.cpuUsed | type) == "number"
              and (.ramLimit | type) == "number" and (.ramUsed | type) == "number"
            )
          | .serviceStackId]
        | unique | length
      ' "$response")
      if (( actual_count == expected_count )); then
        jq --slurpfile expected "$expected_ids" '{
          groupBy,timeGroupBy,from,till,
          items:[.items[]
            | select(.serviceStackId as $id | $expected[0] | index($id))
            | {from,till,serviceStackId,containerCount,cpuLimit,cpuUsed,vCpuLimit,vCpuUsed,ramLimit,ramUsed,diskLimit,diskUsed}]
        }' "$response" >"$artifact_dir/zerops-runtime-statistics.json"
        break
      fi
    fi
    sleep 10
  done
  (( actual_count == expected_count )) \
    || die "fresh Zerops CPU/RAM statistics were unavailable for all $expected_count runtime services"

  if [[ "$BACKUP_ENABLED" == true ]]; then
    backup_id=$(jq -er --arg name "$BACKUP_HOSTNAME" '.list[] | select(.name == $name) | .id' "$inventory")
    backup_status=$(jq -er --arg name "$BACKUP_HOSTNAME" '.list[] | select(.name == $name) | .status' "$inventory")
    backup_usage=$(mktemp)
    api_request_file GET "/service-stack/${backup_id}/object-storage-size" '' "$backup_usage"
    backup_quota=$(zcli project env -P "$ZEROPS_PROJECT_ID" \
      --template '{{if eq .Key "k8sbackups_quotaGBytes"}}{{.Value}}{{end}}' 2>/dev/null \
      | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '"[:space:]')
    [[ "$backup_quota" =~ ^[0-9]+$ && "$backup_quota" -gt 0 ]] \
      || die 'production backup quota was unavailable in the resolved Zerops environment'
    jq --arg service "$BACKUP_HOSTNAME" --arg status "$backup_status" \
      --argjson quotaGBytes "$backup_quota" \
      '{service:$service,status:$status,quotaGBytes:$quotaGBytes,diskGBytesUsed,objects}' \
      "$backup_usage" >"$artifact_dir/zerops-backup-storage.json"
    rm -f "$backup_usage"
  fi
  rm -f "$inventory" "$expected_ids" "$response"
}

verify_security_controls() {
  local sentinel raw_file audit_marker audit_selector
  sentinel="zerops-encryption-proof-${GITHUB_RUN_ID:-local}-$(date +%s)"
  kubectl -n workloads create secret generic encryption-proof --from-literal="sentinel=$sentinel" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  raw_file=$(mktemp)
  kubectl -n kube-system exec "etcd-${CONTROL_PLANES[0]}" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/workloads/encryption-proof --print-value-only \
    >"$raw_file"
  ! grep -aFq "$sentinel" "$raw_file" || die 'Kubernetes Secret plaintext was visible in etcd'
  rm -f "$raw_file"
  jq -n '{encryptedAtRest:true}' >"$artifact_dir/encryption-at-rest.json"
  kubectl -n workloads delete secret encryption-proof --wait=true >/dev/null

  audit_marker="zerops-audit-${GITHUB_RUN_ID:-local}-$(date +%s)"
  audit_selector=$(jq -rn --arg value "zerops-audit-marker=$audit_marker" '$value | @uri')
  kubectl get --raw="/api/v1/namespaces?labelSelector=$audit_selector" >/dev/null
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: audit-proof-reader, namespace: kube-system}
spec:
  restartPolicy: Never
  nodeName: ${CONTROL_PLANES[0]}
  automountServiceAccountToken: false
  containers:
    - name: reader
      image: busybox:1.37.0
      command: [sh, -ec, "sleep 2; grep -F '$audit_marker' /audit/audit.log >/dev/null"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true, runAsUser: 0}
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
      volumeMounts: [{name: audit, mountPath: /audit, readOnly: true}]
  volumes:
    - name: audit
      hostPath: {path: /var/log/kubernetes/audit, type: Directory}
YAML
  kubectl -n kube-system wait pod/audit-proof-reader --for=jsonpath='{.status.phase}'=Succeeded --timeout=3m
  jq -n --arg marker "$audit_marker" '{auditEventFound:true,marker:$marker}' >"$artifact_dir/audit-proof.json"
  kubectl -n kube-system delete pod/audit-proof-reader --wait=true >/dev/null

  ! kubectl auth can-i get secrets --as=system:serviceaccount:default:default \
    | grep -qx yes || die 'default service account can read Secrets'
  cat <<'YAML' >"$artifact_dir/psa-negative.yaml"
apiVersion: v1
kind: Pod
metadata: {name: forbidden-privileged, namespace: workloads}
spec:
  containers:
    - name: forbidden
      image: busybox:1.37.0
      command: [sleep, "60"]
      securityContext: {privileged: true}
YAML
  if kubectl apply --server-side --dry-run=server -f "$artifact_dir/psa-negative.yaml" \
    >"$artifact_dir/psa-negative-result.txt" 2>&1; then
    die 'Pod Security Admission accepted a privileged workload pod'
  fi
  rm -f "$artifact_dir/psa-negative.yaml"
  kubectl -n workloads get networkpolicy default-deny allow-required-traffic -o yaml \
    >"$artifact_dir/network-policies.yaml"
}

run_node_recovery_tests() {
  local victim=${WORKERS[0]} deadline victim_pod survivor_uid rescheduled_pod
  if profile_capability workerDisruption; then
    victim_pod=$(kubectl -n workloads get pods -l app=demo -o json \
      | jq -er --arg victim "$victim" \
        '[.items[] | select(.spec.nodeName == $victim) | .metadata.name][0]')
    survivor_uid=$(kubectl -n workloads get pods -l app=demo -o json \
      | jq -er --arg victim "$victim" \
        '[.items[] | select(.spec.nodeName != $victim) | .metadata.uid][0]')
    log "disrupting worker $victim and proving the demo reschedules without ingress loss"
    restore_nodes+=("$victim")
    agent_request "$victim" POST /v1/node/stop >/dev/null
    wait_node_unready "$victim"
    deadline=$((SECONDS + 900))
    rescheduled_pod=''
    until [[ -n "$rescheduled_pod" ]] \
      && [[ $(kubectl -n workloads get deployment demo -o jsonpath='{.status.availableReplicas}') -ge 2 ]] \
      && http_probe "http://${VRRP_VIP}:8080/healthz" >/dev/null; do
      (( SECONDS < deadline )) \
        || die 'the demo did not reschedule with ingress available after a compact-production worker failure'
      rescheduled_pod=$(kubectl -n workloads get pods -l app=demo -o json \
        | jq -r --arg victim "$victim" --arg survivor_uid "$survivor_uid" '
          [.items[]
            | select(.spec.nodeName != $victim and .metadata.uid != $survivor_uid)
            | select(any(.status.containerStatuses[]?; .ready == true))
            | .metadata.name][0] // ""
        ')
      sleep 5
    done
    agent_request "$victim" POST /v1/node/start >/dev/null
    kubectl wait "node/$victim" --for=condition=Ready --timeout=10m
    wait_node_dataplane_ready "$victim"
    recover_terminating_node_pods "$victim"
    kubectl -n workloads delete pod "$rescheduled_pod" --wait=false >/dev/null
    deadline=$((SECONDS + 600))
    until [[ $(kubectl -n workloads get pods -l app=demo -o json | jq '
      [.items[] | select(any(.status.containerStatuses[]?; .ready == true)) | .spec.nodeName]
      | unique | length
    ') -eq 2 ]]; do
      (( SECONDS < deadline )) || die 'demo replicas did not rebalance after the disrupted worker recovered'
      sleep 5
    done
    wait_longhorn_healthy
    jq -n --arg node "$victim" --arg evictedPod "$victim_pod" --arg replacementPod "$rescheduled_pod" \
      '{node:$node,evictedPod:$evictedPod,replacementPod:$replacementPod,rescheduled:true,ingressPreserved:true,rebalanced:true}' \
      >"$artifact_dir/worker-disruption.json"
    restore_nodes=()
    return
  fi

  log "restarting staging worker $victim; a data-plane outage is expected"
  restore_nodes+=("$victim")
  agent_request "$victim" POST /v1/node/stop >/dev/null
  wait_node_unready "$victim"
  agent_request "$victim" POST /v1/node/start >/dev/null
  kubectl wait "node/$victim" --for=condition=Ready --timeout=10m
  wait_node_dataplane_ready "$victim"
  recover_terminating_node_pods "$victim"
  restore_nodes=()
  jq -n --arg node "$victim" '{node:$node,outageExpected:true,recovered:true}' \
    >"$artifact_dir/staging-worker-recovery.json"

  log "restarting staging control plane ${CONTROL_PLANES[0]}; an API outage is expected"
  restore_nodes+=("${CONTROL_PLANES[0]}")
  agent_request "${CONTROL_PLANES[0]}" POST /v1/node/stop >/dev/null
  agent_request "${CONTROL_PLANES[0]}" POST /v1/node/start >/dev/null
  deadline=$((SECONDS + 600))
  until kubectl get --raw=/readyz >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die 'staging API did not recover after the control-plane restart'
    sleep 3
  done
  kubectl wait "node/${CONTROL_PLANES[0]}" --for=condition=Ready --timeout=10m
  wait_node_dataplane_ready "${CONTROL_PLANES[0]}"
  restore_nodes=()
  jq -n --arg node "${CONTROL_PLANES[0]}" '{node:$node,apiOutageExpected:true,recovered:true}' \
    >"$artifact_dir/staging-control-plane-recovery.json"
}

log "validating exact Zerops service inventory for $K8S_PROFILE"
assert_profile_service_inventory

log 'validating repository manifests'
kubeconform -strict -summary -ignore-missing-schemas \
  -ignore-filename-pattern '.*-values\.yaml$' "$ROOT_DIR/kubernetes" \
  | tee "$artifact_dir/kubeconform.txt"

expected_control_planes=${#CONTROL_PLANES[@]}
expected_workers=${#WORKERS[@]}
expected_nodes=${#NODES[@]}
log "checking the resolved ${expected_control_planes}+${expected_workers} topology"
"$ROOT_DIR/scripts/verify-vrrp-api.sh" "$artifact_dir/vrrp-api-certificate.txt"
"$ROOT_DIR/scripts/verify-in-project-vrrp.sh" "$artifact_dir/vrrp-in-project-readyz.txt"
kubectl get nodes -o wide | tee "$artifact_dir/nodes.txt"
[[ $(kubectl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length') -eq "$expected_nodes" ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l) -eq "$expected_control_planes" ]]
[[ $(kubectl get nodes -l node-role.kubernetes.io/worker -o name | wc -l) -eq "$expected_workers" ]]
kubectl wait --for=condition=Ready nodes --all --timeout=5m
wait_all_workload_pods_ready
kubectl get pods -A -o wide | tee "$artifact_dir/pods.txt"
kubectl get --raw=/readyz?verbose | tee "$artifact_dir/apiserver-readyz.txt"

forbidden_namespaces=(istio-system istio-ingress cert-manager headlamp observability)
forbidden_crds=(peerauthentications.security.istio.io certificates.cert-manager.io)
for namespace in "${forbidden_namespaces[@]}"; do assert_absent_namespace "$namespace"; done
for crd in "${forbidden_crds[@]}"; do assert_absent_crd "$crd"; done
if [[ $(profile_json '.addons.storage') == none ]]; then
  assert_absent_namespace longhorn-system
  assert_absent_crd volumes.longhorn.io
  forbidden_namespaces+=(longhorn-system)
  forbidden_crds+=(volumes.longhorn.io)
else
  kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=10m
  [[ $(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}') == 2 ]]
  [[ $(kubectl -n longhorn-system get deployment longhorn-ui -o jsonpath='{.spec.replicas}') == 0 ]]
fi
helm list -A -o json | jq --arg profile "$K8S_PROFILE" '
  {profile:$profile,releases:[.[] | {name,namespace,status,chart}]}
' >"$artifact_dir/helm-releases.json"
if jq -e '[.releases[] | select(.name | IN("istiod","istio-base","cert-manager","alloy","fluent-bit","kube-state-metrics","node-exporter"))] | length > 0' \
  "$artifact_dir/helm-releases.json" >/dev/null; then
  die 'a forbidden dedicated component Helm release exists'
fi
jq -n --arg profile "$K8S_PROFILE" \
  --arg namespaces "$(IFS=,; printf '%s' "${forbidden_namespaces[*]}")" \
  --arg crds "$(IFS=,; printf '%s' "${forbidden_crds[*]}")" \
  '{profile:$profile,passed:true,absentNamespaces:($namespaces|split(",")),absentCrds:($crds|split(",")),absentHelmReleases:["istiod","istio-base","cert-manager","alloy","fluent-bit","kube-state-metrics","node-exporter"]}' \
  >"$artifact_dir/forbidden-components.json"

[[ $(kubectl -n traefik-system get deployment traefik -o jsonpath='{.spec.replicas}') -eq $(profile_json '.addons.gatewayReplicas') ]]
[[ $(kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.replicas}') -eq $(profile_json '.addons.metricsServerReplicas') ]]
kubectl -n traefik-system wait --for=condition=Programmed gateway/public-gateway --timeout=5m
kubectl -n workloads wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
  httproute/demo --timeout=5m

if [[ "$K8S_PROFILE" == production ]]; then
  [[ $(kubectl -n workloads get deployment demo -o jsonpath='{.spec.replicas}') -eq 2 ]]
  [[ $(kubectl -n workloads get pods -l app=demo -o json | jq '[.items[].spec.nodeName] | unique | length') -eq 2 ]]
  [[ $(kubectl -n traefik-system get pods -l app.kubernetes.io/name=traefik -o json \
    | jq '[.items[].spec.nodeName] | unique | length') -eq 2 ]]
  kubectl -n workloads wait \
    --for=jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}'=True \
    horizontalpodautoscaler/demo --timeout=5m
  kubectl -n workloads get poddisruptionbudget/demo -o json \
    | jq -e '.spec.minAvailable == 1 and .status.currentHealthy >= 2 and .status.disruptionsAllowed >= 1' >/dev/null
  kubectl -n workloads get resourcequota/workload-budget -o json \
    | jq -e '.status.hard == {
      "requests.cpu":"2", "requests.memory":"2Gi",
      "limits.cpu":"4", "limits.memory":"4Gi", "pods":"30"
    }' >/dev/null
  kubectl -n workloads get limitrange/workload-defaults -o json \
    | jq -e '.spec.limits[0].defaultRequest == {"cpu":"25m","memory":"32Mi"}
      and .spec.limits[0].default == {"cpu":"250m","memory":"128Mi"}' >/dev/null
  kubectl -n workloads get poddisruptionbudget/demo horizontalpodautoscaler/demo resourcequota/workload-budget limitrange/workload-defaults \
    -o yaml >"$artifact_dir/workload-controls.yaml"
  http_probe "http://${VRRP_VIP}:8080/healthz" | tee "$artifact_dir/ingress.txt"
else
  [[ $(kubectl -n workloads get deployment demo -o jsonpath='{.spec.replicas}') -eq 1 ]]
  if kubectl -n workloads get poddisruptionbudget/demo >/dev/null 2>&1; then
    die 'staging unexpectedly contains a demo PodDisruptionBudget'
  fi
  if kubectl -n workloads get horizontalpodautoscaler/demo >/dev/null 2>&1; then
    die 'staging unexpectedly contains a demo HorizontalPodAutoscaler'
  fi
  kubectl -n workloads get resourcequota/workload-budget -o json \
    | jq -e '.status.hard == {
      "requests.cpu":"1", "requests.memory":"1Gi",
      "limits.cpu":"2", "limits.memory":"2Gi", "pods":"15"
    }' >/dev/null
  kubectl -n workloads get limitrange/workload-defaults -o json \
    | jq -e '.spec.limits[0].defaultRequest == {"cpu":"25m","memory":"32Mi"}
      and .spec.limits[0].default == {"cpu":"250m","memory":"128Mi"}' >/dev/null
  kubectl -n workloads get resourcequota/workload-budget limitrange/workload-defaults \
    -o yaml >"$artifact_dir/workload-controls.yaml"
  http_probe "http://${VRRP_VIP}:8080/healthz" | tee "$artifact_dir/ingress.txt"
fi
wait_metrics_api

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
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true, runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532}
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
YAML
cleanup_objects+=(daemonset/network-proof)
kubectl -n workloads rollout status daemonset/network-proof --timeout=10m
mapfile -t proof_pods < <(kubectl -n workloads get pods -l app=network-proof -o json | jq -r '.items | sort_by(.spec.nodeName)[] | .metadata.name')
[[ ${#proof_pods[@]} -eq "$expected_workers" ]]
kubectl -n workloads exec "${proof_pods[0]}" -- getent hosts kubernetes.default.svc.cluster.local \
  | tee "$artifact_dir/dns.txt"
if (( expected_workers > 1 )); then
  target_ip=$(kubectl -n workloads get pod "${proof_pods[1]}" -o jsonpath='{.status.podIP}')
  kubectl -n workloads exec "${proof_pods[0]}" -- \
    /agnhost connect --timeout=10s "$target_ip:8080"
  jq -n --arg source "${proof_pods[0]}" --arg target "$target_ip:8080" \
    '{sourcePod:$source,target:$target,tcpConnected:true}' >"$artifact_dir/cross-node-network.json"
else
  kubectl -n workloads exec "${proof_pods[0]}" -- \
    /agnhost connect --timeout=10s demo.workloads.svc.cluster.local:8080
  jq -n --arg source "${proof_pods[0]}" \
    '{sourcePod:$source,target:"demo.workloads.svc.cluster.local:8080",tcpConnected:true}' \
    >"$artifact_dir/service-network.json"
fi

if kubectl -n workloads exec "${proof_pods[0]}" -- \
  /agnhost connect --timeout=5s kubernetes.default.svc.cluster.local:443 >/dev/null 2>&1; then
  die 'workload default-deny NetworkPolicy permitted access to the Kubernetes API Service'
fi
jq -n '{sourceNamespace:"workloads",target:"kubernetes.default.svc.cluster.local:443",denied:true}' \
  >"$artifact_dir/network-policy-negative.json"

verify_security_controls
if [[ "${SKIP_DISRUPTION_TESTS:-false}" != true ]]; then
  run_node_recovery_tests
fi
wait_all_workload_pods_ready
collect_platform_log_evidence
collect_platform_stats_evidence

log 'running report-only Kubescape scan'
kubescape_raw=${RUNNER_TEMP:-$ROOT_DIR/artifacts}/kubescape-raw.json
kubescape scan framework nsa,mitre,cis-v1.10.0 --format json --output "$kubescape_raw" || true
if [[ -s "$kubescape_raw" ]]; then
  jq 'del(.resources)' "$kubescape_raw" >"$artifact_dir/kubescape.json"
else
  jq -n '{scanStatus:"report unavailable"}' >"$artifact_dir/kubescape.json"
fi
rm -f "$kubescape_raw"

if [[ "$K8S_PROFILE" == production ]]; then
  mode=quick
  [[ "${RUN_FULL_CONFORMANCE:-false}" != true ]] || mode=certified-conformance
  log "running Sonobuoy $mode mode"
  sonobuoy delete --wait >/dev/null 2>&1 || true
  sonobuoy run --mode "$mode" --wait
  sonobuoy retrieve "$artifact_dir"
  result=$(find "$artifact_dir" -maxdepth 1 \( -name '*sonobuoy*.tar.gz' -o -name '*.tar.gz' \) | head -n1)
  [[ -n "$result" ]] || die 'Sonobuoy result archive was not created'
  sonobuoy results "$result" | tee "$artifact_dir/sonobuoy-results.txt"
  grep -q 'Status: passed' "$artifact_dir/sonobuoy-results.txt" || die 'Sonobuoy did not pass'
  rm -f "$result"
  sonobuoy delete >/dev/null 2>&1 || true
fi

recover_all_terminating_pods 60
kubectl wait --for=delete namespace/sonobuoy --timeout=3m 2>/dev/null || true
wait_all_workload_pods_ready
kubectl get pods -A -o wide | tee "$artifact_dir/pods-final.txt"
kubectl version -o yaml >"$artifact_dir/kubernetes-version.yaml"
kubectl get gateways,httproutes -A -o yaml >"$artifact_dir/gateway-api.yaml"
kubectl get storageclass,pv,pvc -A -o yaml >"$artifact_dir/storage.yaml"
kubectl -n workloads delete daemonset/network-proof --ignore-not-found >/dev/null
cleanup_objects=()
log "all requested $K8S_PROFILE acceptance checks passed"
