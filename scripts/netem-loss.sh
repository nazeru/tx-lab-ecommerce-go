#!/usr/bin/env bash
set -euo pipefail
kubectl apply -f deploy/chaos/netem-daemonset.yaml
kubectl set env daemonset/txlab-netem NETEM_LOSS=1%
