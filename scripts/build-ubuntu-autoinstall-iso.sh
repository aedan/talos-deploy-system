#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  build-ubuntu-autoinstall-iso.sh \
    --source-iso /path/to/ubuntu.iso \
    --seed-dir /path/to/nocloud \
    --output-iso /path/to/output.iso \
    [--extra-kernel-arg ARG ...] \
    [--workdir /tmp/build-dir]

This script customizes an Ubuntu live-server ISO for unattended installs by:
  - extracting the source ISO with xorriso
  - copying NoCloud seed files to /nocloud/user-data and /nocloud/meta-data
  - patching GRUB menu entries to add autoinstall ds=nocloud\;s=/cdrom/nocloud/
  - refreshing md5sum.txt
  - rebuilding the ISO while replaying the original boot metadata

Compatibility:
  --autoinstall /path/to/autoinstall.yaml is still accepted and is treated as
  the NoCloud user-data file. A minimal meta-data file will be generated.
EOF
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' is not installed" >&2
    exit 1
  fi
}

compute_md5sum_file() {
  local root="$1"
  local output="$2"

  if command -v md5sum >/dev/null 2>&1; then
    (
      cd "$root"
      find . -type f ! -name md5sum.txt -print0 \
        | sort -z \
        | xargs -0 md5sum
    ) >"$output"
    return
  fi

  if command -v md5 >/dev/null 2>&1; then
    python3 - "$root" "$output" <<'PY'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
output = os.path.abspath(sys.argv[2])
paths = []
for base, _, files in os.walk(root):
    for name in files:
        rel = os.path.relpath(os.path.join(base, name), root)
        if rel == "md5sum.txt":
            continue
        paths.append(rel)

paths.sort()

with open(output, "w", encoding="utf-8") as handle:
    for rel in paths:
        full = os.path.join(root, rel)
        digest = hashlib.md5()
        with open(full, "rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        handle.write(f"{digest.hexdigest()}  ./{rel}\n")
PY
    return
  fi

  echo "error: neither md5sum nor md5 is available" >&2
  exit 1
}

patch_grub_cfg() {
  local grub_cfg="$1"
  shift
  python3 - "$grub_cfg" "$@" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
extra_args = sys.argv[2:]
content = path.read_text(encoding="utf-8")

linux_line = re.compile(r'^(?P<prefix>\s*linux(?:efi)?\s+\S+)(?P<args>.*)$')

def patch_line(line):
    match = linux_line.match(line)
    if not match:
        return line, False

    args = match.group("args").strip()
    after_separator = ""
    if "---" in args:
        before, after = args.split("---", 1)
        tokens = [token for token in before.split() if token]
        after_separator = " ---" + after
    else:
        tokens = [token for token in args.split() if token]

    if "autoinstall" not in tokens:
        tokens.append("autoinstall")
    for extra in extra_args:
        if extra not in tokens:
            tokens.append(extra)
    patched_args = " ".join(tokens)
    if patched_args:
        patched_args = " " + patched_args
    return f"{match.group('prefix')}{patched_args}{after_separator}", True

updated_lines = []
count = 0
for line in content.splitlines():
    updated, patched = patch_line(line)
    updated_lines.append(updated)
    if patched:
        count += 1

if count == 0:
    raise SystemExit("error: could not find any GRUB linux lines to patch")

updated = "\n".join(updated_lines)
if content.endswith("\n"):
    updated += "\n"
path.write_text(updated, encoding="utf-8")
PY
}

SOURCE_ISO=""
AUTOINSTALL_FILE=""
SEED_DIR=""
OUTPUT_ISO=""
WORKDIR=""
EXTRA_KERNEL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-iso)
      SOURCE_ISO="${2:-}"
      shift 2
      ;;
    --autoinstall)
      AUTOINSTALL_FILE="${2:-}"
      shift 2
      ;;
    --seed-dir)
      SEED_DIR="${2:-}"
      shift 2
      ;;
    --output-iso)
      OUTPUT_ISO="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --extra-kernel-arg)
      EXTRA_KERNEL_ARGS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_ISO" || -z "$OUTPUT_ISO" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$SEED_DIR" && -z "$AUTOINSTALL_FILE" ]]; then
  usage >&2
  exit 1
fi

