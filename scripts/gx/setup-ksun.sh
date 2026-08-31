#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock
# shellcheck disable=SC1091
source .gx-variant

: "${KSUN_REPO:?KSUN_REPO missing}"
: "${KSUN_LEGACY_COMMIT:?KSUN_LEGACY_COMMIT missing}"
: "${GX_DEFCONFIG:=vendor/miatoll-perf_defconfig}"

KSUN_DIR="$ROOT_DIR/KernelSU-Next"
DEFCONFIG="arch/arm64/configs/$GX_DEFCONFIG"

rm -rf "$KSUN_DIR" drivers/kernelsu
mkdir -p "$KSUN_DIR"
git -C "$KSUN_DIR" init -q
git -C "$KSUN_DIR" remote add origin "$KSUN_REPO"
git -C "$KSUN_DIR" fetch -q --depth=1 origin "$KSUN_LEGACY_COMMIT"
git -C "$KSUN_DIR" checkout -q --detach FETCH_HEAD

actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSUN_LEGACY_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSUN_LEGACY_COMMIT got $actual" >&2
  exit 4
fi

ln -s ../KernelSU-Next/kernel drivers/kernelsu

python3 <<'PY'
from pathlib import Path
import re

# Wire pinned KSUN into drivers only once.
p = Path('drivers/Makefile')
s = p.read_text()
line = 'obj-$(CONFIG_KSU) += kernelsu/'
if line not in s:
    if not s.endswith('\n'):
        s += '\n'
    s += '\n# GX N45 pinned KernelSU-Next\n' + line + '\n'
p.write_text(s)

p = Path('drivers/Kconfig')
s = p.read_text()
line = 'source "drivers/kernelsu/Kconfig"'
if line not in s:
    if not s.endswith('\n'):
        s += '\n'
    s += '\n# GX N45 pinned KernelSU-Next\n' + line + '\n'
p.write_text(s)

# Force 4.14 manual mode; do not allow the >=5.10 kprobe path.
p = Path('arch/arm64/configs/' + __import__('os').environ.get('GX_DEFCONFIG', 'vendor/miatoll-perf_defconfig'))
s = p.read_text()
keys = ('KSU', 'KSU_MANUAL_HOOK', 'KSU_KPROBES_HOOK')
lines = []
for line in s.splitlines():
    if any(re.match(rf'^(?:# )?CONFIG_{re.escape(k)}(?:=| is not set)', line) for k in keys):
        continue
    lines.append(line)
lines += [
    'CONFIG_KSU=y',
    'CONFIG_KSU_MANUAL_HOOK=y',
    '# CONFIG_KSU_KPROBES_HOOK is not set',
]
p.write_text('\n'.join(lines) + '\n')

# Existing Velvet manual hooks must remain present. Refuse to paper over drift.
checks = {
    'fs/exec.c': 'ksu_handle_execveat(',
    'fs/open.c': 'ksu_handle_faccessat(',
    'fs/stat.c': 'ksu_handle_stat(',
}
for path, needle in checks.items():
    if needle not in Path(path).read_text():
        raise SystemExit(f'{path}: missing expected existing manual KSU hook {needle}')

# Add only the missing setresuid hook.
p = Path('kernel/sys.c')
s = p.read_text()
if 'ksu_handle_setresuid(' not in s:
    anchor = '''/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{'''
    repl = '''/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t euid, uid_t suid)
{'''
    # Preserve this tree's exact macro spelling if it differs from the common form.
    if anchor not in s:
        anchor = '''/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{'''
    if anchor not in s:
        raise SystemExit('kernel/sys.c: setresuid declaration context drifted')
    # Insert declaration without rewriting the syscall signature.
    s = s.replace(anchor, anchor.replace('SYSCALL_DEFINE3', '#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n\nSYSCALL_DEFINE3'), 1)

    call_anchor = '''\tkuid_t kruid, keuid, ksuid;

\tkruid = make_kuid(ns, ruid);'''
    call_repl = '''\tkuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU
\t(void)ksu_handle_setresuid(ruid, euid, suid);
#endif

\tkruid = make_kuid(ns, ruid);'''
    if call_anchor not in s:
        raise SystemExit('kernel/sys.c: setresuid local context drifted')
    s = s.replace(call_anchor, call_repl, 1)
p.write_text(s)

# KSUN legacy Kbuild explicitly requires a manual reboot hook marker.
p = Path('kernel/reboot.c')
s = p.read_text()
if 'ksu_handle_sys_reboot(' not in s:
    decl_anchor = 'static DEFINE_MUTEX(reboot_mutex);\n'
    decl_repl = '''static DEFINE_MUTEX(reboot_mutex);

#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
                                 void __user **arg);
#endif
'''
    if s.count(decl_anchor) != 1:
        raise SystemExit('kernel/reboot.c: reboot mutex context drifted')
    s = s.replace(decl_anchor, decl_repl, 1)

    call_anchor = '''\tchar buffer[256];
\tint ret = 0;

\t/* We only trust the superuser with rebooting the system. */'''
    call_repl = '''\tchar buffer[256];
\tint ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
\t/* KSUN supercall uses reboot as a side-effect channel; normal reboot
\t * validation continues below for non-KSU calls. */
\t(void)ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

\t/* We only trust the superuser with rebooting the system. */'''
    if s.count(call_anchor) != 1:
        raise SystemExit('kernel/reboot.c: reboot syscall context drifted')
    s = s.replace(call_anchor, call_repl, 1)
p.write_text(s)
PY

# Kbuild's own manual-hook gate looks specifically for this marker.
grep -q 'ksu_handle_sys_reboot' kernel/reboot.c
grep -q 'ksu_handle_setresuid' kernel/sys.c
grep -q '^CONFIG_KSU=y$' "$DEFCONFIG"
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$DEFCONFIG"
grep -q '^# CONFIG_KSU_KPROBES_HOOK is not set$' "$DEFCONFIG"

echo "[N45] KernelSU-Next legacy/manual integration prepared at $actual"
