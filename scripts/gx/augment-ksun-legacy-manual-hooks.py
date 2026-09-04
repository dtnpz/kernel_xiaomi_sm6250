#!/usr/bin/env python3
"""Preserve N45's proven legacy KSU callbacks and add the two missing ones.

KernelSU-Next's official `legacy` branch exports the same callback ABI already
present in the ProjectVelvet/N45 4.14 tree.  Do not strip and reinvent those
call sites: validate exec/faccessat/stat/vfs_read/input and only augment the
setresuid + reboot hooks required by current KernelSU-Next manual mode.
"""
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, desc: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"[N45][KSUN-legacy] expected one anchor for {desc}, got {count}")
    return text.replace(old, new, 1)


# These five callbacks are already part of the known N45 vendor tree and match
# the ABI exported by official KernelSU-Next legacy.  Keeping vfs_read and the
# input callback is important for init.rc injection and safe-mode handling.
existing = {
    "fs/exec.c": "ksu_handle_execveat",
    "fs/open.c": "ksu_handle_faccessat",
    "fs/stat.c": "ksu_handle_stat",
    "fs/read_write.c": "ksu_handle_vfs_read",
    "drivers/input/input.c": "ksu_handle_input_handle_event",
}
for path, symbol in existing.items():
    s = read(path)
    if symbol not in s:
        raise SystemExit(f"[N45][KSUN-legacy] missing existing vendor callback: {path}:{symbol}")
    if "CONFIG_KSU" not in s:
        raise SystemExit(f"[N45][KSUN-legacy] callback lacks CONFIG_KSU guard context: {path}:{symbol}")
    print(f"[N45][KSUN-legacy] preserved: {path}:{symbol}")

# kernel/sys.c — zygote/manager setresuid callback.
path = "kernel/sys.c"
s = read(path)
if "ksu_handle_setresuid" not in s:
    extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

'''
    s = replace_once(
        s,
        '/*\n * This function implements a generic ability to update ruid, euid,\n',
        extern + '/*\n * This function implements a generic ability to update ruid, euid,\n',
        "setresuid declaration",
    )
    s = replace_once(
        s,
        'SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n{\n\tstruct user_namespace *ns = current_user_ns();\n',
        'SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n{\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_setresuid(ruid, euid, suid);\n#endif\n\tstruct user_namespace *ns = current_user_ns();\n',
        "setresuid callback",
    )
    write(path, s)
    print("[N45][KSUN-legacy] added: kernel/sys.c:ksu_handle_setresuid")
else:
    print("[N45][KSUN-legacy] already present: kernel/sys.c:ksu_handle_setresuid")

# kernel/reboot.c — manager/supercall FD callback.  KernelSU-Next's handler
# returns 0 for both handled calls and ordinary non-KSU reboot magic, so the
# historical manual-hook contract uses the magic1 discriminator before deciding
# whether to consume the syscall.  Do not return early for normal reboot calls.
path = "kernel/reboot.c"
s = read(path)
if "ksu_handle_sys_reboot" not in s:
    extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
                                 void __user **arg);
#endif

'''
    s = replace_once(
        s,
        '/*\n * Reboot system call: for obvious reasons only root may call it,\n',
        extern + '/*\n * Reboot system call: for obvious reasons only root may call it,\n',
        "reboot declaration",
    )
    # The KernelSU install-fd path uses its private magic1 value.  Call the
    # handler before CAP_SYS_BOOT validation so the unprivileged manager can
    # obtain its anon fd, but only consume the syscall when magic1 is private.
    marker = '#define KSU_INSTALL_MAGIC1 0xDEADBEEF\n'
    if marker not in s:
        # Keep the kernel tree independent from KernelSU private headers while
        # matching the stable/legacy supercall ABI value used by the handler.
        insert = '#ifdef CONFIG_KSU_MANUAL_HOOK\n#define KSU_INSTALL_MAGIC1 0xDEADBEEF\n#endif\n\n'
        s = replace_once(
            s,
            'static DEFINE_MUTEX(reboot_mutex);\n\n',
            'static DEFINE_MUTEX(reboot_mutex);\n\n' + insert,
            "KernelSU reboot magic declaration",
        )
    s = replace_once(
        s,
        '\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n',
        '\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (magic1 == KSU_INSTALL_MAGIC1) {\n\t\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n\t\treturn 0;\n\t}\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n',
        "reboot callback",
    )
    write(path, s)
    print("[N45][KSUN-legacy] added: kernel/reboot.c:ksu_handle_sys_reboot")
else:
    print("[N45][KSUN-legacy] already present: kernel/reboot.c:ksu_handle_sys_reboot")

checks = dict(existing)
checks.update({
    "kernel/sys.c": "ksu_handle_setresuid",
    "kernel/reboot.c": "ksu_handle_sys_reboot",
})
for path, symbol in checks.items():
    if symbol not in read(path):
        raise SystemExit(f"[N45][KSUN-legacy] final verification failed: {path}:{symbol}")

print("[N45][KSUN-legacy] complete seven-callback manual-hook surface ready")