require_tool xorriso
require_tool python3

SOURCE_ISO="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SOURCE_ISO")"
if [[ -n "$AUTOINSTALL_FILE" ]]; then
  AUTOINSTALL_FILE="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$AUTOINSTALL_FILE")"
fi
OUTPUT_ISO="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUTPUT_ISO")"
if [[ -n "$SEED_DIR" ]]; then
  SEED_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$SEED_DIR")"
fi

if [[ ! -f "$SOURCE_ISO" ]]; then
  echo "error: source ISO not found: $SOURCE_ISO" >&2
  exit 1
fi

if [[ -n "$AUTOINSTALL_FILE" && ! -f "$AUTOINSTALL_FILE" ]]; then
  echo "error: autoinstall file not found: $AUTOINSTALL_FILE" >&2
  exit 1
fi

if [[ -n "$SEED_DIR" ]]; then
  if [[ ! -f "$SEED_DIR/user-data" || ! -f "$SEED_DIR/meta-data" ]]; then
    echo "error: seed dir must contain user-data and meta-data: $SEED_DIR" >&2
    exit 1
  fi
fi

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(dirname "$OUTPUT_ISO")/$(basename "$OUTPUT_ISO" .iso)-work"
fi

WORKDIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$WORKDIR")"
ISO_ROOT="$WORKDIR/iso-root"

if [[ -e "$WORKDIR" ]]; then
  chmod -R u+w "$WORKDIR" 2>/dev/null || true
  rm -rf "$WORKDIR"
fi
mkdir -p "$ISO_ROOT"
mkdir -p "$(dirname "$OUTPUT_ISO")"

echo "Extracting source ISO..."
xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$ISO_ROOT" >/dev/null 2>&1
chmod -R u+w "$ISO_ROOT"

echo "Copying NoCloud seed..."
mkdir -p "$ISO_ROOT/nocloud"
if [[ -n "$SEED_DIR" ]]; then
  cp "$SEED_DIR/user-data" "$ISO_ROOT/nocloud/user-data"
  cp "$SEED_DIR/meta-data" "$ISO_ROOT/nocloud/meta-data"
  if [[ -f "$SEED_DIR/90-tds-preserved.yaml" ]]; then
    cp "$SEED_DIR/90-tds-preserved.yaml" "$ISO_ROOT/nocloud/90-tds-preserved.yaml"
  fi
else
  cp "$AUTOINSTALL_FILE" "$ISO_ROOT/nocloud/user-data"
  {
    echo "instance-id: tds-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "local-hostname: tds-helper"
  } >"$ISO_ROOT/nocloud/meta-data"
fi
if [[ ! -f "$ISO_ROOT/nocloud/90-tds-preserved.yaml" ]]; then
  : >"$ISO_ROOT/nocloud/90-tds-preserved.yaml"
fi

echo "Patching GRUB configuration..."
GRUB_KERNEL_ARGS=("ds=nocloud\\;s=/cdrom/nocloud/")
if [[ ${#EXTRA_KERNEL_ARGS[@]} -gt 0 ]]; then
  GRUB_KERNEL_ARGS+=("${EXTRA_KERNEL_ARGS[@]}")
fi
patch_grub_cfg "$ISO_ROOT/boot/grub/grub.cfg" "${GRUB_KERNEL_ARGS[@]}"

echo "Refreshing md5sum.txt..."
compute_md5sum_file "$ISO_ROOT" "$ISO_ROOT/md5sum.txt"

echo "Building customized ISO..."
rm -f "$OUTPUT_ISO"
xorriso \
  -indev "$SOURCE_ISO" \
  -outdev "$OUTPUT_ISO" \
  -map "$ISO_ROOT/nocloud/user-data" /nocloud/user-data \
  -map "$ISO_ROOT/nocloud/meta-data" /nocloud/meta-data \
  -map "$ISO_ROOT/nocloud/90-tds-preserved.yaml" /nocloud/90-tds-preserved.yaml \
  -map "$ISO_ROOT/boot/grub/grub.cfg" /boot/grub/grub.cfg \
  -map "$ISO_ROOT/md5sum.txt" /md5sum.txt \
  -boot_image any replay \
  -commit \
  >/dev/null 2>&1

echo "Customized ISO written to $OUTPUT_ISO"
