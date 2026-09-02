#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"
KSUN_DIR="$ROOT_DIR/KernelSU-Next"

rm -rf "$KSUN_DIR" drivers/kernelsu

echo "[GXT] integrating KernelSU-Next ${KSUN_RELEASE_TAG} @ ${KSUN_RELEASE_COMMIT}"
git clone -q "$KSUN_REPO" "$KSUN_DIR"
git -C "$KSUN_DIR" checkout -q "$KSUN_RELEASE_COMMIT"
actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSUN_RELEASE_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSUN_RELEASE_COMMIT got $actual" >&2
  exit 4
fi

ln -s "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

python3 - "$DEFCONFIG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
# v3.3.0 uses its native KPROBES/syscall hook engine.  Do not enable the
# removed legacy KSU_MANUAL_HOOK/KSU_KPROBES_HOOK switches.
settings = {
    'KSU': 'y',
    'KPROBES': 'y',
    'EXT4_FS': 'y',
}
for key, value in settings.items():
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}=y'
    if pat.search(s):
        s = pat.sub(line, s, count=1)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'
for obsolete in ('KSU_MANUAL_HOOK', 'KSU_KPROBES_HOOK'):
    s = re.sub(rf'^(?:CONFIG_{obsolete}=.*|# CONFIG_{obsolete} is not set)\n?', '', s, flags=re.M)
p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KPROBES=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"
test -f "$KSUN_DIR/kernel/feature/selinux_hide.c"

echo "[GXT] KernelSU-Next ${KSUN_RELEASE_TAG} native-hook integration ready"
