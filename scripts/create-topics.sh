#!/usr/bin/env bash
set -euo pipefail
BROKER=${BROKER:-localhost:9092}
TOPIC=${TOPIC:-txlab.events}
PARTITIONS=${PARTITIONS:-3}

if ! command -v kafka-topics.sh >/dev/null 2>&1; then
  echo "kafka-topics.sh not found. Run inside Kafka/Redpanda container or install Kafka CLI."
  exit 1
fi

kafka-topics.sh --bootstrap-server "$BROKER" --create --if-not-exists --topic "$TOPIC" --partitions "$PARTITIONS" --replication-factor 1
