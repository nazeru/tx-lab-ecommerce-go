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

# ----------------------------
# Config (env overrides)
# ----------------------------
NAMESPACE="$(trim "${NAMESPACE:-txlab}")"
DEPLOYMENT="$(trim "${DEPLOYMENT:-order}")"      # логическое имя (order), будет разрешено в реальное имя deployment
APP_LABEL="$(trim "${APP_LABEL:-order}")"        # больше не обязателен, оставлен для совместимости

ORDER_BASE_URL="$(trim "${ORDER_BASE_URL:-http://localhost:8080}")"
INVENTORY_BASE_URL="$(trim "${INVENTORY_BASE_URL:-}")"
PAYMENT_BASE_URL="$(trim "${PAYMENT_BASE_URL:-}")"
SHIPPING_BASE_URL="$(trim "${SHIPPING_BASE_URL:-}")"

RESULTS_DIR="$(trim "${RESULTS_DIR:-results}")"
CONCURRENCY="$(trim "${CONCURRENCY:-10}")"
BENCH_SCENARIO="$(trim "${BENCH_SCENARIO:-all}")"
BENCH_TIMEOUT="$(trim "${BENCH_TIMEOUT:-}")"
TX_MODES_RAW="$(trim "${TX_MODES:-}")"
TX_MODE_DEPLOYMENT="$(trim "${TX_MODE_DEPLOYMENT:-}")"
SKIP_TX_MODE_SWITCH="$(trim "${SKIP_TX_MODE_SWITCH:-}")"

REPLICAS_LIST=(1 3 5 7 10)
TX_COUNTS=(1000)
LATENCIES_MS=(100 500 1000)
JITTERS_MS=(20)
TX_MODES_DEFAULT=("twopc" "saga" "tcc" "outbox")

# Fallback if whitespace-only was provided
[[ -n "$NAMESPACE" ]] || NAMESPACE="txlab"
[[ -n "$DEPLOYMENT" ]] || DEPLOYMENT="order"
[[ -n "$ORDER_BASE_URL" ]] || ORDER_BASE_URL="http://localhost:8080"
[[ -n "$RESULTS_DIR" ]] || RESULTS_DIR="results"
[[ -n "$CONCURRENCY" ]] || CONCURRENCY="10"
[[ -n "$BENCH_SCENARIO" ]] || BENCH_SCENARIO="all"
SKIP_TX_MODE_SWITCH="${SKIP_TX_MODE_SWITCH:-0}"

# ----------------------------
# Tools
# ----------------------------
PYTHON_BIN=${PYTHON_BIN:-python3}
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3/python not found in PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v go >/dev/null 2>&1 || die "go not found in PATH"

# ----------------------------
# Resolve deployment name
# ----------------------------
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' not found"

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

  # 3) last resort: any deployment containing wanted, but exclude postgres
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
if [[ -z "${TX_MODE_DEPLOYMENT//[[:space:]]/}" ]]; then
  TX_MODE_DEPLOYMENT="$DEPLOYMENT"
else
  REAL_TX_MODE_DEPLOYMENT="$(resolve_deployment "$TX_MODE_DEPLOYMENT" || true)"
  if [[ -z "${REAL_TX_MODE_DEPLOYMENT//[[:space:]]/}" ]]; then
    echo "ERROR: tx mode deployment '$TX_MODE_DEPLOYMENT' not found in namespace '$NAMESPACE'." >&2
    echo "Deployments in '$NAMESPACE':" >&2
    kubectl get deploy -n "$NAMESPACE" >&2 || true
    exit 1
  fi
  TX_MODE_DEPLOYMENT="$REAL_TX_MODE_DEPLOYMENT"
fi

# ----------------------------
# Derive pod label selector from deployment.spec.selector.matchLabels
# ----------------------------
LABEL_SELECTOR="$(
  kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" -o json | "$PYTHON_BIN" -c '
import json,sys
d=json.load(sys.stdin)
ml=(d.get("spec",{}).get("selector",{}) or {}).get("matchLabels") or {}
# k8s label selector: k=v,k2=v2
print(",".join([f"{k}={v}" for k,v in ml.items()]))
'
)"
if [[ -z "${LABEL_SELECTOR//[[:space:]]/}" ]]; then
  die "cannot derive LABEL_SELECTOR from deployment '$DEPLOYMENT' (.spec.selector.matchLabels is empty)"
fi

# ----------------------------
# Build bench-runner once
# ----------------------------
BENCH_BIN=${BENCH_BIN:-/tmp/bench-runner}
go build -o "$BENCH_BIN" ./cmd/bench-runner

