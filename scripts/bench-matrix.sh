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

# Port-forward management for order-service (restarted after every TX_MODE switch)
MANAGE_ORDER_PF="${MANAGE_ORDER_PF:-1}"                     # 1/0
ORDER_PF_ADDR="$(trim "${ORDER_PF_ADDR:-127.0.0.1}")"
ORDER_PF_PORT="$(trim "${ORDER_PF_PORT:-8080}")"            # local port for order-service
ORDER_PF_LOG_DIR="$(trim "${ORDER_PF_LOG_DIR:-${RESULTS_DIR}/pf-logs}")"

# Rollout timeouts
ROLLOUT_TIMEOUT="$(trim "${ROLLOUT_TIMEOUT:-5m}")"
PODS_READY_TIMEOUT="$(trim "${PODS_READY_TIMEOUT:-3m}")"

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

mkdir -p "$RESULTS_DIR" "$ORDER_PF_LOG_DIR"

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
* Concurrency: $CONCURRENCY
* TX modes: ${TX_MODES[*]}
* Net profiles: ${NET_PROFILES[*]}
* Port-forward restart policy: stop before TX_MODE switch, start after rollout (MANAGE_ORDER_PF=$MANAGE_ORDER_PF)

| TX mode | Net profile | Replicas | Transactions | Latency (ms) | Jitter (ms) | Avg latency (ms) | Throughput (rps) | Errors | CPU (m) | Memory (Mi) | Net RX (KB/s) | Net TX (KB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER

echo "[" > "$json_file"
first_record=true

# ----------------------------
# K8s helpers
# ----------------------------
ensure_rollout() {
  kubectl -n "$NAMESPACE" rollout status "deployment/${DEPLOYMENT}" --timeout="$ROLLOUT_TIMEOUT"
}

wait_pods_stable() {
  local timeout_s="${1:-180}"
  local start
  start="$(date +%s)"

  while true; do
    local desired
    desired="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
    [[ -n "$desired" ]] || desired="1"

    local pods_json
    pods_json="$(kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o json)"

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
      kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o wide >&2 || true
      kubectl -n "$NAMESPACE" describe deploy "$DEPLOYMENT" >&2 || true
      return 1
    fi

    sleep 0.5
  done
}

scale_replicas() {
  local replicas="$1"
  kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$replicas" >/dev/null
  ensure_rollout
  wait_pods_stable 180
}

list_pods() {
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}'
}

# ----------------------------
# Netem helpers (profiles)
# ----------------------------
apply_netem_profile() {
  local profile="$1"
  local delay_ms="$2"
  local jitter_ms="$3"

  local extra=""
  case "$profile" in
    normal)
      extra=""
      ;;
    lossy)
      # add small packet loss
      extra=" loss 1%"
      ;;
    congested)
      # add reorder to emulate queue instability
      extra=" reorder 25% 50%"
      ;;
    *)
      die "unknown net profile: $profile"
      ;;
  esac

  local pod
  for pod in $(list_pods); do
    # NOTE: ignore failures to avoid hard crash if tc is missing; you can remove '|| true' if you prefer strictness.
    kubectl exec -n "$NAMESPACE" "$pod" -- \
      tc qdisc replace dev eth0 root netem delay "${delay_ms}ms" "${jitter_ms}ms"${extra} >/dev/null 2>&1 || true
  done
}

clear_netem() {
  local pod
  for pod in $(list_pods); do
    kubectl exec -n "$NAMESPACE" "$pod" -- tc qdisc del dev eth0 root >/dev/null 2>&1 || true
  done
}

sum_net_bytes() {
  local direction="$1"  # rx or tx
  local total=0
  local pod
  for pod in $(list_pods); do
    local val
    val="$(kubectl exec -n "$NAMESPACE" "$pod" -- cat "/sys/class/net/eth0/statistics/${direction}_bytes" 2>/dev/null || echo "")"
    if [[ -n "$val" ]]; then
      total=$((total + val))
    fi
  done
  echo "$total"
}

capture_top() {
  local output=""
  local i

  # metrics-server может не успеть отдать метрики сразу после рестарта pod'ов
  for i in $(seq 1 20); do
    output=$(kubectl top pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null || true)
    if [[ -n "$output" ]]; then
      break
    fi
    sleep 0.5
  done

  if [[ -z "$output" ]]; then
    echo ""
    return
  fi

  # NAME  CPU(m)  MEM(Mi)
  echo "$output" | awk '{
    gsub("m","",$2); gsub("Mi","",$3);
    cpu+=$2; mem+=$3
  } END {printf "%d %d", cpu, mem}'
}

