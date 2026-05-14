#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 NODE_IP MACHINE_CONFIG_PATH" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALOSCTL="$(command -v talosctl || true)"

if [ -z "$TALOSCTL" ]; then
  echo "talosctl is required for apply-config" >&2
  exit 1
fi

"$TALOSCTL" --nodes "$1" apply-config --insecure --file "$2"
