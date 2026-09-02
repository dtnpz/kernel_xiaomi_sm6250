#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

if [[ ! -f .gx-variant ]]; then
  echo "Missing .gx-variant metadata." >&2
  exit 2
fi

# shellcheck disable=SC1091
source .gx-variant

: "${GX_VARIANT:?GX_VARIANT missing}"
: "${GX_ROOT:=none}"
: "${GX_SUSFS:=0}"
: "${GX_BP:=0}"
: "${GX_DEFCONFIG:=vendor/miatoll-perf_defconfig}"

case "$GX_ROOT" in
  none|xxksu|ksun) ;;
  *) echo "Unknown GX_ROOT=$GX_ROOT" >&2; exit 2 ;;
esac

case "$GX_SUSFS" in 0|1) ;; *) echo "GX_SUSFS must be 0/1" >&2; exit 2 ;; esac
case "$GX_BP" in 0|1) ;; *) echo "GX_BP must be 0/1" >&2; exit 2 ;; esac

if [[ "$GX_ROOT" == none && "$GX_SUSFS" == 1 ]]; then
  echo "SUSFS is forbidden on NONKSU variants." >&2
  exit 2
fi

# Nexus v4.5's published MM target uses swappiness=60. Keep this as a common
# build-time N45 delta so every release variant inherits the same MM behavior.
python3 - <<'PY'
from pathlib import Path
p = Path('mm/vmscan.c')
s = p.read_text()
old = 'int vm_swappiness = 10;'
new = 'int vm_swappiness = 60;'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('Unexpected vm_swappiness source state; refusing to guess')
p.write_text(s)
PY

# The source tree still carries Velvet's old localversion. Give every build an
# unambiguous N45 banner without keeping six duplicate defconfigs in git.
defconfig_path="arch/arm64/configs/$GX_DEFCONFIG"
if [[ ! -f "$defconfig_path" ]]; then
  echo "Defconfig not found: $defconfig_path" >&2
  exit 2
fi
python3 - "$defconfig_path" "$GX_VARIANT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
variant = sys.argv[2]
s = p.read_text()
line = f'CONFIG_LOCALVERSION="-N45-{variant}"'
pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
if pat.search(s):
    s = pat.sub(line, s, count=1)
else:
    s = line + '\n' + s
p.write_text(s)
PY

# Layer order is deliberately fixed so every family differs minimally:
# common N45 base -> optional selected BPF backports -> one root -> SUSFS.
if [[ "$GX_BP" == 1 ]]; then
  if [[ ! -f scripts/gx/apply-bp510.sh ]]; then
    echo "BP requested but scripts/gx/apply-bp510.sh is not ready." >&2
    exit 3
  fi
  bash scripts/gx/apply-bp510.sh
fi

case "$GX_ROOT" in
  none)
    ;;
  xxksu)
    if [[ ! -f scripts/gx/setup-xxksu.sh ]]; then
      echo "xxKSU requested but setup script is not ready." >&2
      exit 3
    fi
    bash scripts/gx/setup-xxksu.sh
    ;;
  ksun)
    if [[ ! -f scripts/gx/setup-ksun.sh ]]; then
      echo "KSUN requested but setup script is not ready." >&2
      exit 3
    fi
    bash scripts/gx/setup-ksun.sh
    ;;
esac

# ProjectVelvet carries legacy manual KernelSU call sites. Modern xxKSU has
# its own syscall/LSM/input paths and does not export those old callbacks.
# This cleanup is required regardless of whether SUSFS is enabled.
if [[ "$GX_ROOT" == "xxksu" ]]; then
  if [[ ! -f scripts/gx/strip-xxksu-legacy-vendor-hooks.py ]]; then
    echo "xxKSU legacy vendor-hook cleanup helper missing." >&2
    exit 3
  fi
  python3 scripts/gx/strip-xxksu-legacy-vendor-hooks.py
fi

if [[ "$GX_SUSFS" == 1 ]]; then
  if [[ ! -f scripts/gx/setup-susfs.sh ]]; then
    echo "SUSFS requested but setup script is not ready." >&2
    exit 3
  fi
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"

  if [[ ! -f scripts/gx/add-susfs-v155-bridges.py ]]; then
    echo "SUSFS v1.5.5 ABI bridge helper missing." >&2
    exit 3
  fi
  case "$GX_ROOT" in
    xxksu) KSU_DIR="$ROOT_DIR/KernelSU" ;;
    ksun)  KSU_DIR="$ROOT_DIR/KernelSU-Next" ;;
    *) echo "SUSFS ABI bridge requires a rooted variant." >&2; exit 3 ;;
  esac
  python3 scripts/gx/add-susfs-v155-bridges.py "$KSU_DIR" "$GX_ROOT"
fi

echo "[N45] variant preparation complete: $GX_VARIANT"
