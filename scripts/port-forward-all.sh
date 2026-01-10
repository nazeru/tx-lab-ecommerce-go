#!/usr/bin/env bash
set -euo pipefail

NS=${NS:-txlab}
RELEASE=${RELEASE:-tx-lab-ecommerce-go}
CHART=${CHART:-txlab}

services=(
  "order-service:8080:8080"
  "inventory-service:8081:8080"
  "payment-service:8082:8080"
  "shipping-service:8083:8080"
  "notification-service:8084:8080"
)

databases=(
  "postgres-order:5432:5432"
  "postgres-inventory:5433:5432"
  "postgres-payment:5434:5432"
  "postgres-shipping:5435:5432"
  "postgres-notification:5436:5432"
)

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT

pids=()
for entry in "${services[@]}"; do
  svc="${entry%%:*}"
  rest="${entry#*:}"
  local_port="${rest%%:*}"
  remote_port="${rest##*:}"
  name="${RELEASE}-${CHART}-${svc}"
  echo "Port-forward ${name} -> localhost:${local_port}"
  kubectl port-forward -n "${NS}" "svc/${name}" "${local_port}:${remote_port}" >/tmp/port-forward-"${svc}".log 2>&1 &
  pids+=("$!")
done

for entry in "${databases[@]}"; do
  svc="${entry%%:*}"
  rest="${entry#*:}"
  local_port="${rest%%:*}"
  remote_port="${rest##*:}"
  name="${RELEASE}-${CHART}-${svc}"
  echo "Port-forward ${name} -> localhost:${local_port}"
  kubectl port-forward -n "${NS}" "svc/${name}" "${local_port}:${remote_port}" >/tmp/port-forward-"${svc}".log 2>&1 &
  pids+=("$!")
done

wait
