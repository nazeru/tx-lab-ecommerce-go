#!/usr/bin/env bash
set -euo pipefail

NS=${NS:-txlab}
RELEASE=${RELEASE:-tx-lab-ecommerce-go}
CHART=${CHART:-txlab}

declare -A ports=(
  ["order-service"]=8080
  ["inventory-service"]=8081
  ["payment-service"]=8082
  ["shipping-service"]=8083
  ["notification-service"]=8084
)

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT

pids=()
for svc in "${!ports[@]}"; do
  local_port="${ports[$svc]}"
  remote_port=8080
  name="${RELEASE}-${CHART}-${svc}"
  echo "Port-forward ${name} -> localhost:${local_port}"
  kubectl port-forward -n "${NS}" "svc/${name}" "${local_port}:${remote_port}" >/tmp/port-forward-"${svc}".log 2>&1 &
  pids+=("$!")
done

wait
