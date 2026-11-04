#!/usr/bin/env bash
# Offline compatibility check (no device needed).
#
#   scripts/compat-check.sh [OUT_DIR]
#
# Compares out/.config and out/boot.img against the stock crDroid 10.14 kernel
# baselines committed under prebuilt/. Writes out/compat-report.md and exits
# non-zero when a check fails, so it can gate CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/out}"

exec python3 "$ROOT/scripts/compat_check.py" \
  --config        "$OUT_DIR/.config" \
  --bootimg       "$OUT_DIR/boot.img" \
  --stock-config  "$ROOT/prebuilt/stock-kernel.config" \
  --stock-dtb     "$ROOT/prebuilt/stock-dtb.sha256" \
  --stock-ramdisk "$ROOT/prebuilt/stock-ramdisk.sha256" \
  --allowlist     "$ROOT/prebuilt/compat-allowlist.txt" \
  --report        "$OUT_DIR/compat-report.md"