# ----------------------------
# Output files
# ----------------------------
timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
json_file="$RESULTS_DIR/benchmarks-$timestamp.json"
md_file="$RESULTS_DIR/benchmarks-$timestamp.md"

mkdir -p "$RESULTS_DIR"

cat <<HEADER > "$md_file"
# Benchmark results ($timestamp)

* Namespace: $NAMESPACE
* Deployment: $DEPLOYMENT
* TX mode deployment: $TX_MODE_DEPLOYMENT
* Pod selector: $LABEL_SELECTOR
* Base URL: $ORDER_BASE_URL
* Scenario: $BENCH_SCENARIO
* Concurrency: $CONCURRENCY
* TX modes: ${TX_MODES_RAW:-${TX_MODES_DEFAULT[*]}}
* Network profiles: latencies [${LATENCIES_MS[*]}] ms, jitters [${JITTERS_MS[*]}] ms
* Bench timeout: ${BENCH_TIMEOUT:-default}

| TX mode | Replicas | Transactions | Latency (ms) | Jitter (ms) | Avg latency (ms) | Throughput (rps) | Errors | CPU (m) | Memory (Mi) | Net RX (KB/s) | Net TX (KB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER

echo "[" > "$json_file"
first_record=true

# ----------------------------
# K8s helpers
# ----------------------------
ensure_rollout() {
  kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE"
}

dump_rollout_diagnostics() {
  echo "---- deployment/${TX_MODE_DEPLOYMENT} describe ----" >&2
  kubectl describe deployment "$TX_MODE_DEPLOYMENT" -n "$NAMESPACE" >&2 || true
  echo "---- pods (selector: ${LABEL_SELECTOR}) ----" >&2
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o wide >&2 || true
  echo "---- events (tail) ----" >&2
  kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp | tail -n 50 >&2 || true
}

switch_tx_mode() {
  local mode=$1

  if [[ "$SKIP_TX_MODE_SWITCH" == "1" ]]; then
    echo "SKIP_TX_MODE_SWITCH=1: not switching TX_MODE; tagging results with $mode" >&2
    return 0
  fi

  if ! kubectl -n "$NAMESPACE" set env deployment/"$TX_MODE_DEPLOYMENT" TX_MODE="$mode"; then
    dump_rollout_diagnostics
    return 1
  fi
  if ! kubectl -n "$NAMESPACE" rollout restart deployment/"$TX_MODE_DEPLOYMENT"; then
    dump_rollout_diagnostics
    return 1
  fi
  if ! kubectl -n "$NAMESPACE" rollout status deployment/"$TX_MODE_DEPLOYMENT" --timeout=5m; then
    dump_rollout_diagnostics
    return 1
  fi
  if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "$LABEL_SELECTOR" --timeout=3m; then
    dump_rollout_diagnostics
    return 1
  fi

  echo "TX_MODE switched to $mode" >&2
}

scale_replicas() {
  local replicas=$1
  kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas="$replicas"
  ensure_rollout
}

list_pods() {
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}'
}

apply_netem() {
  local delay_ms=$1
  local jitter_ms=$2
  local pod
  for pod in $(list_pods); do
    kubectl exec -n "$NAMESPACE" "$pod" -- tc qdisc replace dev eth0 root netem delay "${delay_ms}ms" "${jitter_ms}ms" >/dev/null 2>&1 || true
  done
}

clear_netem() {
  local pod
  for pod in $(list_pods); do
    kubectl exec -n "$NAMESPACE" "$pod" -- tc qdisc del dev eth0 root >/dev/null 2>&1 || true
  done
}

cleanup() {
  clear_netem || true
}
trap cleanup EXIT

sum_net_bytes() {
  local direction=$1
  local total=0
  local pod
  for pod in $(list_pods); do
    local val
    val=$(kubectl exec -n "$NAMESPACE" "$pod" -- cat "/sys/class/net/eth0/statistics/${direction}_bytes" 2>/dev/null || echo "")
    if [[ -n "$val" ]]; then
      total=$((total + val))
    fi
  done
  echo "$total"
}

capture_top() {
  local output
  output=$(kubectl top pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null || true)
  if [[ -z "$output" ]]; then
    echo ""
    return
  fi
  echo "$output" | awk '{gsub("m","",$2); gsub("Mi","",$3); cpu+=$2; mem+=$3} END {printf "%d %d", cpu, mem}'
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
  local tx=$1
  local conc=$2
  local out
  if [[ -n "${BENCH_TIMEOUT//[[:space:]]/}" ]]; then
    out=$("$BENCH_BIN" -base-url "$ORDER_BASE_URL" -total "$tx" -concurrency "$conc" -timeout "$BENCH_TIMEOUT" 2>&1)
  else
    out=$("$BENCH_BIN" -base-url "$ORDER_BASE_URL" -total "$tx" -concurrency "$conc" 2>&1)
  fi
  printf '%s' "$out" | extract_first_json_object
}

