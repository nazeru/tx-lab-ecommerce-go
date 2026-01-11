#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${ORDER_BASE_URL:-http://127.0.0.1:8080}"
HEALTH_PATH="${READY_HTTP_PATH:-/health}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

health_code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL%/}${HEALTH_PATH}" || echo "000")"
if [[ "$health_code" != "200" ]]; then
  echo "health check failed: ${health_code}" >&2
  exit 1
fi

order_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
idem="$(python3 -c 'import uuid; print(uuid.uuid4())')"

payload="$(python3 -c "import json; print(json.dumps({'order_id': '$order_id', 'total': 1200, 'items': [{'product_id': 'sku-1', 'quantity': 1}]}))")"

resp="$(curl -s -w '\n%{http_code}' -H 'Content-Type: application/json' -H "Idempotency-Key: $idem" -d "$payload" "${BASE_URL%/}/checkout")"
body="$(echo "$resp" | head -n1)"
code="$(echo "$resp" | tail -n1)"

if [[ "$code" != 2* ]]; then
  echo "checkout failed: ${code} ${body}" >&2
  exit 1
fi

returned_id="$(python3 - <<'PY'
import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get('order_id',''))
except Exception:
    print('')
PY
<<<"$body")"

if [[ -z "$returned_id" ]]; then
  echo "order_id missing in response" >&2
  exit 1
fi

status_resp="$(curl -s -w '\n%{http_code}' "${BASE_URL%/}/orders/${returned_id}")"
status_body="$(echo "$status_resp" | head -n1)"
status_code="$(echo "$status_resp" | tail -n1)"
if [[ "$status_code" != "200" ]]; then
  echo "order status lookup failed: ${status_code} ${status_body}" >&2
  exit 1
fi

repeat_resp="$(curl -s -w '\n%{http_code}' -H 'Content-Type: application/json' -H "Idempotency-Key: $idem" -d "$payload" "${BASE_URL%/}/checkout")"
repeat_body="$(echo "$repeat_resp" | head -n1)"
repeat_code="$(echo "$repeat_resp" | tail -n1)"
if [[ "$repeat_code" != 2* ]]; then
  echo "idempotent checkout failed: ${repeat_code} ${repeat_body}" >&2
  exit 1
fi

repeat_id="$(python3 - <<'PY'
import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get('order_id',''))
except Exception:
    print('')
PY
<<<"$repeat_body")"

if [[ "$repeat_id" != "$returned_id" ]]; then
  echo "idempotency mismatch: ${returned_id} vs ${repeat_id}" >&2
  exit 1
fi

echo "smoke OK: order_id=${returned_id}"
