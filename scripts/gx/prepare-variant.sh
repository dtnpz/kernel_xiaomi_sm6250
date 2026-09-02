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

python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
old, new = 'int vm_swappiness = 10;', 'int vm_swappiness = 60;'
if old in s: s = s.replace(old, new, 1)
elif new not in s: raise SystemExit('Unexpected vm_swappiness source state')
p.write_text(s)
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

# Modern rooted cores use their own hooks; remove Velvet's stale callback ABI
# before either plain or SUSFS build paths.
if [[ "$GX_ROOT" != none ]]; then
  python3 scripts/gx/strip-modern-ksu-legacy-vendor-hooks.py
fi

if [[ "$GX_SUSFS" == 1 ]]; then
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"
  case "$GX_ROOT" in
    xxksu) KSU_DIR="$ROOT_DIR/KernelSU" ;;
    ksun) KSU_DIR="$ROOT_DIR/KernelSU-Next" ;;
    *) echo "SUSFS ABI bridge requires a rooted variant." >&2; exit 3 ;;
  esac
  python3 scripts/gx/add-susfs-v155-bridges.py "$KSU_DIR" "$GX_ROOT"
fi

echo "[GXT] variant preparation complete: $GX_VARIANT"
