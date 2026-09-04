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

if [[ "${GX_SUSFS:-0}" == "1" ]]; then
  KSU_REPO="$KSUN_SUSFS_REPO"
  KSU_COMMIT="$KSUN_SUSFS_COMMIT"
  echo "[GXT] integrating KernelSU-Next SUSFS-v2 compatibility tree @ $KSU_COMMIT"
else
  # N45 is Linux 4.14. Use KernelSU-Next's own legacy/manual-hook branch.
  # Do not force the stable v3.3.0 KPROBES path onto this old vendor kernel.
  KSU_REPO="$KSUN_REPO"
  KSU_COMMIT="$KSUN_LEGACY_COMMIT"
  echo "[GXT] integrating official KernelSU-Next ${KSUN_LEGACY_BRANCH} manual-hook tree @ $KSU_COMMIT"
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

def drop_cfg(key):
    global s
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)\n?', re.M)
    s = pat.sub('', s)

set_cfg('KSU', 'y')
set_cfg('EXT4_FS', 'y')
set_cfg('KSU_MANUAL_HOOK', 'y')
set_cfg('KSU_KPROBES_HOOK', 'n')
# Keep the Miatoll baseline for generic MODULES/KPROBES. The official legacy
# branch explicitly supports manual hooks and warns against its kprobe hook
# engine on kernels below 5.10.
if not susfs:
    drop_cfg('KSU_SUSFS')
else:
    set_cfg('KSU_SUSFS', 'y')

p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"

if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  test -f "$KSUN_DIR/kernel/core/init.c"
  test -f "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  test -f "$KSUN_DIR/kernel/supercall/supercall.c"
  grep -Fq 'config KSU_MANUAL_HOOK' "$KSUN_DIR/kernel/Kconfig"
  grep -Fq 'This should not be used on kernel below 5.10' "$KSUN_DIR/kernel/Kconfig"
  grep -Fq 'int ksu_handle_execveat(' "$KSUN_DIR/kernel/core/init.c"
  grep -Fq 'ksu_handle_vfs_read' "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  grep -Fq 'ksu_handle_input_handle_event' "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  grep -Fq 'ksu_handle_sys_reboot' "$KSUN_DIR/kernel/supercall/supercall.c"
  grep -Fq 'No hooks were defined, please integrate manual hooks in your kernel!' "$KSUN_DIR/kernel/Kbuild"
  echo "[GXT] official KernelSU-Next legacy manual-hook integration ready"
else
  grep -Fq 'config KSU_SUSFS' "$KSUN_DIR/kernel/Kconfig"
  grep -Fxq 'CONFIG_KSU_SUSFS=y' "$DEFCONFIG"
  echo "[GXT] KernelSU-Next SUSFS compatibility integration ready"
fi
