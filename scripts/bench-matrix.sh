#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Helpers
# ----------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

run_with_timeout() {
  local duration="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$duration" "$@"
  else
    "$@"
  fi
}

kube() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

kube_exec() {
  run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec "$@"
}

duration_seconds() {
  "$PYTHON_BIN" -c '
import re, sys
text = sys.argv[1]
total = 0.0
for num, unit in re.findall(r"([0-9]*\.?[0-9]+)(ms|s|m|h)", text):
    v = float(num)
    if unit == "ms":
        total += v / 1000.0
    elif unit == "s":
        total += v
    elif unit == "m":
        total += v * 60.0
    elif unit == "h":
        total += v * 3600.0
print(int(total))
' "$1"
}

# ----------------------------
# Config (env overrides)
# ----------------------------
NAMESPACE="$(trim "${NAMESPACE:-txlab}")"
DEPLOYMENT="$(trim "${DEPLOYMENT:-order}")"

ORDER_BASE_URL="$(trim "${ORDER_BASE_URL:-http://127.0.0.1:8080}")"

RESULTS_DIR="$(trim "${RESULTS_DIR:-results}")"
LOCK_FILE="$(trim "${LOCK_FILE:-${RESULTS_DIR}/bench-matrix.lock}")"
CONCURRENCY="$(trim "${CONCURRENCY:-20}")"
CONCURRENCY_LIST_STR="$(trim "${CONCURRENCY_LIST:-}")"
REPLICAS_LIST_STR="$(trim "${REPLICAS_LIST:-}")"
TX_COUNTS_LIST_STR="$(trim "${TX_COUNTS_LIST:-}")"
BENCH_LOG_DIR="$(trim "${BENCH_LOG_DIR:-${RESULTS_DIR}/bench-logs}")"
BENCH_RUNS_PER_POINT="$(trim "${BENCH_RUNS_PER_POINT:-3}")"
WARMUP_TX="$(trim "${WARMUP_TX:-100}")"
WARMUP_CONCURRENCY="$(trim "${WARMUP_CONCURRENCY:-$CONCURRENCY}")"
WARMUP_ENABLED="$(trim "${WARMUP_ENABLED:-1}")"
INVALID_RETRY_LIMIT="$(trim "${INVALID_RETRY_LIMIT:-2}")"
INVALID_RETRY_SLEEP="$(trim "${INVALID_RETRY_SLEEP:-3}")"
BENCH_IN_CLUSTER="$(trim "${BENCH_IN_CLUSTER:-1}")"
BENCH_RUNNER_IMAGE="$(trim "${BENCH_RUNNER_IMAGE:-busybox:1.36}")"
BENCH_RUNNER_POD_PREFIX="$(trim "${BENCH_RUNNER_POD_PREFIX:-bench-runner}")"
BENCH_RUNNER_KEEP_POD="$(trim "${BENCH_RUNNER_KEEP_POD:-0}")"
BENCH_RUNNER_READY_TIMEOUT="$(trim "${BENCH_RUNNER_READY_TIMEOUT:-120s}")"
BENCH_RUNNER_GOOS="$(trim "${BENCH_RUNNER_GOOS:-}")"
BENCH_RUNNER_GOARCH="$(trim "${BENCH_RUNNER_GOARCH:-}")"

# TX modes
TX_MODES_STR="$(trim "${TX_MODES:-}")"
TX_MODES_DEFAULT=("twopc" "saga-orch" "saga-chor" "tcc" "outbox")

# Network profiles
NET_PROFILES_STR="$(trim "${NET_PROFILES:-}")"
NET_PROFILES_DEFAULT=("normal" "lossy" "congested")

REPLICAS_LIST=(1 3 5 7 10)
TX_COUNTS=(5000)
LATENCIES_MS=(10)
JITTERS_MS=(2)

# Network profile parameters
LOSSY_LOSS_PCT="$(trim "${LOSSY_LOSS_PCT:-1}")"
LOSSY_DUP_PCT="$(trim "${LOSSY_DUP_PCT:-0.1}")"
LOSSY_REORDER_PCT="$(trim "${LOSSY_REORDER_PCT:-0.1}")"
LOSSY_REORDER_CORR="$(trim "${LOSSY_REORDER_CORR:-25}")"

CONGEST_DELAY_MS="$(trim "${CONGEST_DELAY_MS:-80}")"
CONGEST_JITTER_MS="$(trim "${CONGEST_JITTER_MS:-20}")"
CONGEST_RATE="$(trim "${CONGEST_RATE:-20mbit}")"
CONGEST_BURST="$(trim "${CONGEST_BURST:-32kb}")"
CONGEST_LIMIT_PKTS="$(trim "${CONGEST_LIMIT_PKTS:-10000}")"
CONGEST_LOSS_PCT="$(trim "${CONGEST_LOSS_PCT:-0.2}")"

# Port-forward management
MANAGE_ORDER_PF="${MANAGE_ORDER_PF:-1}"
ORDER_PF_ADDR="$(trim "${ORDER_PF_ADDR:-127.0.0.1}")"
ORDER_PF_PORT="$(trim "${ORDER_PF_PORT:-8080}")"
ORDER_PF_MODE="$(trim "${ORDER_PF_MODE:-pods}")"
ORDER_PF_LOG_DIR="$(trim "${ORDER_PF_LOG_DIR:-${RESULTS_DIR}/pf-logs}")"

# Timeouts
ROLLOUT_TIMEOUT="$(trim "${ROLLOUT_TIMEOUT:-5m}")"
PODS_READY_TIMEOUT_SECONDS="$(trim "${PODS_READY_TIMEOUT_SECONDS:-300}")"
WAIT_AFTER_NETEM="$(trim "${WAIT_AFTER_NETEM:-1}")"

KUBECTL_REQUEST_TIMEOUT="$(trim "${KUBECTL_REQUEST_TIMEOUT:-30s}")"
KUBECTL_EXEC_TIMEOUT="$(trim "${KUBECTL_EXEC_TIMEOUT:-20s}")"
KUBECTL_TOP_TIMEOUT="$(trim "${KUBECTL_TOP_TIMEOUT:-20s}")"

BENCH_RUN_TIMEOUT="$(trim "${BENCH_RUN_TIMEOUT:-120m}")"
BENCH_REQUEST_TIMEOUT="$(trim "${BENCH_REQUEST_TIMEOUT:-120s}")"
HEARTBEAT_INTERVAL="$(trim "${HEARTBEAT_INTERVAL:-3}")"

SMOKE="${SMOKE:-0}"
READINESS_DEPLOYMENTS_STR="$(trim "${READINESS_DEPLOYMENTS:-}")"
READY_HTTP_PATH="$(trim "${READY_HTTP_PATH:-/health}")"
READY_HTTP_RETRIES="$(trim "${READY_HTTP_RETRIES:-40}")"
READY_HTTP_SLEEP="$(trim "${READY_HTTP_SLEEP:-0.5}")"
READY_CHECKOUT_RETRIES="$(trim "${READY_CHECKOUT_RETRIES:-20}")"
READY_CHECKOUT_SLEEP="$(trim "${READY_CHECKOUT_SLEEP:-0.5}")"
READY_CHECKOUT_BODY="$(trim "${READY_CHECKOUT_BODY:-}")"

AWAIT_FINAL="$(trim "${AWAIT_FINAL:-0}")"
FINAL_TIMEOUT="$(trim "${FINAL_TIMEOUT:-2m}")"
FINAL_INTERVAL="$(trim "${FINAL_INTERVAL:-500ms}")"
FINAL_STATUSES="$(trim "${FINAL_STATUSES:-CONFIRMED,COMMITTED}")"

NETEM_TARGET_SELECTORS_STR="$(trim "${NETEM_TARGET_SELECTORS:-}")"
NETEM_VALIDATE="$(trim "${NETEM_VALIDATE:-1}")"
NETEM_VALIDATE_LOG_DIR="$(trim "${NETEM_VALIDATE_LOG_DIR:-${RESULTS_DIR}/netem-validate}")"
NETEM_REQUIRE_TC="$(trim "${NETEM_REQUIRE_TC:-1}")"
NETEM_CONTAINER="$(trim "${NETEM_CONTAINER:-netem}")"
NETEM_TARGETS_FROM_PROBE="$(trim "${NETEM_TARGETS_FROM_PROBE:-1}")"

PROBE_SERVICES_STR="$(trim "${PROBE_SERVICES:-}")"
PROBE_SERVICE_HOSTS_STR="$(trim "${PROBE_SERVICE_HOSTS:-}")"
PROBE_IMAGE="$(trim "${PROBE_IMAGE:-busybox:1.36}")"

METRICS_SELECTORS_STR="$(trim "${METRICS_SELECTORS:-}")"
METRICS_SAMPLE_INTERVAL="$(trim "${METRICS_SAMPLE_INTERVAL:-2}")"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi

# ----------------------------
# Tools
# ----------------------------
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3/python not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v go >/dev/null 2>&1 || die "go not found in PATH"

if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
  MANAGE_ORDER_PF=0
fi

# ----------------------------
# Validate basics
# ----------------------------
[[ -n "$NAMESPACE" ]] || die "NAMESPACE is empty"
kube get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' not found"

mkdir -p "$RESULTS_DIR" "$ORDER_PF_LOG_DIR" "$BENCH_LOG_DIR" "$NETEM_VALIDATE_LOG_DIR"

# ----------------------------
# Lock
# ----------------------------
exec {LOCK_FD}>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
if ! flock -n "$LOCK_FD"; then
  die "bench-matrix already running (lock: $LOCK_FILE)"
fi

# ----------------------------
# Resolve deployment name
# ----------------------------
deployment_exists() {
  kube get deployment "$1" -n "$NAMESPACE" >/dev/null 2>&1
}

list_deployments() {
  kube get deploy -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

resolve_deployment() {
  local wanted="$1"
  if deployment_exists "$wanted"; then
    printf '%s' "$wanted"
    return 0
  fi
  local cand
  cand="$(list_deployments | grep -F "${wanted}-service" | head -n1 || true)"
  if [[ -n "${cand//[[:space:]]/}" ]] && deployment_exists "$cand"; then
    printf '%s' "$cand"
    return 0
  fi
  cand="$(list_deployments | grep -F "$wanted" | grep -v postgres | head -n1 || true)"
  if [[ -n "${cand//[[:space:]]/}" ]] && deployment_exists "$cand"; then
    printf '%s' "$cand"
    return 0
  fi
  return 1
}

REAL_DEPLOYMENT="$(resolve_deployment "$DEPLOYMENT" || true)"
if [[ -z "${REAL_DEPLOYMENT//[[:space:]]/}" ]]; then
  echo "ERROR: deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'." >&2
  exit 1
fi
DEPLOYMENT="$REAL_DEPLOYMENT"
log "Using deployment: $DEPLOYMENT"

# ----------------------------
# Derive label selector
# ----------------------------
LABEL_SELECTOR="$(
  kube get deploy "$DEPLOYMENT" -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
import json,sys
d=json.load(sys.stdin)
ml=(d.get("spec",{}).get("selector",{}) or {}).get("matchLabels") or {}
print(",".join([f"{k}={v}" for k,v in ml.items()]))
'
)"
[[ -n "${LABEL_SELECTOR//[[:space:]]/}" ]] || die "cannot derive LABEL_SELECTOR"
log "Pod selector: $LABEL_SELECTOR"

# ----------------------------
# Resolve Service
# ----------------------------
ORDER_SERVICE_NAME="$(
  kube get svc -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
import json,sys
label_selector = sys.argv[1].strip()
want = {}
for part in label_selector.split(","):
    if "=" in part:
        k,v = part.split("=",1)
        want[k] = v
data = json.load(sys.stdin)
for s in data.get("items", []):
    sel = (s.get("spec") or {}).get("selector") or {}
    if sel == want:
        print((s.get("metadata") or {}).get("name",""))
        sys.exit(0)
print("")
' "$LABEL_SELECTOR"
)"

