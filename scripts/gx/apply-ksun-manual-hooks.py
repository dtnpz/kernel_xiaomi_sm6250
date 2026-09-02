#!/usr/bin/env python3
"""Install the minimal KernelSU-Next manual-hook surface on N45.

This is used by KSUN no-SUSFS variants.  The SUSFS lane gets the same hook
surface from apply-susfs-v2-n45-final-hooks.py.  Keep these hooks at syscall
entry points so we avoid the kprobe/tracepoint hook engine on Linux 4.14.
"""
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, desc: str) -> str:
    if old not in text:
        raise SystemExit(f"[N45][KSUN-manual] missing anchor: {desc}")
    if text.count(old) != 1:
        raise SystemExit(
            f"[N45][KSUN-manual] ambiguous anchor ({text.count(old)}): {desc}"
        )
    return text.replace(old, new, 1)


def require_absent(text: str, needle: str, path: str) -> None:
    if needle in text:
        raise SystemExit(
            f"[N45][KSUN-manual] {path}: stale/duplicate {needle} before adapter"
        )


# fs/exec.c — execve/sucompat/ksud hook.
path = "fs/exec.c"
s = read(path)
require_absent(s, "ksu_handle_execveat", path)
extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                                void *argv, void *envp, int *flags);
#endif
'''
s = replace_once(
    s,
    "int do_execve(struct filename *filename,\n",
    extern + "int do_execve(struct filename *filename,\n",
    "exec manual-hook declaration",
)
s = replace_once(
    s,
    "\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n",
    "\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n",
    "native execve manual hook",
)
s = replace_once(
    s,
    "\t\t.ptr.compat = __envp,\n\t};\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n",
    "\t\t.ptr.compat = __envp,\n\t};\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n",
    "compat execve manual hook",
)
write(path, s)

# fs/open.c — faccessat sucompat hook.
path = "fs/open.c"
s = read(path)
require_absent(s, "ksu_handle_faccessat", path)
extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern __attribute__((hot, always_inline)) int ksu_handle_faccessat(
    int *dfd, const char __user **filename_user, int *mode, int *flags);
#endif

'''
s = replace_once(
    s,
    "/*\n * access() needs to use the real uid/gid, not the effective uid/gid.\n",
    extern + "/*\n * access() needs to use the real uid/gid, not the effective uid/gid.\n",
    "faccessat manual-hook declaration",
)
s = replace_once(
    s,
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\tif (mode & ~S_IRWXO)",
    "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\tif (mode & ~S_IRWXO)",
    "faccessat manual hook",
)
write(path, s)

# fs/stat.c — newfstatat sucompat hook.
path = "fs/stat.c"
s = read(path)
require_absent(s, "ksu_handle_stat", path)
extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern __attribute__((hot, always_inline)) int ksu_handle_stat(
    int *dfd, const char __user **filename_user, int *flags);
#endif

'''
s = replace_once(
    s,
    "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\n",
    extern + "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\n",
    "newfstatat manual-hook declaration",
)
old = '''SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
new = '''SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
s = replace_once(s, old, new, "newfstatat syscall manual hook")
write(path, s)

# kernel/sys.c — zygote/manager setresuid hook.
path = "kernel/sys.c"
s = read(path)
require_absent(s, "ksu_handle_setresuid", path)
extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif

'''
s = replace_once(
    s,
    "/*\n * This function implements a generic ability to update ruid, euid,\n",
    extern + "/*\n * This function implements a generic ability to update ruid, euid,\n",
    "setresuid manual-hook declaration",
)
s = replace_once(
    s,
    "SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n{\n\tstruct user_namespace *ns = current_user_ns();\n",
    "SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)\n{\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_setresuid(ruid, euid, suid);\n#endif\n\tstruct user_namespace *ns = current_user_ns();\n",
    "setresuid manual hook",
)
write(path, s)

# kernel/reboot.c — KernelSU-Next manual supercall/manager hook and Kbuild marker.
path = "kernel/reboot.c"
s = read(path)
require_absent(s, "ksu_handle_sys_reboot", path)
extern = '''#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
                                 void __user **arg);
#endif

'''
s = replace_once(
    s,
    "/*\n * Reboot system call: for obvious reasons only root may call it,\n",
    extern + "/*\n * Reboot system call: for obvious reasons only root may call it,\n",
    "reboot manual-hook declaration",
)
s = replace_once(
    s,
    "\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n",
    "\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n\tif (!ret)\n\t\treturn 0;\n\tret = 0;\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n",
    "reboot manual hook",
)
write(path, s)

checks = {
    "fs/exec.c": "ksu_handle_execveat",
    "fs/open.c": "ksu_handle_faccessat",
    "fs/stat.c": "ksu_handle_stat",
    "kernel/sys.c": "ksu_handle_setresuid",
    "kernel/reboot.c": "ksu_handle_sys_reboot",
}
for f, needle in checks.items():
    text = read(f)
    if needle not in text or "CONFIG_KSU_MANUAL_HOOK" not in text:
        raise SystemExit(f"[N45][KSUN-manual] verification failed: {f}: {needle}")

print("[N45][KSUN-manual] non-kprobe manual hook surface applied")
