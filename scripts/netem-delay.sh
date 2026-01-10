#!/usr/bin/env bash
set -euo pipefail
kubectl apply -f deploy/chaos/netem-daemonset.yaml
