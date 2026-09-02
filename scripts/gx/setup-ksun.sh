#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock
# shellcheck disable=SC1091
source .gx-variant

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"
KSUN_DIR="$ROOT_DIR/KernelSU-Next"

rm -rf "$KSUN_DIR" drivers/kernelsu

# N45 4.14 uses the pinned legacy/manual-hook tree for both KSUN lanes.
# SUSFS remains a Kconfig/build-time choice; using one manual-hook-capable core
# prevents the no-SUSFS variant from falling back to kprobes/tracepoints.
KSU_REPO="$KSUN_SUSFS_REPO"
KSU_COMMIT="$KSUN_SUSFS_COMMIT"
if [[ "${GX_SUSFS:-0}" == "1" ]]; then
  echo "[GXT] integrating KernelSU-Next SUSFS-v2 manual-hook tree @ $KSU_COMMIT"
else
  echo "[GXT] integrating KernelSU-Next manual-hook core (SUSFS disabled) @ $KSU_COMMIT"
fi

git clone -q "$KSU_REPO" "$KSUN_DIR"
git -C "$KSUN_DIR" checkout -q "$KSU_COMMIT"
actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSU_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSU_COMMIT got $actual" >&2
  exit 4
fi

ln -s "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

python3 - "$DEFCONFIG" "${GX_SUSFS:-0}" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
susfs = sys.argv[2] == '1'
s = p.read_text()

def set_cfg(key, value):
    global s
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}={value}' if value != 'n' else f'# CONFIG_{key} is not set'
    if pat.search(s):
        s = pat.sub(line, s, count=1)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'

set_cfg('KSU', 'y')
set_cfg('EXT4_FS', 'y')
set_cfg('KSU_MANUAL_HOOK', 'y')
set_cfg('KSU_KPROBES_HOOK', 'n')
# Do not force generic Linux KPROBES/KRETPROBES. Preserve the Miatoll baseline.
if not susfs:
    # The pinned manual-hook tree defaults SUSFS on, so explicitly turn it off
    # for the no-SUSFS release variant.
    set_cfg('KSU_SUSFS', 'n')

p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"
test -f "$KSUN_DIR/kernel/supercall/dispatch.c"
grep -Fq 'config KSU_SUSFS' "$KSUN_DIR/kernel/Kconfig"
if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  grep -Fxq '# CONFIG_KSU_SUSFS is not set' "$DEFCONFIG"
fi

echo "[GXT] KernelSU-Next manual-hook integration ready"
