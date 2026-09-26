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
  # Pull the real v3.4.0 kernel-side core, not the older legacy/UAPI2 lane.
  # The Linux 4.14 adapter only replaces the syscall interception surface and
  # missing kernel APIs; v3.4.0 policy/features/UAPI (including selinux_hide)
  # remain the source of truth.
  KSU_REPO="$KSUN_REPO"
  KSU_COMMIT="$KSUN_RELEASE_COMMIT"
  echo "[GXT] integrating KernelSU-Next ${KSUN_RELEASE_TAG} kernel core @ $KSU_COMMIT"
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

# v3.4.0 selinux_hide resolves selinuxfs data tables (write_op and
# sel_handle_status_ops) by name. 4.14's KALLSYMS_ALL is unnecessarily gated by
# DEBUG_KERNEL; relax only that menu dependency so the release build can expose
# data symbols without enabling the whole debug-kernel feature set.
if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  python3 - <<'PY'
from pathlib import Path
p = Path("init/Kconfig")
s = p.read_text()
old = """config KALLSYMS_ALL
\tbool "Include all symbols in kallsyms"
\tdepends on DEBUG_KERNEL && KALLSYMS"""
new = """config KALLSYMS_ALL
\tbool "Include all symbols in kallsyms"
\tdepends on KALLSYMS"""
if old not in s:
    raise SystemExit("[GXT] KALLSYMS_ALL 4.14 dependency anchor missing")
p.write_text(s.replace(old, new, 1))
print("[GXT] relaxed KALLSYMS_ALL debug-only gate for KSUN v3.4.0")
PY
fi

python3 - "$DEFCONFIG" "${GX_SUSFS:-0}" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); susfs = sys.argv[2] == '1'; s = p.read_text()

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
if susfs:
    set_cfg('KSU_MANUAL_HOOK', 'y')
    set_cfg('KSU_KPROBES_HOOK', 'n')
    set_cfg('KSU_SUSFS', 'y')
else:
    # v3.4.0 Kconfig requires KPROBES. The GXT 4.14 adapter keeps that
    # dependency satisfied but replaces only the incompatible arm64 syscall
    # dispatcher with native 4.14 call-site callbacks.
    set_cfg('MODULES', 'y')
    set_cfg('KPROBES', 'y')
    set_cfg('KALLSYMS', 'y')
    set_cfg('KALLSYMS_ALL', 'y')
    drop_cfg('KSU_MANUAL_HOOK')
    drop_cfg('KSU_KPROBES_HOOK')
    drop_cfg('KSU_SUSFS')

p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"

if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  grep -Fxq 'CONFIG_MODULES=y' "$DEFCONFIG"
  grep -Fxq 'CONFIG_KPROBES=y' "$DEFCONFIG"
  grep -Fxq 'CONFIG_KALLSYMS=y' "$DEFCONFIG"
  grep -Fxq 'CONFIG_KALLSYMS_ALL=y' "$DEFCONFIG"
  test -f "$KSUN_DIR/kernel/core/init.c"
  test -f "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  test -f "$KSUN_DIR/kernel/feature/selinux_hide.c"
  grep -Fq 'depends on KPROBES && EXT4_FS' "$KSUN_DIR/kernel/Kconfig"
  grep -Fq 'static const __u32 KERNEL_SU_UAPI_VERSION = 4;' "$KSUN_DIR/uapi/supercall.h"
  grep -Fq 'static bool ksu_selinux_hide_enabled __read_mostly = false;' "$KSUN_DIR/kernel/feature/selinux_hide.c"
  if grep -Fq 'blocked transaction_write from uid=' "$KSUN_DIR/kernel/feature/selinux_hide.c"; then
    echo "legacy transaction_write blocker leaked into v3.4.0 lane" >&2
    exit 5
  fi
  echo "[GXT] KernelSU-Next v3.4.0/UAPI4 core pinned; Linux 4.14 bridge will be applied"
else
  grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
  grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"
  grep -Fq 'config KSU_SUSFS' "$KSUN_DIR/kernel/Kconfig"
  grep -Fxq 'CONFIG_KSU_SUSFS=y' "$DEFCONFIG"
  echo "[GXT] KernelSU-Next SUSFS compatibility integration ready"
fi
