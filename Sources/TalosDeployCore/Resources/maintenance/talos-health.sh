#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALOSCTL="$(command -v talosctl || true)"

if [ -z "$TALOSCTL" ]; then
  echo "talosctl is required for Talos health checks" >&2
  exit 1
fi

cd "$ROOT"

health_args=(--talosconfig "$ROOT/generated/talosconfig" --endpoints "$1" health --nodes "$2" --control-plane-nodes "$3" --wait-timeout 10m)
if [ -n "$4" ]; then
  health_args+=(--worker-nodes "$4")
fi

"$TALOSCTL" "${health_args[@]}"

if [ -f "$ROOT/kubeconfig" ] && command -v kubectl >/dev/null 2>&1; then
  kubectl --kubeconfig "$ROOT/kubeconfig" get nodes -o wide
  kubectl --kubeconfig "$ROOT/kubeconfig" get pods -A
elif [ -f "$ROOT/kubeconfig" ]; then
  echo "kubectl is not installed; Talos health passed, skipping Kubernetes object listing." >&2
fi
