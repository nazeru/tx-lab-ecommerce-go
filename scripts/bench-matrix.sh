#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-txlab}
DEPLOYMENT=${DEPLOYMENT:-order}
APP_LABEL=${APP_LABEL:-order}
ORDER_BASE_URL=${ORDER_BASE_URL:-http://localhost:8080}
RESULTS_DIR=${RESULTS_DIR:-results}
CONCURRENCY=${CONCURRENCY:-10}

REPLICAS_LIST=(1 3 5 7 10)
TX_COUNTS=(500 1000 5000 10000 20000)
LATENCIES_MS=(10 100 500)
JITTERS_MS=(5 20 100)

timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
json_file="$RESULTS_DIR/benchmarks-$timestamp.json"
md_file="$RESULTS_DIR/benchmarks-$timestamp.md"

mkdir -p "$RESULTS_DIR"

cat <<HEADER > "$md_file"
# Benchmark results ($timestamp)

* Namespace: $NAMESPACE
* Deployment: $DEPLOYMENT
* Base URL: $ORDER_BASE_URL
* Concurrency: $CONCURRENCY

| Replicas | Transactions | Latency (ms) | Jitter (ms) | Avg latency (ms) | Throughput (rps) | Errors | CPU (m) | Memory (Mi) | Net RX (KB/s) | Net TX (KB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER

echo "[" > "$json_file"
first_record=true

ensure_rollout() {
  kubectl rollout status "deployment/${DEPLOYMENT}" -n "$NAMESPACE"
}

scale_replicas() {
  local replicas=$1
  kubectl scale "deployment/${DEPLOYMENT}" -n "$NAMESPACE" --replicas="$replicas"
  ensure_rollout
}

list_pods() {
  kubectl get pods -n "$NAMESPACE" -l "app=${APP_LABEL}" -o jsonpath='{.items[*].metadata.name}'
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
  output=$(kubectl top pods -n "$NAMESPACE" -l "app=${APP_LABEL}" --no-headers 2>/dev/null || true)
  if [[ -z "$output" ]]; then
    echo ""
    return
  fi
  echo "$output" | awk '{gsub("m","",$2); gsub("Mi","",$3); cpu+=$2; mem+=$3} END {printf "%d %d", cpu, mem}'
}

for replicas in "${REPLICAS_LIST[@]}"; do
  scale_replicas "$replicas"
  for latency in "${LATENCIES_MS[@]}"; do
    for jitter in "${JITTERS_MS[@]}"; do
      apply_netem "$latency" "$jitter"
      for tx in "${TX_COUNTS[@]}"; do
        net_before_rx=$(sum_net_bytes rx)
        net_before_tx=$(sum_net_bytes tx)

        bench_json=$(go run ./cmd/bench-runner -base-url "$ORDER_BASE_URL" -total "$tx" -concurrency "$CONCURRENCY")

        net_after_rx=$(sum_net_bytes rx)
        net_after_tx=$(sum_net_bytes tx)

        bench_fields=$(printf '%s' "$bench_json" | python - <<'PY'
import json
import sys

data = json.load(sys.stdin)
print(
    "{avg:.2f}\t{thr:.2f}\t{err}\t{dur:.4f}".format(
        avg=data.get("avg_latency_ms", 0),
        thr=data.get("throughput_rps", 0),
        err=data.get("error_requests", 0),
        dur=data.get("duration_seconds", 0),
    )
)
PY
        )

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
        if [[ "$duration" != "0" ]]; then
          rx_rate=$(python - <<PY
import math
print(int(${rx_delta} / ${duration}))
PY
          )
          tx_rate=$(python - <<PY
import math
print(int(${tx_delta} / ${duration}))
PY
          )
        fi

        if [[ "$first_record" == true ]]; then
          first_record=false
        else
          echo "," >> "$json_file"
        fi

        printf '%s\n' "  {" >> "$json_file"
        printf '    "replicas": %s,\n' "$replicas" >> "$json_file"
        printf '    "transactions": %s,\n' "$tx" >> "$json_file"
        printf '    "latency_ms": %s,\n' "$latency" >> "$json_file"
        printf '    "jitter_ms": %s,\n' "$jitter" >> "$json_file"
        printf '    "bench": %s,\n' "$(printf '%s' "$bench_json" | tr -d '\n')" >> "$json_file"
        printf '    "resources": {"cpu_millicores": %s, "memory_mib": %s, "network_rx_bytes": %s, "network_tx_bytes": %s, "network_rx_bps": %s, "network_tx_bps": %s}\n' "${cpu_m:-null}" "${mem_mi:-null}" "$rx_delta" "$tx_delta" "$rx_rate" "$tx_rate" >> "$json_file"
        printf '%s\n' "  }" >> "$json_file"

        net_rx_kbps=$(python - <<PY
print(round(${rx_rate} / 1024, 2))
PY
        )
        net_tx_kbps=$(python - <<PY
print(round(${tx_rate} / 1024, 2))
PY
        )

        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
          "$replicas" "$tx" "$latency" "$jitter" "$avg_latency" "$throughput" "$errors" \
          "${cpu_m:-n/a}" "${mem_mi:-n/a}" "$net_rx_kbps" "$net_tx_kbps" >> "$md_file"
      done
      clear_netem
    done
  done
done

echo "]" >> "$json_file"

echo "Results saved to $json_file and $md_file"
