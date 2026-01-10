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

# ----------------------------
# Config (env overrides)
# ----------------------------
NAMESPACE="$(trim "${NAMESPACE:-txlab}")"
DEPLOYMENT="$(trim "${DEPLOYMENT:-order}")"                 # logical name, will be resolved to real deployment name

ORDER_BASE_URL="$(trim "${ORDER_BASE_URL:-http://127.0.0.1:8080}")"

RESULTS_DIR="$(trim "${RESULTS_DIR:-results}")"
CONCURRENCY="$(trim "${CONCURRENCY:-10}")"
CONCURRENCY_LIST_STR="$(trim "${CONCURRENCY_LIST:-}")"
BENCH_LOG_DIR="$(trim "${BENCH_LOG_DIR:-${RESULTS_DIR}/bench-logs}")"
BENCH_RUNS_PER_POINT="$(trim "${BENCH_RUNS_PER_POINT:-3}")"
WARMUP_TX="$(trim "${WARMUP_TX:-200}")"
WARMUP_CONCURRENCY="$(trim "${WARMUP_CONCURRENCY:-$CONCURRENCY}")"
WARMUP_ENABLED="$(trim "${WARMUP_ENABLED:-1}")"
INVALID_RETRY_LIMIT="$(trim "${INVALID_RETRY_LIMIT:-2}")"
INVALID_RETRY_SLEEP="$(trim "${INVALID_RETRY_SLEEP:-3}")"

# TX modes: override via TX_MODES="twopc saga-orch tcc outbox"
TX_MODES_STR="$(trim "${TX_MODES:-}")"
TX_MODES_DEFAULT=("twopc" "saga-orch" "saga-chor" "tcc" "outbox")

# Network profiles
NET_PROFILES_STR="$(trim "${NET_PROFILES:-}")"
NET_PROFILES_DEFAULT=("normal" "lossy" "congested")

REPLICAS_LIST=(1 3)
TX_COUNTS=(10000)
LATENCIES_MS=(100)
JITTERS_MS=(20)

# Network profile parameters (lossy/congested)
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

# Port-forward management for order-service (restarted after every TX_MODE switch)
MANAGE_ORDER_PF="${MANAGE_ORDER_PF:-1}"                     # 1/0
ORDER_PF_ADDR="$(trim "${ORDER_PF_ADDR:-127.0.0.1}")"
ORDER_PF_PORT="$(trim "${ORDER_PF_PORT:-8080}")"            # local port for order-service
ORDER_PF_LOG_DIR="$(trim "${ORDER_PF_LOG_DIR:-${RESULTS_DIR}/pf-logs}")"

# Rollout timeouts
ROLLOUT_TIMEOUT="$(trim "${ROLLOUT_TIMEOUT:-5m}")"
PODS_READY_TIMEOUT_SECONDS="$(trim "${PODS_READY_TIMEOUT_SECONDS:-180}")"
WAIT_AFTER_NETEM="$(trim "${WAIT_AFTER_NETEM:-1}")"

SMOKE="${SMOKE:-0}"
READINESS_DEPLOYMENTS_STR="$(trim "${READINESS_DEPLOYMENTS:-}")"
READY_HTTP_PATH="$(trim "${READY_HTTP_PATH:-/health}")"
READY_HTTP_RETRIES="$(trim "${READY_HTTP_RETRIES:-20}")"
READY_HTTP_SLEEP="$(trim "${READY_HTTP_SLEEP:-0.5}")"
READY_CHECKOUT_RETRIES="$(trim "${READY_CHECKOUT_RETRIES:-10}")"
READY_CHECKOUT_SLEEP="$(trim "${READY_CHECKOUT_SLEEP:-0.5}")"
READY_CHECKOUT_BODY="$(trim "${READY_CHECKOUT_BODY:-}")"
AWAIT_FINAL="$(trim "${AWAIT_FINAL:-0}")"
FINAL_TIMEOUT="$(trim "${FINAL_TIMEOUT:-30s}")"
FINAL_INTERVAL="$(trim "${FINAL_INTERVAL:-500ms}")"
FINAL_STATUSES="$(trim "${FINAL_STATUSES:-CONFIRMED,COMMITTED}")"

NETEM_TARGET_SELECTORS_STR="$(trim "${NETEM_TARGET_SELECTORS:-}")"
NETEM_VALIDATE="$(trim "${NETEM_VALIDATE:-1}")"
NETEM_VALIDATE_LOG_DIR="$(trim "${NETEM_VALIDATE_LOG_DIR:-${RESULTS_DIR}/netem-validate}")"
NETEM_REQUIRE_TC="$(trim "${NETEM_REQUIRE_TC:-1}")"
PROBE_SERVICES_STR="$(trim "${PROBE_SERVICES:-}")"
PROBE_IMAGE="$(trim "${PROBE_IMAGE:-busybox:1.36}")"

METRICS_SELECTORS_STR="$(trim "${METRICS_SELECTORS:-}")"
METRICS_SAMPLE_INTERVAL="$(trim "${METRICS_SAMPLE_INTERVAL:-2}")"

# python3 preferred
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

# ----------------------------
# Validate basics
# ----------------------------
[[ -n "$NAMESPACE" ]] || die "NAMESPACE is empty"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' not found"

mkdir -p "$RESULTS_DIR" "$ORDER_PF_LOG_DIR" "$BENCH_LOG_DIR" "$NETEM_VALIDATE_LOG_DIR"

# ----------------------------
# Resolve deployment name
# ----------------------------
deployment_exists() {
  kubectl get deployment "$1" -n "$NAMESPACE" >/dev/null 2>&1
}

list_deployments() {
  kubectl get deploy -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

resolve_deployment() {
  local wanted="$1"

  # 1) exact match
  if deployment_exists "$wanted"; then
    printf '%s' "$wanted"
    return 0
  fi

  # 2) prefer "*-<wanted>-service"
  local cand
  cand="$(list_deployments | grep -F "${wanted}-service" | head -n1 || true)"
  if [[ -n "${cand//[[:space:]]/}" ]] && deployment_exists "$cand"; then
    printf '%s' "$cand"
    return 0
  fi

  # 3) any deployment containing wanted, exclude postgres
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
  echo "Deployments in '$NAMESPACE':" >&2
  kubectl get deploy -n "$NAMESPACE" >&2 || true
  exit 1
fi
DEPLOYMENT="$REAL_DEPLOYMENT"
log "Using deployment: $DEPLOYMENT"

# ----------------------------
# Derive label selector from deployment.spec.selector.matchLabels
# ----------------------------
LABEL_SELECTOR="$(
  kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
import json,sys
d=json.load(sys.stdin)
ml=(d.get("spec",{}).get("selector",{}) or {}).get("matchLabels") or {}
print(",".join([f"{k}={v}" for k,v in ml.items()]))
'
)"
[[ -n "${LABEL_SELECTOR//[[:space:]]/}" ]] || die "cannot derive LABEL_SELECTOR from deployment '$DEPLOYMENT' (.spec.selector.matchLabels is empty)"
log "Pod selector: $LABEL_SELECTOR"

# ----------------------------
# Resolve service name that matches deployment selector (for port-forward)
# ----------------------------
ORDER_SERVICE_NAME="$(
  kubectl get svc -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
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

# Allow manual override
ORDER_SERVICE_NAME="$(trim "${ORDER_SERVICE_NAME_OVERRIDE:-$ORDER_SERVICE_NAME}")"

if [[ -z "${ORDER_SERVICE_NAME//[[:space:]]/}" ]]; then
  # fallback: service name equals deployment name
  if kubectl get svc -n "$NAMESPACE" "$DEPLOYMENT" >/dev/null 2>&1; then
    ORDER_SERVICE_NAME="$DEPLOYMENT"
  else
    log "Services in '$NAMESPACE':"
    kubectl get svc -n "$NAMESPACE" >&2 || true
    die "cannot resolve Service for deployment '$DEPLOYMENT' (no svc with selector == deployment selector). Set ORDER_SERVICE_NAME_OVERRIDE."
  fi
fi

log "Using service for order port-forward: $ORDER_SERVICE_NAME"

# ----------------------------
# TX_MODES / NET_PROFILES parsing
# ----------------------------
TX_MODES=()
if [[ -n "${TX_MODES_STR//[[:space:]]/}" ]]; then
  # shellcheck disable=SC2206
  TX_MODES=($TX_MODES_STR)
else
  TX_MODES=("${TX_MODES_DEFAULT[@]}")
fi

NET_PROFILES=()
if [[ -n "${NET_PROFILES_STR//[[:space:]]/}" ]]; then
  # shellcheck disable=SC2206
  NET_PROFILES=($NET_PROFILES_STR)
else
  NET_PROFILES=("${NET_PROFILES_DEFAULT[@]}")
fi

CONCURRENCY_LIST=()
if [[ -n "${CONCURRENCY_LIST_STR//[[:space:]]/}" ]]; then
  # shellcheck disable=SC2206
  CONCURRENCY_LIST=($CONCURRENCY_LIST_STR)
else
  CONCURRENCY_LIST=("$CONCURRENCY")
fi

READINESS_DEPLOYMENTS=()
if [[ -n "${READINESS_DEPLOYMENTS_STR//[[:space:]]/}" ]]; then
  # shellcheck disable=SC2206
  READINESS_DEPLOYMENTS=($READINESS_DEPLOYMENTS_STR)
else
  READINESS_DEPLOYMENTS=("$DEPLOYMENT")
fi

NETEM_TARGET_SELECTORS=()
if [[ -n "${NETEM_TARGET_SELECTORS_STR//[[:space:]]/}" ]]; then
  IFS=';' read -r -a NETEM_TARGET_SELECTORS <<<"$NETEM_TARGET_SELECTORS_STR"
else
  NETEM_TARGET_SELECTORS=("$LABEL_SELECTOR")
fi

METRICS_SELECTORS=()
if [[ -n "${METRICS_SELECTORS_STR//[[:space:]]/}" ]]; then
  IFS=';' read -r -a METRICS_SELECTORS <<<"$METRICS_SELECTORS_STR"
else
  METRICS_SELECTORS=("$LABEL_SELECTOR")
fi

PROBE_SERVICES=()
if [[ -n "${PROBE_SERVICES_STR//[[:space:]]/}" ]]; then
  # shellcheck disable=SC2206
  PROBE_SERVICES=($PROBE_SERVICES_STR)
fi

# ----------------------------
# Build bench-runner once
# ----------------------------
BENCH_BIN="${BENCH_BIN:-/tmp/bench-runner}"
go build -o "$BENCH_BIN" ./cmd/bench-runner
[[ -x "$BENCH_BIN" ]] || die "bench-runner binary not found at $BENCH_BIN"

# ----------------------------
# Output files
# ----------------------------
timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
json_file="$RESULTS_DIR/benchmarks-$timestamp.json"
md_file="$RESULTS_DIR/benchmarks-$timestamp.md"

cat <<HEADER > "$md_file"
# Benchmark results ($timestamp)

* Namespace: $NAMESPACE
* Deployment: $DEPLOYMENT
* Service (order): $ORDER_SERVICE_NAME
* Pod selector: $LABEL_SELECTOR
* Base URL: $ORDER_BASE_URL
* Concurrency list: ${CONCURRENCY_LIST[*]}
* Runs per point: $BENCH_RUNS_PER_POINT (warmup=${WARMUP_ENABLED}, warmup_tx=$WARMUP_TX)
* TX modes: ${TX_MODES[*]}
* Net profiles: ${NET_PROFILES[*]}
* Port-forward restart policy: stop before TX_MODE switch, start after rollout (MANAGE_ORDER_PF=$MANAGE_ORDER_PF)
* Netem target selectors: ${NETEM_TARGET_SELECTORS[*]}
* Metrics selectors: ${METRICS_SELECTORS[*]}
* Net profile parameters:
  * normal: delay/jitter from matrix (no loss)
  * lossy: loss=${LOSSY_LOSS_PCT}%, dup=${LOSSY_DUP_PCT}%, reorder=${LOSSY_REORDER_PCT}% corr=${LOSSY_REORDER_CORR}%
  * congested: delay=${CONGEST_DELAY_MS}ms jitter=${CONGEST_JITTER_MS}ms loss=${CONGEST_LOSS_PCT}% rate=${CONGEST_RATE} burst=${CONGEST_BURST} limit=${CONGEST_LIMIT_PKTS}

| TX mode | Net profile | Replicas | Concurrency | Run | Transactions | Latency (ms) | Jitter (ms) | Avg latency (ms) | P95 (ms) | P99 (ms) | Throughput (rps) | Errors | Error classes | Status counts | Finalized/Timeouts | First error | CPU avg/max (m) | Mem avg/max (Mi) | Net RX (KB/s) | Net TX (KB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER

echo "[" > "$json_file"
first_record=true

# ----------------------------
# K8s helpers
# ----------------------------
ensure_rollout() {
  kubectl -n "$NAMESPACE" rollout status "deployment/${DEPLOYMENT}" --timeout="$ROLLOUT_TIMEOUT"
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

# OK, если ровно desired активных pod и все они Ready
if len(active)==desired and ready==desired:
    print("OK")
else:
    print(f"WAIT active={len(active)}/{desired} ready={ready}/{desired}")
' <<<"$pods_json")"

    if [[ "$status" == "OK" ]]; then
      return 0
    fi

    # периодически печатать прогресс, чтобы не выглядело “зависанием”
    log "$status"

    if (( $(date +%s) - start > timeout_s )); then
      echo "ERROR: pods did not become stable in ${timeout_s}s" >&2
      kubectl -n "$NAMESPACE" get pods -l "$selector" -o wide >&2 || true
      kubectl -n "$NAMESPACE" describe deploy "$deployment" >&2 || true
      return 1
    fi

    sleep 0.5
  done
}

wait_pods_stable() {
  local timeout_s="${1:-180}"
  wait_pods_stable_for "$LABEL_SELECTOR" "$DEPLOYMENT" "$timeout_s"
}

scale_replicas() {
  local replicas="$1"
  kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$replicas" >/dev/null
  ensure_rollout
  wait_pods_stable "$PODS_READY_TIMEOUT_SECONDS"
}

list_pods_for() {
  local selector="$1"
  kubectl get pods -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[*].metadata.name}'
}

list_pods() {
  list_pods_for "$LABEL_SELECTOR"
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
  local code
  local i
  for i in $(seq 1 "$retries"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${base_url%/}${path}" || echo "000")"
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

warmup_checkout() {
  local base_url="$1"
  local attempts="$2"
  local sleep_s="$3"
  local order_id
  local idem
  local payload
  local code
  local i
  for i in $(seq 1 "$attempts"); do
    order_id="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
    idem="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
    if [[ -n "${READY_CHECKOUT_BODY//[[:space:]]/}" ]]; then
      payload="$READY_CHECKOUT_BODY"
    else
      payload="$($PYTHON_BIN -c "import json; print(json.dumps({'order_id': '$order_id', 'total': 1200, 'items': [{'product_id': 'sku-1', 'quantity': 1}]}))")"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Idempotency-Key: $idem" \
      -d "$payload" \
      "${base_url%/}/checkout" || echo "000")"
    if [[ "$code" == 2* ]]; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

ensure_readiness() {
  local dep
  for dep in "${READINESS_DEPLOYMENTS[@]}"; do
    local resolved
    resolved="$(resolve_deployment "$dep" || true)"
    if [[ -z "${resolved//[[:space:]]/}" ]]; then
      die "readiness deployment '$dep' not found"
    fi
    local selector
    selector="$(selector_for_deploy "$resolved")"
    if [[ -z "${selector//[[:space:]]/}" ]]; then
      die "cannot derive selector for readiness deployment '$resolved'"
    fi
    log "Readiness check: deployment=$resolved selector=$selector"
    ensure_deploy_ready "$resolved" "$selector"
  done

  ensure_order_pf
  if ! wait_http_ready "$BENCH_BASE_URL" "$READY_HTTP_PATH" "$READY_HTTP_RETRIES" "$READY_HTTP_SLEEP"; then
    die "readiness check failed for ${BENCH_BASE_URL}${READY_HTTP_PATH}"
  fi
  if ! warmup_checkout "$BENCH_BASE_URL" "$READY_CHECKOUT_RETRIES" "$READY_CHECKOUT_SLEEP"; then
    die "readiness checkout warmup failed after ${READY_CHECKOUT_RETRIES} attempts"
  fi
}

# ----------------------------
# Netem helpers (profiles)
# ----------------------------
apply_tc_cmd() {
  local pod="$1"
  shift
  kubectl exec -n "$NAMESPACE" "$pod" -- "$@" >/dev/null 2>&1 || true
}

pod_has_tc() {
  local pod="$1"
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "command -v tc >/dev/null 2>&1" >/dev/null 2>&1
}

ensure_tc_or_warn() {
  local pod="$1"
  local selector="$2"
  if pod_has_tc "$pod"; then
    return 0
  fi
  if [[ "$NETEM_REQUIRE_TC" == "1" ]]; then
    die "tc not found in pod $pod (selector=$selector); set NETEM_REQUIRE_TC=0 to skip netem for this pod"
  fi
  log "WARNING: tc not found in pod $pod (selector=$selector); skipping netem"
  return 1
}

apply_netem_profile() {
  local profile="$1"
  local delay_ms="$2"
  local jitter_ms="$3"

  local selector
  local pod
  for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "${selector//[[:space:]]/}" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      if ! ensure_tc_or_warn "$pod" "$selector"; then
        continue
      fi
      apply_tc_cmd "$pod" tc qdisc del dev eth0 root

      case "$profile" in
        normal)
          if [[ "$delay_ms" != "0" || "$jitter_ms" != "0" ]]; then
            apply_tc_cmd "$pod" tc qdisc replace dev eth0 root netem delay "${delay_ms}ms" "${jitter_ms}ms"
          fi
          ;;
        lossy)
          apply_tc_cmd "$pod" tc qdisc replace dev eth0 root netem \
            delay "${delay_ms}ms" "${jitter_ms}ms" \
            loss "${LOSSY_LOSS_PCT}%" \
            duplicate "${LOSSY_DUP_PCT}%" \
            reorder "${LOSSY_REORDER_PCT}%" "${LOSSY_REORDER_CORR}%"
          ;;
        congested)
          apply_tc_cmd "$pod" tc qdisc replace dev eth0 root handle 1: netem \
            delay "${delay_ms}ms" "${jitter_ms}ms" \
            loss "${CONGEST_LOSS_PCT}%"
          apply_tc_cmd "$pod" tc qdisc replace dev eth0 parent 1:1 handle 10: tbf \
            rate "$CONGEST_RATE" \
            burst "$CONGEST_BURST" \
            limit "$CONGEST_LIMIT_PKTS"
          ;;
        *)
          die "unknown net profile: $profile"
          ;;
      esac
    done
  done
}

clear_netem() {
  local selector
  local pod
  for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "${selector//[[:space:]]/}" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      if ! ensure_tc_or_warn "$pod" "$selector"; then
        continue
      fi
      apply_tc_cmd "$pod" tc qdisc del dev eth0 root
    done
  done
}

sum_net_bytes() {
  local direction="$1"  # rx or tx
  local total=0
  local selector
  local pod
  for selector in "${METRICS_SELECTORS[@]}"; do
    selector="$(trim "$selector")"
    [[ -n "${selector//[[:space:]]/}" ]] || continue
    for pod in $(list_pods_for "$selector"); do
      local val
      val="$(kubectl exec -n "$NAMESPACE" "$pod" -- cat "/sys/class/net/eth0/statistics/${direction}_bytes" 2>/dev/null || echo "")"
      if [[ -n "$val" ]]; then
        total=$((total + val))
      fi
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
    echo "netem_selectors=${NETEM_TARGET_SELECTORS[*]}"
    echo
    local selector
    local pod
    for selector in "${NETEM_TARGET_SELECTORS[@]}"; do
      selector="$(trim "$selector")"
      [[ -n "${selector//[[:space:]]/}" ]] || continue
      echo "selector=$selector"
      for pod in $(list_pods_for "$selector"); do
        echo "pod=$pod"
        if ! ensure_tc_or_warn "$pod" "$selector"; then
          echo "tc not found in pod; skipping tc qdisc inspection"
          echo "---"
          continue
        fi
        kubectl exec -n "$NAMESPACE" "$pod" -- tc qdisc show dev eth0 || true
        kubectl exec -n "$NAMESPACE" "$pod" -- tc -s qdisc show dev eth0 || true
        echo "---"
      done
      echo
    done

    if [[ "${NETEM_VALIDATE}" == "1" && ${#PROBE_SERVICES[@]} -gt 0 ]]; then
      echo "probe_services=${PROBE_SERVICES[*]}"
      probe_name="netem-probe-$(date +%s%N | tail -c 8)"
      kubectl run -n "$NAMESPACE" --rm -i "$probe_name" --restart=Never --image "$PROBE_IMAGE" --command -- sh -c "
set -e
for svc in ${PROBE_SERVICES[*]}; do
  echo \"=== \$svc ===\"
  ping -c 5 \"\$svc.${NAMESPACE}.svc.cluster.local\" || true
  wget -qO- --timeout=2 \"http://\$svc.${NAMESPACE}.svc.cluster.local:8080/health\" >/dev/null 2>&1 || true
done
" || true
    fi
  } >"$log_file" 2>&1

  echo "$log_file"
}

METRICS_WARNING_EMITTED="0"

start_metrics_sampler() {
  local sample_file="$1"
  local interval="$2"
  : >"$sample_file"

  (
    while true; do
      local selector
      for selector in "${METRICS_SELECTORS[@]}"; do
        selector="$(trim "$selector")"
        [[ -n "${selector//[[:space:]]/}" ]] || continue
        local output
        output="$(kubectl top pods -n "$NAMESPACE" -l "$selector" --no-headers 2>&1 || true)"
        if [[ -z "$output" ]]; then
          continue
        fi
        if [[ "$output" == *"Metrics API not available"* || "$output" == *"metrics.k8s.io"* ]]; then
          if [[ "$METRICS_WARNING_EMITTED" == "0" ]]; then
            log "WARNING: Metrics API not available (kubectl top returned: $output)"
            METRICS_WARNING_EMITTED="1"
          fi
          continue
        fi
        echo "$output" | awk -v sel="$selector" -v ts="$(date +%s)" '{
          gsub("m","",$2); gsub("Mi","",$3);
          cpu+=$2; mem+=$3
        } END {printf "%s\t%s\t%d\t%d\n", ts, sel, cpu, mem}'
      done >>"$sample_file"
      sleep "$interval"
    done
  ) &

  echo $!
}

summarize_metrics_samples() {
  local sample_file="$1"
  if [[ ! -s "$sample_file" ]]; then
    echo ""
    return
  fi
  "$PYTHON_BIN" -c '
import json, sys
from collections import defaultdict

data = defaultdict(lambda: {"cpu": [], "mem": []})
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.strip().split("\t")
        if len(parts) != 4:
            continue
        _, selector, cpu, mem = parts
        try:
            data[selector]["cpu"].append(int(cpu))
            data[selector]["mem"].append(int(mem))
        except ValueError:
            continue

def stats(values):
    if not values:
        return {"avg": None, "max": None, "samples": 0}
    return {
        "avg": round(sum(values) / len(values), 2),
        "max": max(values),
        "samples": len(values),
    }

selectors = {}
total_cpu = []
total_mem = []
for selector, vals in data.items():
    selectors[selector] = {
        "cpu_millicores": stats(vals["cpu"]),
        "memory_mib": stats(vals["mem"]),
    }
    total_cpu.extend(vals["cpu"])
    total_mem.extend(vals["mem"])

summary = {
    "selectors": selectors,
    "total": {
        "cpu_millicores": stats(total_cpu),
        "memory_mib": stats(total_mem),
    },
}
print(json.dumps(summary, separators=(",", ":")))
' "$sample_file"
}

# ----------------------------
# Port-forward management for order-service (restart after TX_MODE switch)
# ----------------------------
ORDER_PF_PID=""
ORDER_PF_LOG=""
ORDER_PF_LOG_LINES=0

have_port_listener() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -qE "(:|\\])${port}$"
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

check_tcp_open() {
  local host="$1"
  local port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
    return $?
  fi
  bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  return $?
}

pf_log_has_disconnects() {
  if [[ -z "$ORDER_PF_LOG" || ! -f "$ORDER_PF_LOG" ]]; then
    return 1
  fi
  local total_lines
  total_lines="$(wc -l < "$ORDER_PF_LOG" | tr -d ' ')"
  local new_lines=$((total_lines - ORDER_PF_LOG_LINES))
  if (( new_lines <= 0 )); then
    return 1
  fi
  ORDER_PF_LOG_LINES="$total_lines"
  if tail -n "$new_lines" "$ORDER_PF_LOG" | grep -Eiq "lost connection to pod|network namespace.*closed"; then
    return 0
  fi
  return 1
}

kill_existing_order_pf() {
  # Kill only port-forward processes that match namespace + svc + local port mapping
  # This is intentionally narrow to avoid killing other port-forwards.
  pkill -f "kubectl.*port-forward.*-n[[:space:]]+$NAMESPACE.*svc/$ORDER_SERVICE_NAME[[:space:]]+$ORDER_PF_PORT:8080" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*-n[[:space:]]+$NAMESPACE.*svc/$ORDER_SERVICE_NAME[[:space:]]+$ORDER_PF_PORT:8080" >/dev/null 2>&1 || true
}

stop_order_pf() {
  if [[ -n "${ORDER_PF_PID//[[:space:]]/}" ]]; then
    if kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
      kill "$ORDER_PF_PID" >/dev/null 2>&1 || true
      local i
      for i in $(seq 1 20); do
        if ! kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
          break
        fi
        sleep 0.1
      done
      if kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
        kill -9 "$ORDER_PF_PID" >/dev/null 2>&1 || true
      fi
    fi
  fi
  ORDER_PF_PID=""
  ORDER_PF_LOG=""
  ORDER_PF_LOG_LINES=0
  # also clean up any matching stray processes
  kill_existing_order_pf
}

start_order_pf() {
  stop_order_pf

  # ensure port is not occupied by another process
  if have_port_listener "$ORDER_PF_PORT"; then
    # If it's our old port-forward, kill it; otherwise fail clearly
    kill_existing_order_pf
    sleep 0.2
  fi
  if have_port_listener "$ORDER_PF_PORT"; then
    die "local port $ORDER_PF_PORT is already in use; stop conflicting process or set ORDER_PF_PORT=18080"
  fi

  ORDER_PF_LOG="${ORDER_PF_LOG_DIR}/order-${timestamp}-txmode.log"
  : > "$ORDER_PF_LOG" || true

  log "Starting port-forward for order: svc/$ORDER_SERVICE_NAME -> ${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
  kubectl -n "$NAMESPACE" port-forward "svc/$ORDER_SERVICE_NAME" "${ORDER_PF_PORT}:8080" --address "$ORDER_PF_ADDR" >"$ORDER_PF_LOG" 2>&1 &
  ORDER_PF_PID="$!"
  ORDER_PF_LOG_LINES=0

  # wait until port starts listening or process dies
  local i
  for i in $(seq 1 80); do
    if have_port_listener "$ORDER_PF_PORT" || check_tcp_open "$ORDER_PF_ADDR" "$ORDER_PF_PORT"; then
      log "Port-forward is listening on ${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
      return 0
    fi
    if ! kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
      log "Port-forward process exited early; last log lines:"
      tail -n 80 "$ORDER_PF_LOG" >&2 || true
      die "order port-forward failed to start"
    fi
    sleep 0.1
  done

  log "Timeout while waiting for port-forward to listen; last log lines:"
  tail -n 80 "$ORDER_PF_LOG" >&2 || true
  die "order port-forward did not start listening on ${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
}

restart_order_pf() {
  log "Restarting order port-forward"
  stop_order_pf
  start_order_pf
}

ensure_order_pf() {
  if [[ "$MANAGE_ORDER_PF" != "1" ]]; then
    return 0
  fi
  if [[ -z "$ORDER_PF_PID" || ! -e "/proc/$ORDER_PF_PID" ]]; then
    restart_order_pf
    return 0
  fi
  if ! have_port_listener "$ORDER_PF_PORT" && ! check_tcp_open "$ORDER_PF_ADDR" "$ORDER_PF_PORT"; then
    restart_order_pf
    return 0
  fi
  if pf_log_has_disconnects; then
    restart_order_pf
  fi
}

# ----------------------------
# Bench helpers
# ----------------------------
extract_first_json_object() {
  "$PYTHON_BIN" -c '
import json, sys
text = sys.stdin.read()
if not text.strip():
    sys.stderr.write("ERROR: empty bench-runner output\n")
    sys.exit(2)

dec = json.JSONDecoder()
for i, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, _ = dec.raw_decode(text[i:])
        if isinstance(obj, dict):
            print(json.dumps(obj, separators=(",", ":")))
            sys.exit(0)
    except Exception:
        pass

sys.stderr.write("ERROR: no JSON object found in bench-runner output\n")
sys.stderr.write("----- output prefix -----\n")
sys.stderr.write(text[:1200] + "\n")
sys.stderr.write("----- end prefix -----\n")
sys.exit(3)
'
}

run_bench_json() {
  local base_url="$1"
  local tx="$2"
  local conc="$3"
  local log_file="$4"

  local out
  local args=("$BENCH_BIN" -base-url "$base_url" -total "$tx" -concurrency "$conc")
  if [[ "$AWAIT_FINAL" == "1" ]]; then
    args+=(-await-final -final-timeout "$FINAL_TIMEOUT" -final-interval "$FINAL_INTERVAL" -final-statuses "$FINAL_STATUSES")
  fi
  if ! out="$("${args[@]}" 2>"$log_file")"; then
    log "bench-runner failed; see $log_file"
    return 1
  fi
  if [[ -z "${out//[[:space:]]/}" ]]; then
    log "bench-runner produced empty output; see $log_file"
    return 1
  fi
  printf '%s' "$out" | extract_first_json_object
}

run_bench_json_with_retry() {
  local base_url="$1"
  local tx="$2"
  local conc="$3"
  local log_file="$4"

  local attempt
  for attempt in 1 2; do
    if bench_json="$(run_bench_json "$base_url" "$tx" "$conc" "$log_file")"; then
      if [[ -n "${bench_json//[[:space:]]/}" ]]; then
        printf '%s' "$bench_json"
        return 0
      fi
      log "bench-runner returned empty JSON payload; see $log_file"
    fi
    if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
      log "bench-runner failed (attempt $attempt); restarting port-forward and retrying once"
      restart_order_pf
    fi
    sleep 0.5
  done

  return 1
}

bench_invalid_reason() {
  "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
total = d.get("total_requests", 0) or 0
errors = d.get("error_requests", 0) or 0
status_counts = d.get("status_counts", {}) or {}
error_classes = d.get("error_classes", {}) or {}
transport = error_classes.get("transport", 0) or 0
status_zero = status_counts.get("0", 0) or 0

if total > 0 and errors == total and (transport == total or status_zero == total):
    print("transport_all")
    sys.exit(0)
if total > 0 and errors == total and status_zero == total:
    print("status_zero_all")
    sys.exit(0)
print("")
' 
}

smoke_check() {
  local base_url="$1"
  local order_id
  local idempotency_key
  order_id="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"
  idempotency_key="$($PYTHON_BIN -c 'import uuid; print(uuid.uuid4())')"

  local payload
  payload="$($PYTHON_BIN -c "import json; print(json.dumps({'order_id': '$order_id', 'total': 1200, 'items': [{'product_id': 'sku-1', 'quantity': 1}]}))")"

  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $idempotency_key" \
    -d "$payload" \
    "${base_url%/}/checkout" || echo "000")"

  log "Smoke check /checkout -> HTTP $http_code"
  if [[ "$http_code" != 2* ]]; then
    die "smoke check failed with HTTP $http_code"
  fi
}

# ----------------------------
# Cleanup
# ----------------------------
cleanup() {
  clear_netem || true
  if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
    stop_order_pf || true
  fi
}
trap cleanup EXIT

# ----------------------------
# Prepare base url used by bench
# ----------------------------
# For reliability: always use 127.0.0.1 with managed port-forward
BENCH_BASE_URL="$ORDER_BASE_URL"
if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
  BENCH_BASE_URL="http://${ORDER_PF_ADDR}:${ORDER_PF_PORT}"
fi
log "Bench base url: $BENCH_BASE_URL"

# ----------------------------
# Main loop: TX_MODE -> net profile -> replicas -> latency/jitter -> tx
# ----------------------------
for mode in "${TX_MODES[@]}"; do
  log "Switching TX_MODE to '$mode'"

  if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
    # stop PF BEFORE rollout to avoid 'namespace closed' noise and avoid dead processes
    stop_order_pf
  fi

  kubectl -n "$NAMESPACE" set env "deployment/${DEPLOYMENT}" "TX_MODE=${mode}" >/dev/null
  kubectl -n "$NAMESPACE" rollout restart "deployment/${DEPLOYMENT}" >/dev/null
  ensure_rollout
  wait_pods_stable "$PODS_READY_TIMEOUT_SECONDS"
  sleep 5

  if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
    start_order_pf
  fi

  ensure_readiness

  if [[ "$SMOKE" == "1" ]]; then
    smoke_check "$BENCH_BASE_URL"
  fi

  for profile in "${NET_PROFILES[@]}"; do
    for replicas in "${REPLICAS_LIST[@]}"; do
      log "Scale replicas=$replicas (mode=$mode, profile=$profile)"
      scale_replicas "$replicas"

      for latency in "${LATENCIES_MS[@]}"; do
        for jitter in "${JITTERS_MS[@]}"; do
          effective_latency="$latency"
          effective_jitter="$jitter"
          if [[ "$profile" == "congested" ]]; then
            effective_latency="$CONGEST_DELAY_MS"
            effective_jitter="$CONGEST_JITTER_MS"
          fi

          # Apply network emulation profile on pods
          apply_netem_profile "$profile" "$effective_latency" "$effective_jitter"
          sleep "$WAIT_AFTER_NETEM"
          netem_log="$(capture_netem_state "$profile" "$effective_latency" "$effective_jitter")"

          if [[ "$WARMUP_ENABLED" == "1" && "$WARMUP_TX" != "0" ]]; then
            log "WARMUP mode=$mode profile=$profile replicas=$replicas concurrency=$WARMUP_CONCURRENCY tx=$WARMUP_TX"
            warmup_log="${BENCH_LOG_DIR}/warmup-${timestamp}-${mode}-${profile}-r${replicas}.log"
            run_bench_json_with_retry "$BENCH_BASE_URL" "$WARMUP_TX" "$WARMUP_CONCURRENCY" "$warmup_log" >/dev/null || true
          fi

          for tx in "${TX_COUNTS[@]}"; do
            for conc in "${CONCURRENCY_LIST[@]}"; do
              for run_id in $(seq 1 "$BENCH_RUNS_PER_POINT"); do
                log "RUN mode=$mode profile=$profile replicas=$replicas conc=$conc run=${run_id}/${BENCH_RUNS_PER_POINT} latency=${effective_latency}ms jitter=${effective_jitter}ms tx=$tx"

                ensure_order_pf
                net_before_rx="$(sum_net_bytes rx)"
                net_before_tx="$(sum_net_bytes tx)"

                bench_log="${BENCH_LOG_DIR}/bench-${timestamp}-${mode}-${profile}-r${replicas}-tx${tx}-c${conc}-run${run_id}.log"
                attempt=0
                while true; do
                  attempt=$((attempt + 1))
                  sample_file="${BENCH_LOG_DIR}/metrics-${timestamp}-${mode}-${profile}-r${replicas}-tx${tx}-c${conc}-run${run_id}-a${attempt}.log"
                  metrics_pid="$(start_metrics_sampler "$sample_file" "$METRICS_SAMPLE_INTERVAL")"

                  if ! bench_json="$(run_bench_json_with_retry "$BENCH_BASE_URL" "$tx" "$conc" "$bench_log")"; then
                    kill "$metrics_pid" >/dev/null 2>&1 || true
                    die "bench-runner failed after retry; see $bench_log"
                  fi
                  kill "$metrics_pid" >/dev/null 2>&1 || true

                  if [[ -z "${bench_json//[[:space:]]/}" ]]; then
                    die "bench-runner returned empty JSON after retry; see $bench_log"
                  fi

                  invalid_reason="$(printf '%s' "$bench_json" | bench_invalid_reason)"
                  if [[ -z "${invalid_reason//[[:space:]]/}" ]]; then
                    break
                  fi
                  log "Invalid run detected (${invalid_reason}); retrying after ${INVALID_RETRY_SLEEP}s (attempt ${attempt}/${INVALID_RETRY_LIMIT})"
                  if (( attempt >= INVALID_RETRY_LIMIT )); then
                    die "invalid run persisted after ${INVALID_RETRY_LIMIT} attempts; see $bench_log"
                  fi
                  sleep "$INVALID_RETRY_SLEEP"
                done

                net_after_rx="$(sum_net_bytes rx)"
                net_after_tx="$(sum_net_bytes tx)"

            # IMPORTANT:
            # Do NOT use:  printf '%s' "$bench_json" | python - <<'PY' ... PY
            # Because `python -` reads the PROGRAM from stdin, so the piped JSON never reaches json.load(sys.stdin).
            # Always use `python -c '...'` here so stdin remains the JSON stream.
            bench_fields="$(printf '%s' "$bench_json" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
avg = d.get("avg_latency_ms", 0)
p95 = d.get("p95_latency_ms", 0)
p99 = d.get("p99_latency_ms", 0)
thr = d.get("throughput_rps", 0)
err = d.get("error_requests", 0)
dur = d.get("duration_seconds", 0)
status_counts = d.get("status_counts", {})
error_classes = d.get("error_classes", {})
finalized = d.get("finalized_requests", 0)
final_timeouts = d.get("final_timeouts", 0)
first_error = (d.get("first_error", "") or "").replace("\n", " ").replace("\t", " ")
print("{:.2f}\t{:.2f}\t{:.2f}\t{:.2f}\t{}\t{:.4f}\t{}\t{}\t{}\t{}\t{}".format(
    avg, p95, p99, thr, err, dur,
    json.dumps(status_counts, separators=(",", ":")),
    json.dumps(error_classes, separators=(",", ":")),
    finalized, final_timeouts,
    first_error,
))
')"


            avg_latency="$(echo "$bench_fields" | awk '{print $1}')"
            p95_latency="$(echo "$bench_fields" | awk '{print $2}')"
            p99_latency="$(echo "$bench_fields" | awk '{print $3}')"
            throughput="$(echo "$bench_fields" | awk '{print $4}')"
            errors="$(echo "$bench_fields" | awk '{print $5}')"
            duration="$(echo "$bench_fields" | awk '{print $6}')"
            status_counts="$(echo "$bench_fields" | cut -f7)"
            error_classes="$(echo "$bench_fields" | cut -f8)"
            finalized="$(echo "$bench_fields" | awk '{print $9}')"
            final_timeouts="$(echo "$bench_fields" | awk '{print $10}')"
            first_error="$(echo "$bench_fields" | cut -f11-)"

            if [[ "$errors" != "0" && -n "$first_error" ]]; then
              log "ERRORS mode=$mode profile=$profile -> $first_error"
            fi

              metrics_summary="$(summarize_metrics_samples "$sample_file")"
              if [[ -z "${metrics_summary//[[:space:]]/}" ]]; then
                metrics_summary="null"
              fi
              cpu_avg=""
              cpu_max=""
              mem_avg=""
              mem_max=""
              if [[ -n "${metrics_summary//[[:space:]]/}" ]]; then
                cpu_avg="$(echo "$metrics_summary" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); v=d.get("total",{}).get("cpu_millicores",{}).get("avg"); print("" if v is None else v)')"
                cpu_max="$(echo "$metrics_summary" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); v=d.get("total",{}).get("cpu_millicores",{}).get("max"); print("" if v is None else v)')"
                mem_avg="$(echo "$metrics_summary" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); v=d.get("total",{}).get("memory_mib",{}).get("avg"); print("" if v is None else v)')"
                mem_max="$(echo "$metrics_summary" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); v=d.get("total",{}).get("memory_mib",{}).get("max"); print("" if v is None else v)')"
              fi

            rx_delta=$((net_after_rx - net_before_rx))
            tx_delta=$((net_after_tx - net_before_tx))

            rx_rate=0
            tx_rate=0
            if [[ -n "$duration" && "$duration" != "0" ]]; then
              rx_rate="$($PYTHON_BIN -c "print(int(${rx_delta} / ${duration}))")"
              tx_rate="$($PYTHON_BIN -c "print(int(${tx_delta} / ${duration}))")"
            fi

            net_rx_kbps="$($PYTHON_BIN -c "print(round(${rx_rate} / 1024, 2))")"
            net_tx_kbps="$($PYTHON_BIN -c "print(round(${tx_rate} / 1024, 2))")"

              if [[ "$first_record" == true ]]; then
                first_record=false
              else
                echo "," >> "$json_file"
              fi

              {
                printf '%s\n' "  {"
                printf '    "tx_mode": %s,\n' "\"$mode\""
                printf '    "net_profile": %s,\n' "\"$profile\""
                printf '    "replicas": %s,\n' "$replicas"
                printf '    "concurrency": %s,\n' "$conc"
                printf '    "run_id": %s,\n' "$run_id"
                printf '    "transactions": %s,\n' "$tx"
                printf '    "latency_ms": %s,\n' "$effective_latency"
                printf '    "jitter_ms": %s,\n' "$effective_jitter"
                printf '    "netem_validation_log": %s,\n' "\"$netem_log\""
                printf '    "bench": %s,\n' "$(printf '%s' "$bench_json" | tr -d '\n')"
                printf '    "resources": %s,\n' "${metrics_summary:-null}"
                printf '    "network": {"rx_bytes": %s, "tx_bytes": %s, "rx_bps": %s, "tx_bps": %s}\n' \
                  "$rx_delta" "$tx_delta" "$rx_rate" "$tx_rate"
                printf '%s\n' "  }"
              } >> "$json_file"

              md_first_error="${first_error//|/ }"
              md_status_counts="${status_counts//|/ }"
              md_error_classes="${error_classes//|/ }"

              printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                "$mode" "$profile" "$replicas" "$conc" "$run_id" "$tx" "$effective_latency" "$effective_jitter" "$avg_latency" "$p95_latency" "$p99_latency" \
                "$throughput" "$errors" "$md_error_classes" "$md_status_counts" "${finalized}/${final_timeouts}" "$md_first_error" \
                "${cpu_avg:-n/a}/${cpu_max:-n/a}" "${mem_avg:-n/a}/${mem_max:-n/a}" "$net_rx_kbps" "$net_tx_kbps" >> "$md_file"

                log "DONE mode=$mode profile=$profile replicas=$replicas conc=$conc run=$run_id -> avg=${avg_latency}ms p95=${p95_latency}ms thr=${throughput}rps err=${errors}"
              done
            done
          done

          clear_netem
        done
      done
    done
  done
done

echo "]" >> "$json_file"
log "Results saved to $json_file and $md_file"
