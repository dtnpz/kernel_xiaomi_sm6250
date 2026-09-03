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

# #185: remove the failed #184 swappiness experiment. Runtime logs show
# swappiness=60 drove substantially more swap/reclaim and severe vmpressure
# bursts; keep the kernel's conservative 10 while fixing LMK policy itself.
python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
if 'int vm_swappiness = 10;' not in s:
    raise SystemExit('Unexpected vm_swappiness baseline; expected 10 for #185')
if 'int vm_swappiness = 60;' in s:
    raise SystemExit('Failed #184 swappiness=60 experiment is still present')
print('[N45] #185 keeps vm_swappiness=10 after rejecting #184 swappiness=60')
PY

# Keep the #183/#184 de-RT scheduler adaptation: the LMK control workers must
# not starve system_server/Binder/UI at RR99/RR98 during vmpressure bursts.
python3 scripts/gx/adapt-simple-lmk-scheduler.py

defconfig_path="arch/arm64/configs/$GX_DEFCONFIG"

# N45 had tuned Simple LMK much more aggressively than the driver's linux-4.14
# defaults (245 MiB / 100 ms versus upstream 128 MiB / 200 ms). #184 logs show
# repeated reclaim bursts eventually killing adj 100/200 processes including
# the launcher and telephony-related services. Restore the upstream 4.14 policy
# before adding any custom kill floor or other local heuristics.
python3 - "$defconfig_path" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
settings = {
    'ANDROID_SIMPLE_LMK_MINFREE': '128',
    'ANDROID_SIMPLE_LMK_TIMEOUT_MSEC': '200',
}
for key, value in settings.items():
    pat = re.compile(rf'^CONFIG_{re.escape(key)}=.*$', re.M)
    m = pat.search(s)
    if not m:
        raise SystemExit(f'Missing CONFIG_{key} in defconfig')
    s = pat.sub(f'CONFIG_{key}={value}', s, count=1)
p.write_text(s)
print('[N45] #185 restored Simple LMK linux-4.14 policy: MINFREE=128 MiB TIMEOUT=200 ms')
PY

python3 - "$defconfig_path" "$GX_VARIANT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); variant = sys.argv[2]; s = p.read_text()
line = f'CONFIG_LOCALVERSION="-Gxter-{variant}-FuckMiatollCommu"'
pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
s = pat.sub(line, s, count=1) if pat.search(s) else line + '\n' + s
p.write_text(s)
PY

grep -Fxq 'CONFIG_ANDROID_SIMPLE_LMK_MINFREE=128' "$defconfig_path"
grep -Fxq 'CONFIG_ANDROID_SIMPLE_LMK_TIMEOUT_MSEC=200' "$defconfig_path"

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

# KSUN no-SUSFS still uses the non-kprobe/manual-hook engine on N45. Install
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
