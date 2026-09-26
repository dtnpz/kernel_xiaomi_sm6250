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

# Keep #180's runtime swappiness setting unchanged while isolating the next
# memory-pressure variable. Device logs confirm swappiness is really 10, yet
# direct reclaim and repeated Simple LMK bursts still coincide with stalls.
python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
if 'int vm_swappiness = 10;' not in s:
    raise SystemExit('Unexpected vm_swappiness baseline; expected 10')
if 'int vm_swappiness = 60;' in s:
    raise SystemExit('N45 swappiness override to 60 is still present')
PY

# #181 isolation test: keep Simple LMK trigger/minfree/victim semantics intact,
# but stop its control workers from running at RR99/RR98 on performance CPUs.
# Victim exit threads remain RR1 so memory is still returned promptly.
python3 scripts/gx/adapt-simple-lmk-scheduler.py

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

# KSUN no-SUSFS now uses the real v3.4.0 modern/UAPI4 core. Do not graft the
# legacy manual-hook lifecycle or DirtySepolicy shim onto it: the old shim
# hard-blocked selinuxfs transaction_write for every app UID and caused A15
# userspace to stall during boot. v3.4.0's selinux_hide uses a backup policy
# view instead and starts disabled until ksud applies the persisted feature.
if [[ "$GX_ROOT" == "ksun" && "$GX_SUSFS" == "0" ]]; then
  python3 scripts/gx/adapt-ksun340-414.py
  grep -Fq 'static const __u32 KERNEL_SU_UAPI_VERSION = 4;' KernelSU-Next/uapi/supercall.h
  if grep -Fq 'blocked transaction_write from uid=' KernelSU-Next/kernel/feature/selinux_hide.c; then
    echo "legacy selinux_hide transaction blocker must not be present" >&2
    exit 6
  fi
fi

if [[ "$GX_SUSFS" == 1 ]]; then
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"
  # SUSFS needs the newer IDA API, but its 4.14 reference chain assumes a
  # pre-existing XArray backport. N45 does not have XArray; keep the API while
  # retaining the proven radix-tree/simple-lock implementation used by 4.14.
  python3 scripts/gx/adapt-ida-414-no-xarray.py
fi

echo "[GXT] variant preparation complete: $GX_VARIANT"
