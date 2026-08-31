#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"

rm -rf KernelSU
rm -rf drivers/kernelsu

SETUP_URL="https://raw.githubusercontent.com/backslashxx/KernelSU/${XXKSU_COMMIT}/kernel/setup.sh"
echo "[N45] integrating backslashxx KernelSU ${XXKSU_TAG} (${XXKSU_COMMIT})"
curl -fL --retry 3 --retry-delay 2 "$SETUP_URL" | sh -s -- "$XXKSU_COMMIT"

actual="$(git -C KernelSU rev-parse HEAD)"
if [[ "$actual" != "$XXKSU_COMMIT" ]]; then
  echo "xxKSU pin mismatch: expected $XXKSU_COMMIT got $actual" >&2
  exit 4
fi

python3 <<'PY'
from pathlib import Path
import re

p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()

settings = {
    'KSU': 'y',
    'KSU_TAMPER_SYSCALL_TABLE': 'y',
    'KSU_HACK_ARM64_BRANCH_LINK': 'n',
    'KSU_KPROBES_KSUD': 'n',
    'KSU_LSM_SECURITY_HOOKS': 'y',
}

for key, value in settings.items():
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}={value}' if value != 'n' else f'# CONFIG_{key} is not set'
    if pat.search(s):
        s = pat.sub(line, s)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'

p.write_text(s)
PY

# 4.14 uses the syscall-table path, not branch-link or early kprobes.
grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_TAMPER_SYSCALL_TABLE=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_HACK_ARM64_BRANCH_LINK is not set' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_KSUD is not set' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_LSM_SECURITY_HOOKS=y' "$DEFCONFIG"

echo "[N45] backslashxx KernelSU integration ready"
