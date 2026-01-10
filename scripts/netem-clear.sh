#!/usr/bin/env bash
set -euo pipefail
kubectl delete daemonset txlab-netem --ignore-not-found=true
