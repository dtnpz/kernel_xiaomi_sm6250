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

# no-SUSFS must use the real upstream KernelSU-Next release, not the old
# sidex15 legacy/manual-hook fork.  The latter is kept only as a SUSFS-v2
# compatibility source and is not a v3.3.0 descendant.
if [[ "${GX_SUSFS:-0}" == "1" ]]; then
  KSU_REPO="$KSUN_SUSFS_REPO"
  KSU_COMMIT="$KSUN_SUSFS_COMMIT"
  echo "[GXT] integrating KernelSU-Next SUSFS-v2 compatibility tree @ $KSU_COMMIT"
else
  KSU_REPO="$KSUN_REPO"
  KSU_COMMIT="$KSUN_RELEASE_COMMIT"
  echo "[GXT] integrating official KernelSU-Next ${KSUN_RELEASE_TAG} @ $KSU_COMMIT"
fi

git clone -q "$KSU_REPO" "$KSUN_DIR"
git -C "$KSUN_DIR" checkout -q "$KSU_COMMIT"
actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSU_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSU_COMMIT got $actual" >&2
  exit 4
fi

if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  tag="$(git -C "$KSUN_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ "$tag" != "$KSUN_RELEASE_TAG" ]]; then
    echo "KSUN release tag mismatch: expected $KSUN_RELEASE_TAG got ${tag:-none}" >&2
    exit 4
  fi
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
if susfs:
    set_cfg('KSU_MANUAL_HOOK', 'y')
    set_cfg('KSU_KPROBES_HOOK', 'n')
else:
    # Official v3.3.0 uses its own syscall-hook/event-bridge engine and its
    # Kconfig explicitly depends on KPROBES.  Do not pretend this is the
    # sidex manual-hook ABI: enable the dependency and remove stale fork-only
    # options from the inherited defconfig.
    set_cfg('KPROBES', 'y')
    drop_cfg('KSU_MANUAL_HOOK')
    drop_cfg('KSU_KPROBES_HOOK')
    drop_cfg('KSU_SUSFS')

p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"
if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  grep -Fxq 'CONFIG_KPROBES=y' "$DEFCONFIG"
  test -f "$KSUN_DIR/kernel/hook/syscall_event_bridge.c"
  test -f "$KSUN_DIR/kernel/hook/arm64/syscall_hook.c"
  grep -Fq 'kernelsu-objs += hook/syscall_event_bridge.o' "$KSUN_DIR/kernel/Kbuild"
  grep -Fq 'depends on KPROBES && EXT4_FS' "$KSUN_DIR/kernel/Kconfig"
  echo "[GXT] official KernelSU-Next ${KSUN_RELEASE_TAG} native hook integration ready"
else
  grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
  grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"
  grep -Fq 'config KSU_SUSFS' "$KSUN_DIR/kernel/Kconfig"
  echo "[GXT] KernelSU-Next SUSFS compatibility integration ready"
fi
