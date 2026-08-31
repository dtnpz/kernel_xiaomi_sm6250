#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

python3 <<'PY'
from pathlib import Path

p = Path('mm/vmscan.c')
s = p.read_text()
old = 'int vm_swappiness = 10;'
new = 'int vm_swappiness = 60;'

if s.count(old) != 1:
    raise SystemExit(f'Expected exactly one {old!r}, found {s.count(old)}')
if new in s:
    raise SystemExit('Common N45 tuning appears to have been applied twice')

p.write_text(s.replace(old, new, 1))
PY

# Nexus v4.5 target invariants that are already provided by this base.
# Keep these as hard assertions so later source changes cannot silently drift.
grep -q '^CONFIG_LRU_GEN=y$' arch/arm64/configs/vendor/miatoll-perf_defconfig
if grep -q '^CONFIG_ZSTD' arch/arm64/configs/vendor/miatoll-perf_defconfig; then
  echo 'Unexpected ZSTD config in N45 defconfig' >&2
  exit 3
fi

grep -q 'int vm_swappiness = 60;' mm/vmscan.c

echo '[N45] common v4.5-style layer applied: MGLRU retained, swappiness=60, no ZSTD defconfig entry.'
