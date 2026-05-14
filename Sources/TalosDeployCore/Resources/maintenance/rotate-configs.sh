#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$ROOT/archive/$ts"
cp -a "$ROOT/generated" "$ROOT/machine-configs" "$ROOT/boot-machine-configs" "$ROOT/archive/$ts/" 2>/dev/null || true

echo "Archived generated config material to $ROOT/archive/$ts"
