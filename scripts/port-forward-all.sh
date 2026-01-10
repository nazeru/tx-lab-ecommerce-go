#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-txlab}"
RELEASE="${RELEASE:-tx-lab-ecommerce-go}"
ADDR="${ADDR:-127.0.0.1}"
LOG_DIR="${LOG_DIR:-results/pf-logs}"

mkdir -p "$LOG_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

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

wait_port() {
  local port="$1"
  local name="$2"
  local log="$3"
  local i
  for i in $(seq 1 40); do
    if have_port_listener "$port"; then
      return 0
    fi
    # если процесс уже умер — покажем лог и выйдем
    if ! kill -0 "${PIDS[$name]}" >/dev/null 2>&1; then
      echo "ERROR: port-forward process for $name exited early." >&2
      echo "----- last log lines: $log -----" >&2
      tail -n 80 "$log" >&2 || true
      return 1
    fi
    sleep 0.15
  done
  echo "ERROR: port-forward not listening on localhost:${port} ($name)" >&2
  echo "----- last log lines: $log -----" >&2
  tail -n 80 "$log" >&2 || true
  return 1
}

declare -A PIDS=()
declare -A LOGS=()

start_pf() {
  local name="$1"
  local target="$2"     # svc/...
  local local_port="$3"
  local remote_port="$4"

  local log="${LOG_DIR}/${name}.log"
  LOGS["$name"]="$log"

  echo "Port-forward $target -> ${ADDR}:${local_port}" >&2
  # ВАЖНО: логируем stdout+stderr
  kubectl -n "$NS" port-forward "$target" "${local_port}:${remote_port}" --address "$ADDR" >"$log" 2>&1 &
  PIDS["$name"]=$!

  wait_port "$local_port" "$name" "$log"
}

# Запуск port-forward’ов
start_pf "order"        "svc/${RELEASE}-${NS}-order-service"        8080 8080
start_pf "inventory"    "svc/${RELEASE}-${NS}-inventory-service"    8081 8080
start_pf "payment"      "svc/${RELEASE}-${NS}-payment-service"      8082 8080
start_pf "shipping"     "svc/${RELEASE}-${NS}-shipping-service"     8083 8080
start_pf "notification" "svc/${RELEASE}-${NS}-notification-service" 8084 8080

start_pf "pg-order"        "svc/${RELEASE}-${NS}-postgres-order"        5432 5432
start_pf "pg-inventory"    "svc/${RELEASE}-${NS}-postgres-inventory"    5433 5432
start_pf "pg-payment"      "svc/${RELEASE}-${NS}-postgres-payment"      5434 5432
start_pf "pg-shipping"     "svc/${RELEASE}-${NS}-postgres-shipping"     5435 5432
start_pf "pg-notification" "svc/${RELEASE}-${NS}-postgres-notification" 5436 5432

echo "OK: all port-forwards are listening." >&2

# Держим скрипт “живым”, чтобы фоновые port-forward не умерли вместе с оболочкой.
# (Если у вас уже есть другой механизм удержания — адаптируйте.)
wait
