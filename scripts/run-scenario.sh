#!/usr/bin/env bash
set -euo pipefail
MODE=${MODE:-twopc}
SCENARIO=${SCENARIO:-success}
ORDER_BASE_URL=${ORDER_BASE_URL:-http://localhost:8080}

ORDER_BASE_URL="$ORDER_BASE_URL" go run ./cmd/cli -run "$SCENARIO" -mode "$MODE"
