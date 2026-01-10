#!/usr/bin/env bash
set -euo pipefail
MODE=${MODE:-twopc}
ORDER_BASE_URL=${ORDER_BASE_URL:-http://localhost:8080}

ORDER_BASE_URL="$ORDER_BASE_URL" go run ./cmd/cli -run bench -mode "$MODE"
