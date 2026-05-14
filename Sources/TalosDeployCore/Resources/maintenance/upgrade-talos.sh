#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 INSTALLER_IMAGE" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TALOSCTL="$(command -v talosctl || true)"

if [ -z "$TALOSCTL" ]; then
  echo "talosctl is required for upgrade" >&2
  exit 1
fi

"$TALOSCTL" --talosconfig "$ROOT/generated/talosconfig" upgrade --image "$1" --preserve
