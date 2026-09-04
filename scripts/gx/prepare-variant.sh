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

# Keep #183's proven runtime swappiness unchanged.
python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
if 'int vm_swappiness = 10;' not in s:
    raise SystemExit('Unexpected vm_swappiness baseline; expected 10')
if 'int vm_swappiness = 60;' in s:
    raise SystemExit('Rejected swappiness=60 experiment is still present')
PY

# Keep #183's de-RT Simple LMK control workers exactly unchanged.
python3 scripts/gx/adapt-simple-lmk-scheduler.py

defconfig_path="arch/arm64/configs/$GX_DEFCONFIG"

# #189 isolation result: retain 128 MiB minfree with the original 100 ms timeout.
python3 - "$defconfig_path" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
minfree = re.compile(r'^CONFIG_ANDROID_SIMPLE_LMK_MINFREE=.*$', re.M)
timeout = re.compile(r'^CONFIG_ANDROID_SIMPLE_LMK_TIMEOUT_MSEC=.*$', re.M)
if not minfree.search(s):
    raise SystemExit('Missing CONFIG_ANDROID_SIMPLE_LMK_MINFREE')
if not timeout.search(s):
    raise SystemExit('Missing CONFIG_ANDROID_SIMPLE_LMK_TIMEOUT_MSEC')
s = minfree.sub('CONFIG_ANDROID_SIMPLE_LMK_MINFREE=128', s, count=1)
if 'CONFIG_ANDROID_SIMPLE_LMK_TIMEOUT_MSEC=100' not in s:
    raise SystemExit('Unexpected Simple LMK timeout; this test must keep 100 ms')
p.write_text(s)
print('[N45] #189 runtime: Simple LMK MINFREE=128 MiB; timeout=100 ms')
PY

grep -Fxq 'CONFIG_ANDROID_SIMPLE_LMK_MINFREE=128' "$defconfig_path"
grep -Fxq 'CONFIG_ANDROID_SIMPLE_LMK_TIMEOUT_MSEC=100' "$defconfig_path"

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

# Official KernelSU-Next legacy exports the same manual callback ABI already
# present in the N45/Velvet 4.14 tree. Preserve those callbacks only for the
# KSUN no-SUSFS legacy lane. Other modern root lanes keep the old cleanup.
if [[ "$GX_ROOT" != none ]]; then
  if [[ "$GX_ROOT" == "ksun" && "$GX_SUSFS" == "0" ]]; then
    echo "[GXT] preserving N45 vendor manual KSU callbacks for upstream KSUN legacy"
  else
    python3 scripts/gx/strip-modern-ksu-legacy-vendor-hooks.py
  fi
fi

if [[ "$GX_ROOT" == "ksun" && "$GX_SUSFS" == "0" ]]; then
  python3 scripts/gx/augment-ksun-legacy-manual-hooks.py
fi

if [[ "$GX_SUSFS" == 1 ]]; then
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"
  # SUSFS needs the newer IDA API, but its 4.14 reference chain assumes a
  # pre-existing XArray backport. N45 does not have XArray; keep the API while
  # retaining the proven radix-tree/simple-lock implementation used by 4.14.
  python3 scripts/gx/adapt-ida-414-no-xarray.py
fi

echo "[GXT] variant preparation complete: $GX_VARIANT"
