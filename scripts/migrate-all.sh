#!/usr/bin/env bash
set -euo pipefail

NS=${NS:-txlab}
RELEASE=${RELEASE:-tx-lab-ecommerce-go}
CHART=${CHART:-txlab}
SQL_DIR=${SQL_DIR:-deploy/sql}
POSTGRES_USER=${POSTGRES_USER:-postgres}

dbs=(
  "order:orderdb"
  "inventory:inventorydb"
  "payment:paymentdb"
  "shipping:shippingdb"
  "notification:notificationdb"
)

for entry in "${dbs[@]}"; do
  name="${entry%%:*}"
  db="${entry##*:}"
  sql_file="${SQL_DIR}/${name}.sql"

  if [[ ! -f "${sql_file}" ]]; then
    echo "SQL file not found: ${sql_file}" >&2
    exit 1
  fi

  selector="app=${RELEASE}-${CHART}-postgres-${name}"
  pod="$(kubectl get pod -n "${NS}" -l "${selector}" -o jsonpath='{.items[0].metadata.name}')"

  if [[ -z "${pod}" ]]; then
    echo "Postgres pod not found for ${name} (selector: ${selector})" >&2
    exit 1
  fi

  echo "Applying ${sql_file} to ${db} (pod: ${pod})..."
  kubectl cp "${sql_file}" "${NS}/${pod}:/tmp/${name}.sql"
  kubectl exec -n "${NS}" "${pod}" -- psql -U "${POSTGRES_USER}" -d "${db}" -f "/tmp/${name}.sql"
done
