#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

[[ -f .gx-variant ]] || { echo "Missing .gx-variant metadata." >&2; exit 2; }
# shellcheck disable=SC1091
source .gx-variant
: "${GX_VARIANT:?GX_VARIANT missing}"
: "${GX_ROOT:=none}"
: "${GX_SUSFS:=0}"
: "${GX_BP:=0}"
: "${GX_DEFCONFIG:=vendor/miatoll-perf_defconfig}"

case "$GX_ROOT" in none|xxksu|ksun) ;; *) echo "Unknown GX_ROOT=$GX_ROOT" >&2; exit 2 ;; esac
case "$GX_SUSFS" in 0|1) ;; *) echo "GX_SUSFS must be 0/1" >&2; exit 2 ;; esac
case "$GX_BP" in 0|1) ;; *) echo "GX_BP must be 0/1" >&2; exit 2 ;; esac
[[ "$GX_ROOT" != none || "$GX_SUSFS" != 1 ]] || { echo "SUSFS is forbidden on NONKSU variants." >&2; exit 2; }

# Runtime baseline test: keep the kernel's proven Miatoll default swappiness.
# The N45 matrix previously forced 10 -> 60 here; device logs from #179 show
# heavy reclaim/LMK activity, so isolate that policy change before touching
# Simple LMK itself (whose source/config match the known-good r1 baseline).
python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
if 'int vm_swappiness = 10;' not in s:
    raise SystemExit('Unexpected vm_swappiness baseline; expected 10')
if 'int vm_swappiness = 60;' in s:
    raise SystemExit('N45 swappiness override to 60 is still present')
PY

defconfig_path="arch/arm64/configs/$GX_DEFCONFIG"
python3 - "$defconfig_path" "$GX_VARIANT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); variant = sys.argv[2]; s = p.read_text()
line = f'CONFIG_LOCALVERSION="-Gxter-{variant}-FuckMiatollCommu"'
pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
s = pat.sub(line, s, count=1) if pat.search(s) else line + '\n' + s
p.write_text(s)
PY

if [[ "$GX_BP" == 1 ]]; then bash scripts/gx/apply-bp510.sh; fi
case "$GX_ROOT" in
  none) ;;
  xxksu) bash scripts/gx/setup-xxksu.sh ;;
  ksun) bash scripts/gx/setup-ksun.sh ;;
esac

# Remove stale Velvet callbacks before either the modern direct-hook path or
# the SUSFS-v2 manual-hook patch installs the current callback ABI.
if [[ "$GX_ROOT" != none ]]; then
  python3 scripts/gx/strip-modern-ksu-legacy-vendor-hooks.py
fi

# KSUN no-SUSFS still uses the non-kprobe/manual-hook engine on N45.  Install
# only the KernelSU hook surface here; do not add any SUSFS source or features.
if [[ "$GX_ROOT" == "ksun" && "$GX_SUSFS" == "0" ]]; then
  python3 scripts/gx/apply-ksun-manual-hooks.py
fi

if [[ "$GX_SUSFS" == 1 ]]; then
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"
  # SUSFS needs the newer IDA API, but its 4.14 reference chain assumes a
  # pre-existing XArray backport. N45 does not have XArray; keep the API while
  # retaining the proven radix-tree/simple-lock implementation used by 4.14.
  python3 scripts/gx/adapt-ida-414-no-xarray.py
fi

echo "[GXT] variant preparation complete: $GX_VARIANT"
