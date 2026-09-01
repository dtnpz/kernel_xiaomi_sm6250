#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"
KSUN_DIR="$ROOT_DIR/KernelSU-Next"

rm -rf "$KSUN_DIR"
rm -rf drivers/kernelsu

echo "[N45] integrating KernelSU-Next legacy ${KSUN_LEGACY_COMMIT}"
git clone -q "$KSUN_REPO" "$KSUN_DIR"
git -C "$KSUN_DIR" checkout -q "$KSUN_LEGACY_COMMIT"
actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSUN_LEGACY_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSUN_LEGACY_COMMIT got $actual" >&2
  exit 4
fi

ln -s "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

python3 <<'PY'
from pathlib import Path
import re

def one_replace(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if s.count(old) != 1:
        raise SystemExit(f'{path}: expected exactly one {label} insertion point, found {s.count(old)}')
    p.write_text(s.replace(old, new, 1))

for path, needle in (
    ('fs/exec.c', 'ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);'),
    ('fs/open.c', 'ksu_handle_faccessat(&dfd, &filename, &mode, NULL);'),
):
    if needle not in Path(path).read_text():
        raise SystemExit(f'{path}: expected existing Velvet KSU manual hook is missing')

stat_decl = '''#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n\n'''
stat_anchor = '/**\n * vfs_statx - Get basic and extra attributes by filename\n'
one_replace('fs/stat.c', stat_anchor, stat_decl + stat_anchor, 'vfs_statx declaration')

stat_call_anchor = '\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n'
stat_call = stat_call_anchor + '''#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\n'''
one_replace('fs/stat.c', stat_call_anchor, stat_call, 'vfs_statx hook')

uid_decl_anchor = '''/*\n * This function implements a generic ability to update ruid, euid,\n * and suid.  This allows you to implement the 4.4 compatible seteuid().\n */\n'''
uid_decl = uid_decl_anchor + '''#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n\n'''
one_replace('kernel/sys.c', uid_decl_anchor, uid_decl, 'setresuid declaration')

uid_call_anchor = '''SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n{\n'''
uid_call = uid_call_anchor + '''#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n'''
one_replace('kernel/sys.c', uid_call_anchor, uid_call, 'setresuid hook')

# KSUN legacy Kbuild explicitly validates the reboot supercall hook.  It is
# also functionally required: ksud asks reboot() for the anonymous driver fd
# before normal CAP_SYS_BOOT validation, so the hook must run before that gate.
reboot_decl_anchor = '''static DEFINE_MUTEX(reboot_mutex);\n\n/*\n * Reboot system call: for obvious reasons only root may call it,\n'''
reboot_decl = '''static DEFINE_MUTEX(reboot_mutex);\n\n#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n/*\n * Reboot system call: for obvious reasons only root may call it,\n'''
one_replace('kernel/reboot.c', reboot_decl_anchor, reboot_decl, 'reboot supercall declaration')

reboot_call_anchor = '''\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n'''
reboot_call = '''\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU\n\t(void)ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\n\t/* We only trust the superuser with rebooting the system. */\n'''
one_replace('kernel/reboot.c', reboot_call_anchor, reboot_call, 'reboot supercall hook')

p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()
settings = {'KSU': 'y', 'KSU_MANUAL_HOOK': 'y', 'KSU_KPROBES_HOOK': 'n'}
for key, value in settings.items():
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}=y' if value == 'y' else f'# CONFIG_{key} is not set'
    if pat.search(s):
        s = pat.sub(line, s)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'
p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"
grep -Fq 'ksu_handle_stat(&dfd, &filename, &flags);' fs/stat.c
grep -Fq 'ksu_handle_setresuid(ruid, euid, suid);' kernel/sys.c
grep -Fq 'ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);' kernel/reboot.c

echo "[N45] KernelSU-Next legacy/manual integration ready"
