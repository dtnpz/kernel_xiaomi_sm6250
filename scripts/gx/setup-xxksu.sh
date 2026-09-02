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

# Miatoll runtime adaptation: never run manager discovery synchronously on the
# packages.list observer and never spawn a high-priority scanner per event.
python3 scripts/gx/adapt-xxksu-throne-worker.py

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
    # Retain the upstream option for generated-config visibility; the N45
    # adapter above additionally coalesces all events onto one worker.
    'KSU_THRONE_TRACKER_ALWAYS_THREADED': 'y',
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
grep -Fxq 'CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED=y' "$DEFCONFIG"

# Validate the current conservative single-flight scheduler, not the obsolete
# persistent waitqueue implementation from the previous experiment.
grep -Fq 'static atomic_t throne_tracker_running = ATOMIC_INIT(0);' KernelSU/kernel/manager/throne_tracker.c
grep -Fq 'atomic_cmpxchg(&throne_tracker_running, 0, 1)' KernelSU/kernel/manager/throne_tracker.c
grep -Fq 'is_file_existing("/data/system/packages.list.tmp")' KernelSU/kernel/manager/throne_tracker.c
grep -Fq 'is_file_stable(SYSTEM_PACKAGES_LIST_PATH)' KernelSU/kernel/manager/throne_tracker.c
grep -Fq 'throne_tracker_fn(prune_only);' KernelSU/kernel/manager/throne_tracker.c
grep -Fq 'set_user_nice(current, 10);' KernelSU/kernel/manager/throne_tracker.c
! grep -Fq 'set_user_nice(current, -10);' KernelSU/kernel/manager/throne_tracker.c
! grep -Fq 'packages.list did not stabilize; deferring scan' KernelSU/kernel/manager/throne_tracker.c

echo "[N45] backslashxx KernelSU integration ready"