ORDER_SERVICE_NAME="$(trim "${ORDER_SERVICE_NAME_OVERRIDE:-$ORDER_SERVICE_NAME}")"

if [[ -z "${ORDER_SERVICE_NAME//[[:space:]]/}" ]]; then
  if kube get svc -n "$NAMESPACE" "$DEPLOYMENT" >/dev/null 2>&1; then
    ORDER_SERVICE_NAME="$DEPLOYMENT"
  else
    die "cannot resolve Service for deployment '$DEPLOYMENT'. Set ORDER_SERVICE_NAME_OVERRIDE."
  fi
fi

log "Using service for order port-forward: $ORDER_SERVICE_NAME"

# ----------------------------
# Parsing Arrays
# ----------------------------
# shellcheck disable=SC2206
if [[ -n "${TX_MODES_STR//[[:space:]]/}" ]]; then TX_MODES=($TX_MODES_STR); else TX_MODES=("${TX_MODES_DEFAULT[@]}"); fi
# shellcheck disable=SC2206
if [[ -n "${NET_PROFILES_STR//[[:space:]]/}" ]]; then NET_PROFILES=($NET_PROFILES_STR); else NET_PROFILES=("${NET_PROFILES_DEFAULT[@]}"); fi
# shellcheck disable=SC2206
if [[ -n "${CONCURRENCY_LIST_STR//[[:space:]]/}" ]]; then CONCURRENCY_LIST=($CONCURRENCY_LIST_STR); else CONCURRENCY_LIST=("$CONCURRENCY"); fi
# shellcheck disable=SC2206
if [[ -n "${REPLICAS_LIST_STR//[[:space:]]/}" ]]; then REPLICAS_LIST=($REPLICAS_LIST_STR); fi
# shellcheck disable=SC2206
if [[ -n "${TX_COUNTS_LIST_STR//[[:space:]]/}" ]]; then TX_COUNTS=($TX_COUNTS_LIST_STR); fi
# shellcheck disable=SC2206
if [[ -n "${READINESS_DEPLOYMENTS_STR//[[:space:]]/}" ]]; then READINESS_DEPLOYMENTS=($READINESS_DEPLOYMENTS_STR); else READINESS_DEPLOYMENTS=("$DEPLOYMENT"); fi

NETEM_TARGET_SELECTORS=()
if [[ -n "${NETEM_TARGET_SELECTORS_STR//[[:space:]]/}" ]]; then
  if [[ "$NETEM_TARGET_SELECTORS_STR" == *";"* ]]; then
    IFS=';' read -r -a NETEM_TARGET_SELECTORS <<<"$NETEM_TARGET_SELECTORS_STR"
  else
    # shellcheck disable=SC2206
    NETEM_TARGET_SELECTORS=($NETEM_TARGET_SELECTORS_STR)
  fi