# ----------------------------
# Main loop
# ----------------------------
tx_modes=()
if [[ -n "${TX_MODES_RAW//[[:space:]]/}" ]]; then
  IFS=' ' read -r -a tx_modes <<< "$TX_MODES_RAW"
else
  tx_modes=("${TX_MODES_DEFAULT[@]}")
fi

for mode in "${tx_modes[@]}"; do
  switch_tx_mode "$mode"

  for replicas in "${REPLICAS_LIST[@]}"; do
    scale_replicas "$replicas"

    for latency in "${LATENCIES_MS[@]}"; do
      for jitter in "${JITTERS_MS[@]}"; do
        apply_netem "$latency" "$jitter"

        for tx in "${TX_COUNTS[@]}"; do
          net_before_rx=$(sum_net_bytes rx)
          net_before_tx=$(sum_net_bytes tx)

          bench_json=$(run_bench_json "$tx" "$CONCURRENCY")

          net_after_rx=$(sum_net_bytes rx)
          net_after_tx=$(sum_net_bytes tx)

          bench_fields=$(printf '%s' "$bench_json" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
avg = d.get("avg_latency_ms", 0)
thr = d.get("throughput_rps", 0)
err = d.get("error_requests", 0)
dur = d.get("duration_seconds", 0)
print(f"{avg:.2f}\t{thr:.2f}\t{err}\t{dur:.4f}")
')

          avg_latency=$(echo "$bench_fields" | awk '{print $1}')
          throughput=$(echo "$bench_fields" | awk '{print $2}')
          errors=$(echo "$bench_fields" | awk '{print $3}')
          duration=$(echo "$bench_fields" | awk '{print $4}')

          top_fields=$(capture_top)
          cpu_m=""
          mem_mi=""
          if [[ -n "$top_fields" ]]; then
            cpu_m=$(echo "$top_fields" | awk '{print $1}')
            mem_mi=$(echo "$top_fields" | awk '{print $2}')
          fi

          rx_delta=$((net_after_rx - net_before_rx))
          tx_delta=$((net_after_tx - net_before_tx))

          rx_rate=0
          tx_rate=0
          if [[ -n "$duration" && "$duration" != "0" ]]; then
            rx_rate=$("$PYTHON_BIN" -c "print(int(${rx_delta} / ${duration}))")
            tx_rate=$("$PYTHON_BIN" -c "print(int(${tx_delta} / ${duration}))")
          fi

          if [[ "$first_record" == true ]]; then
            first_record=false
          else
            echo "," >> "$json_file"
          fi

          {
            printf '%s\n' "  {"
            printf '    "tx_mode": "%s",\n' "$mode"
            printf '    "replicas": %s,\n' "$replicas"
            printf '    "transactions": %s,\n' "$tx"
            printf '    "latency_ms": %s,\n' "$latency"
            printf '    "jitter_ms": %s,\n' "$jitter"
            if [[ -n "${BENCH_TIMEOUT//[[:space:]]/}" ]]; then
              printf '    "bench_timeout": "%s",\n' "$BENCH_TIMEOUT"
            fi
            printf '    "bench": %s,\n' "$(printf '%s' "$bench_json" | tr -d '\n')"
            printf '    "resources": {"cpu_millicores": %s, "memory_mib": %s, "network_rx_bytes": %s, "network_tx_bytes": %s, "network_rx_bps": %s, "network_tx_bps": %s}\n' \
              "${cpu_m:-null}" "${mem_mi:-null}" "$rx_delta" "$tx_delta" "$rx_rate" "$tx_rate"
            printf '%s\n' "  }"
          } >> "$json_file"

          net_rx_kbps=$("$PYTHON_BIN" -c "print(round(${rx_rate} / 1024, 2))")
          net_tx_kbps=$("$PYTHON_BIN" -c "print(round(${tx_rate} / 1024, 2))")

          printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$mode" "$replicas" "$tx" "$latency" "$jitter" "$avg_latency" "$throughput" "$errors" \
            "${cpu_m:-n/a}" "${mem_mi:-n/a}" "$net_rx_kbps" "$net_tx_kbps" >> "$md_file"
        done

        clear_netem
      done
    done
  done
done

echo "]" >> "$json_file"
echo "Results saved to $json_file and $md_file"
