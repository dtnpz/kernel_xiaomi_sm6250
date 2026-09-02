#!/usr/bin/env python3
"""Adapt final SUSFS v2.2/manual-hook state to N45 vendor hot-path files.

The Xiaomi 4.14.357 reference and N45 differ heavily in these files because
N45 carries Qualcomm/MIUI proc formatting and obsolete ProjectVelvet KSU
callbacks.  Replaying every historical SUSFS hunk is both fragile and noisy.
Instead, the generic SUSFS series is applied with these files excluded and we
install only the final manual-hook + SUS_MAP/KSTAT behavior here.
"""
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, desc: str) -> str:
    if old not in text:
        raise SystemExit(f"[N45][SUSFS-v2] missing anchor: {desc}")
    if text.count(old) != 1:
        raise SystemExit(f"[N45][SUSFS-v2] ambiguous anchor ({text.count(old)}): {desc}")
    return text.replace(old, new, 1)


def require_absent(text: str, needle: str, path: str) -> None:
    if needle in text:
        raise SystemExit(f"[N45][SUSFS-v2] {path}: stale/duplicate {needle} before final adapter")


# ---------------------------------------------------------------------------
# fs/exec.c — final manual-hook placement: do_execve + compat_do_execve only.
# Do not re-add the old ProjectVelvet hook in do_execveat_common().
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# fs/open.c — final faccessat manual hook.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# fs/stat.c — final newfstatat manual hook.  Do not hook vfs_statx globally;
# keeping the interception at syscall entry avoids extra work in kernel users.
# ---------------------------------------------------------------------------
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
# Several stat-family wrappers share the same vfs_fstatat() prologue on this
# vendor tree. Scope the edit to the actual newfstatat syscall signature so we
# never hook old/compat wrappers by accident.
newfstatat_old = '''SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
newfstatat_new = '''SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
s = replace_once(s, newfstatat_old, newfstatat_new, "newfstatat syscall manual hook")
write(path, s)

# ---------------------------------------------------------------------------
# kernel/reboot.c — this is also the marker the KSUN Kbuild uses to verify
# that manual hooks are actually integrated.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# fs/proc/task_mmu.c — preserve N45's optimized Qualcomm/Android proc/smaps
# implementation and fold in only final SUSFS v2.2 SUS_MAP + SUS_KSTAT logic.
# ---------------------------------------------------------------------------
path = "fs/proc/task_mmu.c"
s = read(path)
if "<linux/susfs_def.h>" not in s:
    s = replace_once(
        s,
        "#include <linux/uaccess.h>\n",
        "#include <linux/uaccess.h>\n#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP)\n#include <linux/susfs_def.h>\n#endif\n",
        "task_mmu susfs include",
    )
if "susfs_show_map_vma_spoofer" not in s:
    s = replace_once(
        s,
        '#include "internal.h"\n',
        '#include "internal.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\nextern void susfs_show_map_vma_spoofer(struct inode *inode, dev_t *out_dev, unsigned long *out_ino);\n#endif\n',
        "task_mmu kstat declaration",
    )
s = replace_once(
    s,
    "\tif (file) {\n\t\tstruct inode *inode = file_inode(vma->vm_file);\n\t\tdev = inode->i_sb->s_dev;\n\t\tino = inode->i_ino;\n\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n\t}\n",
    "\tif (file) {\n\t\tstruct inode *inode = file_inode(vma->vm_file);\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tif (SUSFS_IS_INODE_SUS_MAP(inode))\n\t\t\treturn;\n#endif\n\t\tdev = inode->i_sb->s_dev;\n\t\tino = inode->i_ino;\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\t\tsusfs_show_map_vma_spoofer(inode, &dev, &ino);\n#endif\n\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n\t}\n",
    "task_mmu maps SUS_MAP/KSTAT",
)
# Skip hidden file-backed VMAs from smaps. For rollup we bypass accounting but
# continue the local rollup state machine, matching the maintained Xiaomi port.
needle = "\t}\n\n#ifdef CONFIG_SHMEM\n\t/* In case of smaps_rollup, reset the value from previous vma */\n"
insert = "\t}\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))) {\n\t\tif (rollup_mode)\n\t\t\tgoto susfs_bypass_smaps_walk;\n\t\treturn 0;\n\t}\n#endif\n\n#ifdef CONFIG_SHMEM\n\t/* In case of smaps_rollup, reset the value from previous vma */\n"
s = replace_once(s, needle, insert, "task_mmu smaps SUS_MAP pre-walk")
s = replace_once(
    s,
    "\twalk_page_vma(vma, smaps_walk_target_ops, mss);\n\n\tif (!rollup_mode) {\n",
    "\twalk_page_vma(vma, smaps_walk_target_ops, mss);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nsusfs_bypass_smaps_walk:\n#endif\n\tif (!rollup_mode) {\n",
    "task_mmu smaps SUS_MAP bypass label",
)
write(path, s)

# Fail fast if the final expected hook surface is incomplete.
checks = {
    "fs/exec.c": ["ksu_handle_execveat", "CONFIG_KSU_MANUAL_HOOK"],
    "fs/open.c": ["ksu_handle_faccessat", "CONFIG_KSU_MANUAL_HOOK"],
    "fs/stat.c": ["ksu_handle_stat", "CONFIG_KSU_MANUAL_HOOK"],
    "kernel/reboot.c": ["ksu_handle_sys_reboot", "CONFIG_KSU_MANUAL_HOOK"],
    "fs/proc/task_mmu.c": ["SUSFS_IS_INODE_SUS_MAP", "susfs_show_map_vma_spoofer"],
}
for f, needles in checks.items():
    text = read(f)
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"[N45][SUSFS-v2] final adapter verification failed: {f}: {needle}")

print("[N45][SUSFS-v2] final N45 vendor hooks adapted")