# ----------------------------
# Port-forward management for order-service (restart after TX_MODE switch)
# ----------------------------
ORDER_PF_PID=""
ORDER_PF_LOG=""

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
      # give it a moment
      sleep 0.2
      if kill -0 "$ORDER_PF_PID" >/dev/null 2>&1; then
        kill -9 "$ORDER_PF_PID" >/dev/null 2>&1 || true
      fi
    fi
  fi
  ORDER_PF_PID=""
  ORDER_PF_LOG=""
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

  # wait until port starts listening or process dies
  local i
  for i in $(seq 1 80); do
    if have_port_listener "$ORDER_PF_PORT"; then
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

  local out
  out="$("$BENCH_BIN" -base-url "$base_url" -total "$tx" -concurrency "$conc" 2>&1)"
  printf '%s' "$out" | extract_first_json_object
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
  wait_pods_stable 180

  sleep 10

  if [[ "$MANAGE_ORDER_PF" == "1" ]]; then
    start_order_pf
  fi

  for profile in "${NET_PROFILES[@]}"; do
    for replicas in "${REPLICAS_LIST[@]}"; do
      log "Scale replicas=$replicas (mode=$mode, profile=$profile)"
      scale_replicas "$replicas"

      for latency in "${LATENCIES_MS[@]}"; do
        for jitter in "${JITTERS_MS[@]}"; do
          # Apply network emulation profile on pods
          apply_netem_profile "$profile" "$latency" "$jitter"

          for tx in "${TX_COUNTS[@]}"; do
            log "RUN mode=$mode profile=$profile replicas=$replicas latency=${latency}ms jitter=${jitter}ms tx=$tx"

            net_before_rx="$(sum_net_bytes rx)"
            net_before_tx="$(sum_net_bytes tx)"

            bench_json="$(run_bench_json "$BENCH_BASE_URL" "$tx" "$CONCURRENCY")"

            net_after_rx="$(sum_net_bytes rx)"
            net_after_tx="$(sum_net_bytes tx)"

            bench_fields="$(printf '%s' "$bench_json" | "$PYTHON_BIN" -c '
import json, sys
d = json.load(sys.stdin)
avg = d.get("avg_latency_ms", 0)
thr = d.get("throughput_rps", 0)
err = d.get("error_requests", 0)
dur = d.get("duration_seconds", 0)
print(f"{avg:.2f}\t{thr:.2f}\t{err}\t{dur:.4f}")
')"

            avg_latency="$(echo "$bench_fields" | awk '{print $1}')"
            throughput="$(echo "$bench_fields" | awk '{print $2}')"
            errors="$(echo "$bench_fields" | awk '{print $3}')"
            duration="$(echo "$bench_fields" | awk '{print $4}')"

            top_fields="$(capture_top)"
            cpu_m=""
            mem_mi=""
            if [[ -n "$top_fields" ]]; then
              cpu_m="$(echo "$top_fields" | awk '{print $1}')"
              mem_mi="$(echo "$top_fields" | awk '{print $2}')"
            fi

            rx_delta=$((net_after_rx - net_before_rx))
            tx_delta=$((net_after_tx - net_before_tx))

            rx_rate=0
            tx_rate=0
            if [[ -n "$duration" && "$duration" != "0" ]]; then
              rx_rate="$("$PYTHON_BIN" -c "print(int(${rx_delta} / ${duration}))")"
              tx_rate="$("$PYTHON_BIN" -c "print(int(${tx_delta} / ${duration}))")"
            fi

            net_rx_kbps="$("$PYTHON_BIN" -c "print(round(${rx_rate} / 1024, 2))")"
            net_tx_kbps="$("$PYTHON_BIN" -c "print(round(${tx_rate} / 1024, 2))")"

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
              printf '    "transactions": %s,\n' "$tx"
              printf '    "latency_ms": %s,\n' "$latency"
              printf '    "jitter_ms": %s,\n' "$jitter"
              printf '    "bench": %s,\n' "$(printf '%s' "$bench_json" | tr -d '\n')"
              printf '    "resources": {"cpu_millicores": %s, "memory_mib": %s, "network_rx_bytes": %s, "network_tx_bytes": %s, "network_rx_bps": %s, "network_tx_bps": %s}\n' \
                "${cpu_m:-null}" "${mem_mi:-null}" "$rx_delta" "$tx_delta" "$rx_rate" "$tx_rate"
              printf '%s\n' "  }"
            } >> "$json_file"

            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
              "$mode" "$profile" "$replicas" "$tx" "$latency" "$jitter" "$avg_latency" "$throughput" "$errors" \
              "${cpu_m:-n/a}" "${mem_mi:-n/a}" "$net_rx_kbps" "$net_tx_kbps" >> "$md_file"

            log "DONE mode=$mode profile=$profile replicas=$replicas -> avg=${avg_latency}ms thr=${throughput}rps err=${errors}"
          done

          clear_netem
        done
      done
    done
  done
done

echo "]" >> "$json_file"
log "Results saved to $json_file and $md_file"
