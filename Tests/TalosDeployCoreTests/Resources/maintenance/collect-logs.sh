#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALOSCTL="$(command -v talosctl || true)"

if [ -z "$TALOSCTL" ]; then
  echo "talosctl is required for logs collection" >&2
  exit 1
fi

cd "$ROOT"

out="$ROOT/logs/collect-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"

for node in "$@"; do
  "$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" --nodes "$node" logs > "$out/$node.log" 2>&1 || true
done

echo "$out"