else
  NETEM_TARGET_SELECTORS=("$LABEL_SELECTOR")
fi

METRICS_SELECTORS=()
if [[ -n "${METRICS_SELECTORS_STR//[[:space:]]/}" ]]; then
  if [[ "$METRICS_SELECTORS_STR" == *";"* ]]; then
    IFS=';' read -r -a METRICS_SELECTORS <<<"$METRICS_SELECTORS_STR"
  else
    # shellcheck disable=SC2206
    METRICS_SELECTORS=($METRICS_SELECTORS_STR)
  fi
else
  METRICS_SELECTORS=("$LABEL_SELECTOR")
fi

PROBE_SERVICES=()
PROBE_SERVICE_HOSTS=()
# shellcheck disable=SC2206
if [[ -n "${PROBE_SERVICES_STR//[[:space:]]/}" ]]; then PROBE_SERVICES=($PROBE_SERVICES_STR); fi
# shellcheck disable=SC2206
if [[ -n "${PROBE_SERVICE_HOSTS_STR//[[:space:]]/}" ]]; then PROBE_SERVICE_HOSTS=($PROBE_SERVICE_HOSTS_STR); fi

# Probe inference
if [[ ${#PROBE_SERVICES[@]} -eq 0 && ${#PROBE_SERVICE_HOSTS[@]} -eq 0 && "$NETEM_VALIDATE" == "1" ]]; then
  PROBE_SERVICES=("$ORDER_SERVICE_NAME")
  if [[ "$ORDER_SERVICE_NAME" == *"-order-service" ]]; then
    prefix="${ORDER_SERVICE_NAME%-order-service}"
    for s in inventory-service payment-service shipping-service; do
      cand="${prefix}-${s}"
      if kubectl get svc -n "$NAMESPACE" "$cand" >/dev/null 2>&1; then
        PROBE_SERVICES+=("$cand")
      fi
    done
  fi
fi

# Netem selectors inference
if [[ -z "${NETEM_TARGET_SELECTORS_STR//[[:space:]]/}" && "$NETEM_TARGETS_FROM_PROBE" == "1" && ${#PROBE_SERVICES[@]} -gt 0 ]]; then
  derived=()
  for svc in "${PROBE_SERVICES[@]}"; do
    if kubectl get pods -n "$NAMESPACE" -l "app=$svc" >/dev/null 2>&1; then
      derived+=("app=$svc")
    fi
  done
  if [[ ${#derived[@]} -gt 0 ]]; then
    NETEM_TARGET_SELECTORS=("${derived[@]}")
  fi
fi

# ----------------------------
# Build bench-runner
# ----------------------------
BENCH_BIN="${BENCH_BIN:-/tmp/bench-runner}"
if [[ -n "${BENCH_RUNNER_GOOS//[[:space:]]/}" || -n "${BENCH_RUNNER_GOARCH//[[:space:]]/}" ]]; then
  GOOS="${BENCH_RUNNER_GOOS:-$(go env GOOS)}" GOARCH="${BENCH_RUNNER_GOARCH:-$(go env GOARCH)}" \
    go build -o "$BENCH_BIN" ./cmd/bench-runner
else
  go build -o "$BENCH_BIN" ./cmd/bench-runner
fi
[[ -x "$BENCH_BIN" ]] || die "bench-runner binary not found at $BENCH_BIN"
if [[ "$BENCH_IN_CLUSTER" == "1" && -z "${BENCH_RUNNER_GOOS//[[:space:]]/}" ]]; then
  host_goos="$(go env GOOS)"
  if [[ "$host_goos" != "linux" ]]; then
    log "WARNING: BENCH_IN_CLUSTER=1 with host GOOS=$host_goos. Set BENCH_RUNNER_GOOS=linux and BENCH_RUNNER_GOARCH to match your nodes."
  fi
fi

# ----------------------------
# Output setup
# ----------------------------
timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
json_file="$RESULTS_DIR/benchmarks-$timestamp.json"
md_file="$RESULTS_DIR/benchmarks-$timestamp.md"

cat <<HEADER > "$md_file"
# Benchmark results ($timestamp)
* Namespace: $NAMESPACE
* Deployment: $DEPLOYMENT
* Service: $ORDER_SERVICE_NAME
* Selectors: ${NETEM_TARGET_SELECTORS[*]}

| TX mode | Net profile | Replicas | Concurrency | Run | Transactions | Latency (ms) | Jitter (ms) | Avg latency (ms) | P95 (ms) | P99 (ms) | Throughput (rps) | Errors | Error classes | Status counts | Finalized/Timeouts | First error | CPU avg/max (m) | Mem avg/max (Mi) | Net RX (KB/s) | Net TX (KB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER

echo "[" > "$json_file"
first_record=true

# ----------------------------
# K8s helpers
# ----------------------------
ensure_rollout() {
  kube -n "$NAMESPACE" rollout status "deployment/${DEPLOYMENT}" --timeout="$ROLLOUT_TIMEOUT"
}

selector_for_deploy() {
  local deployment="$1"
  kubectl get deploy "$deployment" -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
import json,sys
d=json.load(sys.stdin)
ml=(d.get("spec",{}).get("selector",{}) or {}).get("matchLabels") or {}
print(",".join([f"{k}={v}" for k,v in ml.items()]))
'
}

wait_pods_stable_for() {
  local selector="$1"
  local deployment="$2"
  local timeout_s="${3:-180}"
  local start
  start="$(date +%s)"

  while true; do
    local desired
    desired="$(kubectl -n "$NAMESPACE" get deploy "$deployment" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
    [[ -n "$desired" ]] || desired="1"

    local pods_json
    pods_json="$(kubectl -n "$NAMESPACE" get pods -l "$selector" -o json)"

    local status
    status="$(DESIRED="$desired" "$PYTHON_BIN" -c '
import json,sys,os
desired=int(os.environ.get("DESIRED","1"))
d=json.load(sys.stdin)
items=d.get("items",[])
active=[p for p in items if not (p.get("metadata",{}) or {}).get("deletionTimestamp")]
ready=0
for p in active:
    cs=(p.get("status",{}) or {}).get("containerStatuses") or []
    if cs and all(c.get("ready") for c in cs):
        ready += 1
if len(active)==desired and ready==desired:
    print("OK")
else:
    print(f"WAIT active={len(active)}/{desired} ready={ready}/{desired}")
' <<<"$pods_json")"

    if [[ "$status" == "OK" ]]; then
      return 0
    fi
    log "$status"
    if (( $(date +%s) - start > timeout_s )); then
      echo "ERROR: pods did not become stable in ${timeout_s}s" >&2
      return 1
    fi
    sleep 0.5
  done
}

wait_pods_stable() {
  wait_pods_stable_for "$LABEL_SELECTOR" "$DEPLOYMENT" "$PODS_READY_TIMEOUT_SECONDS"
}

scale_replicas() {
  local replicas="$1"
  kube -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$replicas" >/dev/null
  ensure_rollout
  wait_pods_stable
}

list_pods_for() {
  local selector="$1"
  local allow_empty="${2:-0}"
  local pods
  if ! pods="$(kube get pods -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; then
    die "kubectl get pods failed for selector '$selector'"
  fi
  if [[ -z "${pods//[[:space:]]/}" && "$NETEM_VALIDATE" == "1" && "$allow_empty" != "1" ]]; then
    die "no pods found for selector '$selector'"
  fi
  echo "$pods"
}

list_ready_pods_for() {
  local selector="$1"
  local pods_json
  pods_json="$(kube get pods -n "$NAMESPACE" -l "$selector" -o json)"
  "$PYTHON_BIN" -c '
import json,sys
d=json.load(sys.stdin)
items=d.get("items",[])
ready=[]
for p in items:
    meta=p.get("metadata",{}) or {}
    if meta.get("deletionTimestamp"):
        continue
    cs=(p.get("status",{}) or {}).get("containerStatuses") or []
    if cs and all(c.get("ready") for c in cs):
        ready.append(meta.get("name",""))
print(" ".join([p for p in ready if p]))
' <<<"$pods_json"
}

ensure_deploy_ready() {
  local deployment="$1"
  local selector="$2"
  kubectl -n "$NAMESPACE" rollout status "deployment/${deployment}" --timeout="$ROLLOUT_TIMEOUT"
  wait_pods_stable_for "$selector" "$deployment" "$PODS_READY_TIMEOUT_SECONDS"
}

wait_http_ready() {
  local base_url="$1"
  local path="$2"
  local retries="$3"
  local sleep_s="$4"
  if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
    ensure_bench_runner_pod
    local url="${base_url%/}${path}"
    for _ in $(seq 1 "$retries"); do
      if kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" exec "$BENCH_RUNNER_POD" -- sh -c "wget -q -O /dev/null '$url'"; then
        return 0
      fi
      sleep "$sleep_s"
    done
    return 1
  fi
  for _ in $(seq 1 "$retries"); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "${base_url%/}${path}" || echo "000")"
    if [[ "$code" == "200" ]]; then return 0; fi
    sleep "$sleep_s"
  done
  return 1
}

warmup_checkout() {
  local base_url="$1"
  local attempts="$2"
  local sleep_s="$3"
  if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
    local warmup_log="${BENCH_LOG_DIR}/warmup-ready-${timestamp}.log"
    for _ in $(seq 1 "$attempts"); do
      if run_bench_json "$base_url" 1 1 "$warmup_log" "ready" "ready" "ready" >/dev/null; then
        return 0
      fi
      sleep "$sleep_s"
    done
    return 1
  fi
  for _ in $(seq 1 "$attempts"); do
    local order_id
    order_id="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
    local idem
    idem="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
    local payload
    if [[ -n "${READY_CHECKOUT_BODY//[[:space:]]/}" ]]; then
      payload="$READY_CHECKOUT_BODY"
    else
      payload="$($PYTHON_BIN -c "import json; print(json.dumps({'order_id': '$order_id', 'total': 1200, 'items': [{'product_id': 'sku-1', 'quantity': 1}]}))")"
    fi
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Idempotency-Key: $idem" -d "$payload" "${base_url%/}/checkout" || echo "000")"
    if [[ "$code" == 2* ]]; then return 0; fi
    sleep "$sleep_s"
  done
  return 1
}

ensure_readiness() {
  local dep
  for dep in "${READINESS_DEPLOYMENTS[@]}"; do
    local resolved
    resolved="$(resolve_deployment "$dep" || true)"
    [[ -n "${resolved//[[:space:]]/}" ]] || die "readiness deployment '$dep' not found"
    local selector
    selector="$(selector_for_deploy "$resolved")"
    ensure_deploy_ready "$resolved" "$selector"
  done

  ensure_order_pf
  set_bench_base_url || true
  local ready_url
  ready_url="$(bench_base_url_primary)"
  if [[ -z "${ready_url//[[:space:]]/}" ]]; then
    die "bench base url is empty after port-forward setup"
  fi
  if ! wait_http_ready "$ready_url" "$READY_HTTP_PATH" "$READY_HTTP_RETRIES" "$READY_HTTP_SLEEP"; then
    die "readiness check failed"
  fi
  if ! warmup_checkout "$ready_url" "$READY_CHECKOUT_RETRIES" "$READY_CHECKOUT_SLEEP"; then
    die "readiness checkout warmup failed"
  fi
}

# ----------------------------
# Netem helpers
# ----------------------------
apply_tc_cmd() {
  local pod="$1"; shift
  local extra=()
  [[ -n "$NETEM_CONTAINER" ]] && extra+=("-c" "$NETEM_CONTAINER")
  run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec -n "$NAMESPACE" "$pod" "${extra[@]}" -- "$@" >/dev/null 2>&1 || true
}

apply_tc_cmd_strict() {
  local pod="$1"; shift
  local extra=()
  [[ -n "$NETEM_CONTAINER" ]] && extra+=("-c" "$NETEM_CONTAINER")
  if ! run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec -n "$NAMESPACE" "$pod" "${extra[@]}" -- "$@" >/dev/null; then
    die "failed to apply netem on pod $pod"
  fi
}

pod_has_tc() {
  local pod="$1"
  local extra=()
  [[ -n "$NETEM_CONTAINER" ]] && extra+=("-c" "$NETEM_CONTAINER")
  run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec -n "$NAMESPACE" "$pod" "${extra[@]}" -- sh -c "command -v tc >/dev/null" >/dev/null 2>&1
}

ensure_tc_or_warn() {
  local pod="$1"
  local selector="$2"
  if pod_has_tc "$pod"; then return 0; fi
  if [[ "$NETEM_REQUIRE_TC" == "1" ]]; then
    die "tc not found in pod $pod (selector=$selector)"
  fi
  log "WARNING: tc not found in pod $pod; skipping netem"
  return 1
}

apply_netem_profile() {
  local profile="$1"
  local delay_ms="$2"
  local jitter_ms="$3"

  local selector
  for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "$selector" ]] || continue
    local pod_count=0
    for pod in $(list_pods_for "$selector" 1); do
      pod_count=$((pod_count + 1))
      if ! ensure_tc_or_warn "$pod" "$selector"; then continue; fi
      apply_tc_cmd "$pod" tc qdisc del dev eth0 root
      case "$profile" in
        normal)
          if [[ "$delay_ms" != "0" || "$jitter_ms" != "0" ]]; then
            apply_tc_cmd_strict "$pod" tc qdisc replace dev eth0 root netem delay "${delay_ms}ms" "${jitter_ms}ms"
          fi
          ;;
        lossy)
          apply_tc_cmd_strict "$pod" tc qdisc replace dev eth0 root netem delay "${delay_ms}ms" "${jitter_ms}ms" loss "${LOSSY_LOSS_PCT}%" duplicate "${LOSSY_DUP_PCT}%" reorder "${LOSSY_REORDER_PCT}%" "${LOSSY_REORDER_CORR}%"
          ;;
        congested)
          apply_tc_cmd_strict "$pod" tc qdisc replace dev eth0 root handle 1: netem delay "${delay_ms}ms" "${jitter_ms}ms" loss "${CONGEST_LOSS_PCT}%"
          apply_tc_cmd_strict "$pod" tc qdisc replace dev eth0 parent 1:1 handle 10: tbf rate "$CONGEST_RATE" burst "$CONGEST_BURST" limit "$CONGEST_LIMIT_PKTS"
          ;;
        *) die "unknown net profile: $profile" ;;
      esac
    done
    log "Netem applied on selector=$selector pods=$pod_count profile=$profile"
  done
}

validate_netem_profile() {
  local profile="$1"
  local delay_ms="$2"
  local jitter_ms="$3"
  local selector
  for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "$selector" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      ensure_tc_or_warn "$pod" "$selector"
      if [[ "$profile" == "normal" && "$delay_ms" == "0" && "$jitter_ms" == "0" ]]; then continue; fi
      local qdisc
      qdisc="$(kube_exec -n "$NAMESPACE" -c "$NETEM_CONTAINER" "$pod" -- tc qdisc show dev eth0 2>/dev/null || true)"
      if [[ "$qdisc" != *"netem"* ]]; then die "netem not applied on pod $pod"; fi
    done
  done
}

clear_netem() {
  local ignore_errors="${1:-0}"
  local selector
  for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "$selector" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      if [[ "$ignore_errors" == "1" ]]; then
        if ! pod_has_tc "$pod"; then continue; fi
      else
        if ! ensure_tc_or_warn "$pod" "$selector"; then continue; fi
      fi
      apply_tc_cmd "$pod" tc qdisc del dev eth0 root
    done
  done
}

sum_net_bytes() {
  local direction="$1"
  local total=0
  local selector
  for selector in "${METRICS_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "$selector" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      local val
      val="$(run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec -n "$NAMESPACE" "$pod" -- cat "/sys/class/net/eth0/statistics/${direction}_bytes" 2>/dev/null || echo "")"
      if [[ -n "$val" ]]; then total=$((total + val)); fi
    done
  done
  echo "$total"
}

capture_netem_state() {
  local profile="$1"
  local latency_ms="$2"
  local jitter_ms="$3"
  local log_file="${NETEM_VALIDATE_LOG_DIR}/netem-${timestamp}-${profile}-${latency_ms}ms-${jitter_ms}ms.log"
  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "profile=$profile"
    echo "latency_ms=$latency_ms"
    echo "jitter_ms=$jitter_ms"
    local selector
    for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
      echo "selector=$selector"
      for pod in $(list_pods_for "$selector"); do
        echo "pod=$pod"
        if ! ensure_tc_or_warn "$pod" "$selector"; then continue; fi
        local extra=()
        [[ -n "$NETEM_CONTAINER" ]] && extra+=("-c" "$NETEM_CONTAINER")
        run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" exec -n "$NAMESPACE" "$pod" "${extra[@]}" -- tc qdisc show dev eth0 || true
        echo "---"
      done
      echo
    done
  } >"$log_file" 2>&1
  echo "$log_file"
}

METRICS_WARNING_EMITTED="0"
start_metrics_sampler() {
  local sample_file="$1"
  local interval="$2"
  : >"$sample_file"
  # FIX: Redirect entire subshell to avoid leakage to stdout
  (
    while true; do
      local selector
      for selector in "${METRICS_SELECTORS[@]}"; do
        selector="$(trim "$selector")"
        [[ -n "$selector" ]] || continue
        local output
        output="$(run_with_timeout "$KUBECTL_EXEC_TIMEOUT" kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" top pods -n "$NAMESPACE" -l "$selector" --no-headers 2>&1 || true)"
        if [[ -z "$output" ]]; then continue; fi
        if [[ "$output" == *"Metrics API not available"* ]]; then
          continue
        fi
        echo "$output" | awk -v sel="$selector" -v ts="$(date +%s)" '{gsub("m","",$2); gsub("Mi","",$3); cpu+=$2; mem+=$3} END {printf "%s\t%s\t%d\t%d\n", ts, sel, cpu, mem}'
      done
      sleep "$interval"
    done
  ) >"$sample_file" 2>&1 &
  echo $!
}

stop_metrics_sampler() {
  local pid="$1"
  if [[ -n "${pid//[[:space:]]/}" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

summarize_metrics_samples() {
  local sample_file="$1"
  if [[ ! -s "$sample_file" ]]; then echo ""; return; fi
  "$PYTHON_BIN" -c '
import json, sys
from collections import defaultdict
data = defaultdict(lambda: {"cpu": [], "mem": []})
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.strip().split("\t")
        if len(parts) != 4: continue
        _, selector, cpu, mem = parts
        try:
            data[selector]["cpu"].append(int(cpu))
            data[selector]["mem"].append(int(mem))
        except ValueError: continue
def stats(values):
    if not values: return {"avg": None, "max": None, "samples": 0}
    return {"avg": round(sum(values) / len(values), 2), "max": max(values), "samples": len(values)}
selectors = {}
total_cpu = []
total_mem = []
for selector, vals in data.items():
    selectors[selector] = {"cpu_millicores": stats(vals["cpu"]), "memory_mib": stats(vals["mem"])}
    total_cpu.extend(vals["cpu"])
    total_mem.extend(vals["mem"])
summary = {"selectors": selectors, "total": {"cpu_millicores": stats(total_cpu), "memory_mib": stats(total_mem)}}
print(json.dumps(summary, separators=(",", ":")))
' "$sample_file"
}

# ----------------------------
# Bench-runner pod management
# ----------------------------
BENCH_RUNNER_POD=""

ensure_bench_runner_pod() {
  if [[ "$BENCH_IN_CLUSTER" != "1" ]]; then return 0; fi
  if [[ -n "${BENCH_RUNNER_POD//[[:space:]]/}" ]]; then
    if kube -n "$NAMESPACE" get pod "$BENCH_RUNNER_POD" >/dev/null 2>&1; then
      return 0
    fi
  fi
  local pod_ts
  pod_ts="$(printf '%s' "$timestamp" | tr '[:upper:]' '[:lower:]')"
  BENCH_RUNNER_POD="${BENCH_RUNNER_POD_PREFIX}-${pod_ts}"
  log "Starting bench-runner pod: $BENCH_RUNNER_POD (image: $BENCH_RUNNER_IMAGE)"
  kube -n "$NAMESPACE" run "$BENCH_RUNNER_POD" --image="$BENCH_RUNNER_IMAGE" --restart=Never --command -- sleep 36000 >/dev/null
  kube -n "$NAMESPACE" wait --for=condition=Ready "pod/${BENCH_RUNNER_POD}" --timeout="$BENCH_RUNNER_READY_TIMEOUT" >/dev/null
  kubectl -n "$NAMESPACE" cp "$BENCH_BIN" "${BENCH_RUNNER_POD}:/bench-runner" >/dev/null
  kube -n "$NAMESPACE" exec "$BENCH_RUNNER_POD" -- chmod +x /bench-runner >/dev/null
}

cleanup_bench_runner_pod() {
  if [[ "$BENCH_IN_CLUSTER" == "1" && "$BENCH_RUNNER_KEEP_POD" != "1" ]]; then
    if [[ -n "${BENCH_RUNNER_POD//[[:space:]]/}" ]]; then
      kube -n "$NAMESPACE" delete pod "$BENCH_RUNNER_POD" --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi
}

# ----------------------------
# Port-forward management
# ----------------------------
ORDER_PF_PID=""
ORDER_PF_LOG=""
ORDER_PF_LOG_LINES=0
ORDER_PF_PIDS=()
ORDER_PF_PORTS=()
ORDER_PF_PODS=()
ORDER_PF_LOGS=()

have_port_listener() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -qE "(:|\\])${port}$"
    return $?
  fi
  lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  return $?
}

kill_existing_order_pf() {
  if [[ "$ORDER_PF_MODE" == "pods" ]]; then
    for port in "${ORDER_PF_PORTS[@]}"; do
      pkill -f "kubectl.*port-forward.*${port}:8080" >/dev/null 2>&1 || true
    done
    return 0
  fi
  # Узкий шаблон: конкретный namespace + svc + порт
  pkill -f "kubectl.*port-forward.*-n[[:space:]]+$NAMESPACE.*svc/$ORDER_SERVICE_NAME[[:space:]]+${ORDER_PF_PORT}:8080" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*-n[[:space:]]+$NAMESPACE.*svc/$ORDER_SERVICE_NAME[[:space:]]+${ORDER_PF_PORT}:8080" >/dev/null 2>&1 || true
}

stop_order_pf() {
  if [[ "$ORDER_PF_MODE" == "pods" ]]; then
    local ports=("${ORDER_PF_PORTS[@]}")
    for pid in "${ORDER_PF_PIDS[@]}"; do
      if [[ -n "${pid//[[:space:]]/}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
        kill -9 "$pid" >/dev/null 2>&1 || true
      fi
    done
    kill_existing_order_pf
    ORDER_PF_PIDS=()
    ORDER_PF_PORTS=()
    ORDER_PF_PODS=()
    ORDER_PF_LOGS=()

    for port in "${ports[@]}"; do
      for _ in $(seq 1 50); do
        if ! have_port_listener "$port"; then
          break
        fi
        sleep 0.1
      done
      if have_port_listener "$port"; then
        if command -v ss >/dev/null 2>&1; then
          ss -ltnp | grep -E "(:|\\])${port}[[:space:]]" >&2 || true
        elif command -v lsof >/dev/null 2>&1; then
          lsof -iTCP:"$port" -sTCP:LISTEN -n -P >&2 || true
        fi
        die "port $port is still busy after stopping port-forward"
      fi
    done
    return 0
  fi

  if [[ -n "${ORDER_PF_PID//[[:space:]]/}" ]] && kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
    kill "$ORDER_PF_PID" >/dev/null 2>&1 || true
    wait "$ORDER_PF_PID" >/dev/null 2>&1 || true
    # если не умер — добить
    kill -9 "$ORDER_PF_PID" >/dev/null 2>&1 || true
  fi
  ORDER_PF_PID=""

  # добиваем возможные “сироты”
  kill_existing_order_pf

  # дождаться освобождения порта
  for _ in $(seq 1 50); do
    if ! have_port_listener "$ORDER_PF_PORT"; then
      return 0
    fi
    sleep 0.1
  done

  # если всё ещё занят — показать диагностический вывод
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep -E "(:|\\])${ORDER_PF_PORT}[[:space:]]" >&2 || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$ORDER_PF_PORT" -sTCP:LISTEN -n -P >&2 || true
  fi

  die "port $ORDER_PF_PORT is still busy after stopping port-forward"
}

start_order_pf() {
  if [[ "$ORDER_PF_MODE" == "pods" ]]; then
    stop_order_pf
    local pods
    pods="$(list_ready_pods_for "$LABEL_SELECTOR")"
    read -r -a ORDER_PF_PODS <<< "$pods"
    if [[ ${#ORDER_PF_PODS[@]} -eq 0 ]]; then
      die "no pods found for selector '$LABEL_SELECTOR'"
    fi

    local idx=0
    for pod in "${ORDER_PF_PODS[@]}"; do
      local port=$((ORDER_PF_PORT + idx))
      if have_port_listener "$port"; then
        die "local port $port is already in use (set ORDER_PF_PORT=18080 or stop conflicting process)"
      fi
      local log_file="${ORDER_PF_LOG_DIR}/order-${timestamp}-${pod}.log"
      : > "$log_file" || true
      log "Starting port-forward for order: pod/$pod -> ${ORDER_PF_ADDR}:${port}"
      command kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      port-forward "pod/$pod" "${port}:8080" --address "$ORDER_PF_ADDR" \
      >"$log_file" 2>&1 &
      ORDER_PF_PIDS+=("$!")
      ORDER_PF_PORTS+=("$port")
      ORDER_PF_LOGS+=("$log_file")
      idx=$((idx + 1))
    done

    for i in "${!ORDER_PF_PIDS[@]}"; do
      local pid="${ORDER_PF_PIDS[$i]}"
      local port="${ORDER_PF_PORTS[$i]}"
      local pod="${ORDER_PF_PODS[$i]}"
      for _ in $(seq 1 80); do
        if have_port_listener "$port"; then
          sleep 1 # Give it a second to be truly ready
          break
        fi
        if ! kill -0 "$pid" >/dev/null 2>&1; then
          die "order port-forward failed to start for pod $pod"
        fi
        sleep 0.1
      done
      if ! have_port_listener "$port"; then
        die "order port-forward timed out for pod $pod"
      fi
    done
    set_bench_base_url
    return 0
  fi

  stop_order_pf
  if have_port_listener "$ORDER_PF_PORT"; then
    kill_existing_order_pf
    sleep 0.2
  fi
  if have_port_listener "$ORDER_PF_PORT"; then
    die "local port $ORDER_PF_PORT is already in use (set ORDER_PF_PORT=18080 or stop conflicting process)"
  fi

  ORDER_PF_LOG="${ORDER_PF_LOG_DIR}/order-${timestamp}-txmode.log"
  : > "$ORDER_PF_LOG" || true
  log "Starting port-forward for order: svc/$ORDER_SERVICE_NAME -> ${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
  command kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
  port-forward "svc/$ORDER_SERVICE_NAME" "${ORDER_PF_PORT}:8080" --address "$ORDER_PF_ADDR" \
  >"$ORDER_PF_LOG" 2>&1 &
ORDER_PF_PID=$!

  ORDER_PF_PID="$!"
  for _ in $(seq 1 80); do
    if have_port_listener "$ORDER_PF_PORT"; then
      sleep 1 # Give it a second to be truly ready
      set_bench_base_url
      return 0
    fi
    if ! kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then die "order port-forward failed to start"; fi
    sleep 0.1
  done
  die "order port-forward timed out"
}

restart_order_pf() {
  stop_order_pf
  start_order_pf
}

ensure_order_pf() {
  if [[ "$MANAGE_ORDER_PF" != "1" ]]; then return 0; fi
  if [[ "$ORDER_PF_MODE" == "pods" ]]; then
    if [[ ${#ORDER_PF_PIDS[@]} -eq 0 ]]; then restart_order_pf; return 0; fi
    local pods
    pods="$(list_ready_pods_for "$LABEL_SELECTOR")"
    local pods_now=()
    read -r -a pods_now <<< "$pods"
    if [[ ${#pods_now[@]} -eq 0 ]]; then restart_order_pf; return 0; fi
    if [[ ${#pods_now[@]} -ne ${#ORDER_PF_PODS[@]} ]]; then restart_order_pf; return 0; fi
    if [[ "${pods_now[*]}" != "${ORDER_PF_PODS[*]}" ]]; then restart_order_pf; return 0; fi
    for i in "${!ORDER_PF_PIDS[@]}"; do
      local pid="${ORDER_PF_PIDS[$i]}"
      local port="${ORDER_PF_PORTS[$i]}"
      if [[ -z "${pid//[[:space:]]/}" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
        restart_order_pf; return 0
      fi
      if ! have_port_listener "$port"; then
        restart_order_pf; return 0
      fi
    done
    return 0
  fi
  if [[ -z "$ORDER_PF_PID" ]] || ! kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then restart_order_pf; return 0; fi
  if ! have_port_listener "$ORDER_PF_PORT"; then restart_order_pf; fi
}

set_bench_base_url() {
  if [[ "$MANAGE_ORDER_PF" != "1" ]]; then
    BENCH_BASE_URL="$ORDER_BASE_URL"
    return 0
  fi
  if [[ "$ORDER_PF_MODE" == "pods" ]]; then
    if [[ ${#ORDER_PF_PORTS[@]} -eq 0 ]]; then
      BENCH_BASE_URL=""
      return 1
    fi
    local urls=()
    for port in "${ORDER_PF_PORTS[@]}"; do
      urls+=("http://${ORDER_PF_ADDR}:${port}")
    done
    BENCH_BASE_URL="$(IFS=,; echo "${urls[*]}")"
    return 0
  fi
  BENCH_BASE_URL="http://${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
}

bench_base_url_primary() {
  local base="${BENCH_BASE_URL:-}"
  if [[ -z "${base//[[:space:]]/}" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$base" == *","* ]]; then
    base="${base%%,*}"
  fi
  printf '%s' "$base"
}

# ----------------------------
# Bench helpers
# ----------------------------
extract_first_json_object() {
  "$PYTHON_BIN" -c '
import json, sys
text = sys.stdin.read()
if not text.strip(): sys.exit(2)
dec = json.JSONDecoder()
for i, ch in enumerate(text):
    if ch != "{": continue
    try:
        obj, _ = dec.raw_decode(text[i:])
        if isinstance(obj, dict):
            print(json.dumps(obj, separators=(",", ":")))
            sys.exit(0)
    except Exception: pass
sys.exit(3)
'
}

run_bench_json() {
  local base_url="$1"
  local tx="$2"
  local conc="$3"
  local log_file="$4"
  local run_label="$7"
  local bench_bin="$BENCH_BIN"
  if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
    bench_bin="/bench-runner"
  fi
  local args=("$bench_bin" -base-url "$base_url" -total "$tx" -concurrency "$conc" -timeout "$BENCH_REQUEST_TIMEOUT")
  if [[ "$AWAIT_FINAL" == "1" ]]; then
    args+=(-await-final -final-timeout "$FINAL_TIMEOUT" -final-interval "$FINAL_INTERVAL" -final-statuses "$FINAL_STATUSES")
  fi
  local cmd=("${args[@]}")
  if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
    ensure_bench_runner_pod
    cmd=(kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" exec "$BENCH_RUNNER_POD" -- "${args[@]}")
  fi
  local out_file
  out_file="$(mktemp)"
  local timeout_s
  timeout_s="$(duration_seconds "$BENCH_RUN_TIMEOUT")"
  "${cmd[@]}" >"$out_file" 2>"$log_file" &
  local bench_pid=$!
  local start_ts
  start_ts="$(date +%s)"
  while kill -0 "$bench_pid" >/dev/null 2>&1; do
    if (( $(date +%s) - start_ts > timeout_s )); then
      kill -9 "$bench_pid" >/dev/null 2>&1 || true
      rm -f "$out_file"
      return 1
    fi
    sleep "$HEARTBEAT_INTERVAL"
  done
  wait "$bench_pid" || {
    # LOG DEBUG: if bench-runner failed, print tail of log to see WHY
    log "bench-runner failed/exited. Last 20 lines of $log_file:"
    tail -n 20 "$log_file" >&2
    rm -f "$out_file"; return 1;
  }
  cat "$out_file" | extract_first_json_object
  rm -f "$out_file"
}

run_bench_json_with_retry() {
  local base_url="$1"
  local tx="$2"
  local conc="$3"
  local log_file="$4"
  local mode="$5"
  local profile="$6"
  local run_label="$7"
  for attempt in 1 2; do
    if bench_json="$(run_bench_json "$base_url" "$tx" "$conc" "$log_file" "$mode" "$profile" "$run_label")"; then
      [[ -n "$bench_json" ]] && echo "$bench_json" && return 0
    fi
    [[ "$MANAGE_ORDER_PF" == "1" ]] && restart_order_pf
    sleep 0.5
  done
  return 1
}

bench_invalid_reason() {
  "$PYTHON_BIN" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    total = d.get("total_requests", 0) or 0
    errors = d.get("error_requests", 0) or 0
    err_cls = d.get("error_classes", {}) or {}
    status_cnt = d.get("status_counts", {}) or {}
    if total > 0 and errors == total and (err_cls.get("transport",0)==total or status_cnt.get("0",0)==total):
        print("transport_all")
        sys.exit(0)
except: pass
'
}

smoke_check() {
  local base_url="$1"
  local order_id
  order_id="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"order_id\":\"$order_id\",\"total\":1200,\"items\":[{\"product_id\":\"sku-1\",\"quantity\":1}]}" "${base_url%/}/checkout" || echo "000")"
  log "Smoke check /checkout -> HTTP $code"
  if [[ "$code" != 2* ]]; then die "smoke check failed"; fi
}

METRICS_PID=""
cleanup() {
  [[ -n "$METRICS_PID" ]] && kill "$METRICS_PID" >/dev/null 2>&1 || true
  clear_netem 1 || true
  [[ "$MANAGE_ORDER_PF" == "1" ]] && stop_order_pf || true
  cleanup_bench_runner_pod
}
trap cleanup EXIT INT TERM

# ----------------------------
# Prepare URL
# ----------------------------
if [[ "$BENCH_IN_CLUSTER" == "1" && "$ORDER_BASE_URL" == "http://127.0.0.1:8080" ]]; then
  ORDER_BASE_URL="http://${ORDER_SERVICE_NAME}.${NAMESPACE}.svc:8080"
fi

BENCH_BASE_URL="$ORDER_BASE_URL"
if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
  BENCH_BASE_URL=""
fi
if [[ "$MANAGE_ORDER_PF" != "1" ]]; then
  log "Bench base url: $BENCH_BASE_URL"
else
  log "Bench base url: managed by port-forward (${ORDER_PF_MODE})"
fi

if [[ "$BENCH_IN_CLUSTER" == "1" ]]; then
  ensure_bench_runner_pod
  log "Bench runner pod ready: $BENCH_RUNNER_POD"
fi

# ----------------------------
# Main Loop
# ----------------------------
if [[ "$MANAGE_ORDER_PF" == "1" && "$ORDER_PF_MODE" == "service" ]]; then
  for replicas in "${REPLICAS_LIST[@]}"; do
    if (( replicas > 1 )); then
      log "WARNING: ORDER_PF_MODE=service pins traffic to one pod; replicas won't scale (use ORDER_PF_MODE=pods or MANAGE_ORDER_PF=0)."
      break
    fi
  done
fi
for replicas in "${REPLICAS_LIST[@]}"; do
  log "Scale replicas=$replicas"
  scale_replicas "$replicas"

  for mode in "${TX_MODES[@]}"; do
    log "Switching TX_MODE to '$mode'"
    if [[ "$MANAGE_ORDER_PF" == "1" ]]; then stop_order_pf; fi
    kube -n "$NAMESPACE" set env "deployment/${DEPLOYMENT}" "TX_MODE=${mode}" >/dev/null
    kube -n "$NAMESPACE" rollout restart "deployment/${DEPLOYMENT}" >/dev/null
    ensure_rollout
    wait_pods_stable
    sleep 5
  if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
    start_order_pf
    log "Bench base url: $BENCH_BASE_URL"
  else
    set_bench_base_url
  fi
  ensure_readiness
  if [[ "$SMOKE" == "1" ]]; then
    smoke_check "$(bench_base_url_primary)"
  fi

    for profile in "${NET_PROFILES[@]}"; do
      for latency in "${LATENCIES_MS[@]}"; do
        for jitter in "${JITTERS_MS[@]}"; do
          effective_latency="$latency"
          effective_jitter="$jitter"
          if [[ "$profile" == "congested" ]]; then
            effective_latency="$CONGEST_DELAY_MS"
            effective_jitter="$CONGEST_JITTER_MS"
          fi

          apply_netem_profile "$profile" "$effective_latency" "$effective_jitter"
          sleep "$WAIT_AFTER_NETEM"
          validate_netem_profile "$profile" "$effective_latency" "$effective_jitter"
          netem_log="$(capture_netem_state "$profile" "$effective_latency" "$effective_jitter")"

          if [[ "$WARMUP_ENABLED" == "1" && "$WARMUP_TX" != "0" ]]; then
             run_bench_json_with_retry "$BENCH_BASE_URL" "$WARMUP_TX" "$WARMUP_CONCURRENCY" "${BENCH_LOG_DIR}/warmup.log" "$mode" "$profile" "warmup" >/dev/null || true
          fi

          for tx in "${TX_COUNTS[@]}"; do
            for conc in "${CONCURRENCY_LIST[@]}"; do
              for run_id in $(seq 1 "$BENCH_RUNS_PER_POINT"); do
                log "RUN mode=$mode profile=$profile r=$replicas c=$conc run=${run_id} L=${effective_latency}ms"
                ensure_order_pf
                net_before_rx="$(sum_net_bytes rx)"
                net_before_tx="$(sum_net_bytes tx)"

                bench_log="${BENCH_LOG_DIR}/bench-${timestamp}-${mode}-${profile}-r${replicas}-tx${tx}-c${conc}-run${run_id}.log"
                sample_file="${BENCH_LOG_DIR}/metrics-${timestamp}-${mode}-${profile}-r${replicas}-tx${tx}-c${conc}-run${run_id}.log"
                METRICS_PID="$(start_metrics_sampler "$sample_file" "$METRICS_SAMPLE_INTERVAL")"

                attempt=0
                while true; do
                  attempt=$((attempt + 1))
                  if ! bench_json="$(run_bench_json_with_retry "$BENCH_BASE_URL" "$tx" "$conc" "$bench_log" "$mode" "$profile" "run${run_id}")"; then
                    stop_metrics_sampler "$METRICS_PID"
                    die "bench-runner failed"
                  fi
                  invalid="$(printf '%s' "$bench_json" | bench_invalid_reason)"
                  if [[ -z "$invalid" ]]; then break; fi
                  log "Invalid run ($invalid), retrying..."
                  if (( attempt >= INVALID_RETRY_LIMIT )); then die "invalid run persisted"; fi
                  sleep "$INVALID_RETRY_SLEEP"
                done
                stop_metrics_sampler "$METRICS_PID"
                METRICS_PID=""

                net_after_rx="$(sum_net_bytes rx)"
                net_after_tx="$(sum_net_bytes tx)"
                rx_delta=$((net_after_rx - net_before_rx))
                tx_delta=$((net_after_tx - net_before_tx))

                # Safe python extraction
                bench_fields="$(printf '%s' "$bench_json" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
avg = d.get("avg_latency_ms", 0)
p95 = d.get("p95_latency_ms", 0)
p99 = d.get("p99_latency_ms", 0)
thr = d.get("throughput_rps", 0)
err = d.get("error_requests", 0)
dur = d.get("duration_seconds", 0)
status = d.get("status_counts", {})
ecls = d.get("error_classes", {})
fin = d.get("finalized_requests", 0)
fout = d.get("final_timeouts", 0)
ferr = (d.get("first_error", "") or "").replace("\n", " ").replace("\t", " ")
# Print Tab-Separated
print(f"{avg}\t{p95}\t{p99}\t{thr}\t{err}\t{dur}\t{json.dumps(status)}\t{json.dumps(ecls)}\t{fin}\t{fout}\t{ferr}")
')"

                # Use python to split safely (avoids spaces in JSON breaking awk)
                IFS=$'\t' read -r avg_lat p95_lat p99_lat thr err dur status ecls fin fout ferr <<< "$bench_fields"

                if [[ "$err" != "0" && -n "$ferr" ]]; then log "ERRORS: $ferr"; fi

                metrics_summary="$(summarize_metrics_samples "$sample_file")"
                # Resource stats
                res_stats="$($PYTHON_BIN -c '
import json,sys
try:
  d = json.loads(sys.argv[1]) if sys.argv[1] else {}
  t = d.get("total", {})
  c = t.get("cpu_millicores", {})
  m = t.get("memory_mib", {})
  print(f"{c.get("avg","")}/{c.get("max","")} {m.get("avg","")}/{m.get("max","")}")
except: print("/ /")
' "${metrics_summary:-null}")"
                read -r cpu_stats mem_stats <<< "$res_stats"

                # Bandwidth calc (safe division)
                net_stats="$($PYTHON_BIN -c '
import sys
try:
  rx = int(sys.argv[1])
  tx = int(sys.argv[2])
  dur = float(sys.argv[3])
  if dur > 0:
    print(f"{round((rx/dur)/1024,2)} {round((tx/dur)/1024,2)}")
  else:
    print("0 0")
except: print("0 0")
' "$rx_delta" "$tx_delta" "$dur")"
                read -r rx_kbps tx_kbps <<< "$net_stats"

                if [[ "$first_record" == true ]]; then first_record=false; else echo "," >> "$json_file"; fi
                cat <<JSON >> "$json_file"
  {
    "tx_mode": "$mode", "net_profile": "$profile", "replicas": $replicas, "concurrency": $conc, "run_id": $run_id,
    "transactions": $tx, "latency_ms": $effective_latency, "jitter_ms": $effective_jitter,
    "bench": $bench_json, "resources": ${metrics_summary:-null},
    "network": {"rx_bytes": $rx_delta, "tx_bytes": $tx_delta, "rx_kbps": $rx_kbps, "tx_kbps": $tx_kbps}
  }
JSON
                # Markdown Table Row
                printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                  "$mode" "$profile" "$replicas" "$conc" "$run_id" "$tx" "$effective_latency" "$effective_jitter" \
                  "$avg_lat" "$p95_lat" "$p99_lat" "$thr" "$err" "${ecls//|/ }" "${status//|/ }" "${fin}/${fout}" "${ferr//|/ }" \
                  "$cpu_stats" "$mem_stats" "$rx_kbps" "$tx_kbps" >> "$md_file"

              done # run
            done # conc
          done # tx

          clear_netem
        done # jitter
      done # latency
    done # profile
  done # mode
done # replicas

echo "]" >> "$json_file"
log "Results saved to $json_file and $md_file"
