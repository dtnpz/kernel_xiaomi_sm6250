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

rm -rf "$KSUN_DIR"
rm -rf drivers/kernelsu
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

python3 - "$DEFCONFIG" <<'PY'
from pathlib import Path
import re, sys

defconfig = Path(sys.argv[1])

# Match upstream setup.sh semantics: Makefile append; Kconfig source before endmenu.
p = Path('drivers/Makefile')
s = p.read_text()
line = 'obj-$(CONFIG_KSU) += kernelsu/'
if line not in s:
    s = s.rstrip() + '\n\n' + line + '\n'
p.write_text(s)

p = Path('drivers/Kconfig')
s = p.read_text()
line = 'source "drivers/kernelsu/Kconfig"'
if line not in s:
    pos = s.rfind('endmenu')
    if pos < 0:
        raise SystemExit('drivers/Kconfig: endmenu not found')
    s = s[:pos] + line + '\n\n' + s[pos:]
p.write_text(s)

# 4.14 must use the legacy/manual path, never the 5.10+ kprobe path.
s = defconfig.read_text()
keys = ('KSU', 'KSU_MANUAL_HOOK', 'KSU_KPROBES_HOOK')
out = []
for line in s.splitlines():
    if any(re.match(rf'^(?:# )?CONFIG_{re.escape(k)}(?:=.*| is not set)$', line) for k in keys):
        continue
    out.append(line)
out += [
    'CONFIG_KSU=y',
    'CONFIG_KSU_MANUAL_HOOK=y',
    '# CONFIG_KSU_KPROBES_HOOK is not set',
]
defconfig.write_text('\n'.join(out) + '\n')

# Velvet already carries three of KSUN's manual VFS call-sites.
checks = {
    'fs/exec.c': 'ksu_handle_execveat(',
    'fs/open.c': 'ksu_handle_faccessat(',
    'fs/stat.c': 'ksu_handle_stat(',
}
for path, needle in checks.items():
    if needle not in Path(path).read_text():
        raise SystemExit(f'{path}: missing expected existing manual hook {needle}')

# Add the one missing UID transition hook at syscall entry.
p = Path('kernel/sys.c')
s = p.read_text()
if 'ksu_handle_setresuid(' not in s:
    decl_anchor = '''/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{'''
    decl_repl = '''/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)
{'''
    if s.count(decl_anchor) != 1:
        raise SystemExit('kernel/sys.c: setresuid declaration context drifted')
    s = s.replace(decl_anchor, decl_repl, 1)

    call_anchor = '''\tint retval;
\tkuid_t kruid, keuid, ksuid;

\tkruid = make_kuid(ns, ruid);'''
    call_repl = '''\tint retval;
\tkuid_t kruid, keuid, ksuid;
#ifdef CONFIG_KSU
\t(void)ksu_handle_setresuid(ruid, euid, suid);
#endif

\tkruid = make_kuid(ns, ruid);'''
    if s.count(call_anchor) != 1:
        raise SystemExit('kernel/sys.c: setresuid local context drifted')
    s = s.replace(call_anchor, call_repl, 1)
p.write_text(s)

# KSUN's legacy Kbuild explicitly requires this manual reboot hook marker.
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
\t/* KSUN uses reboot as a side-effect supercall channel. Continue through
\t * Linux's normal CAP_SYS_BOOT/magic validation for ordinary reboot calls. */
\t(void)ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

\t/* We only trust the superuser with rebooting the system. */'''
    if s.count(call_anchor) != 1:
        raise SystemExit('kernel/reboot.c: reboot syscall context drifted')
    s = s.replace(call_anchor, call_repl, 1)
p.write_text(s)
PY

grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile
grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig
grep -Fq 'ksu_handle_sys_reboot' kernel/reboot.c
grep -Fq 'ksu_handle_setresuid' kernel/sys.c
grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"

echo "[N45] KernelSU-Next legacy/manual integration ready: $actual"
