#!/usr/bin/env python3
"""Guarded SUSFS v1.5.5 adaptation for backslashxx KernelSU v3.3.0-2."""
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: adapt-xxksu-susfs-v155.py <KernelSU-dir> <temporary-patch>')
ksu = Path(sys.argv[1]); patch = Path(sys.argv[2])

# Preserve xxKSU's own setuid/unmount logic. Add only the old SUSFS task-state
# marker and put SUSFS-specific try-umount targets before xxKSU's own list.
setuid = ksu / 'kernel/hook/setuid_hook.c'
s = setuid.read_text()
start = 'static __always_inline void ksu_handle_setresuid_cred(struct cred *new, const struct cred *old)\n'
if s.count(start) != 1:
    raise SystemExit(f'xxKSU setuid start anchor count={s.count(start)}')
s = s.replace(start, '''#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#endif

''' + start, 1)
old = '''\t// Handle kernel umount
\tksu_handle_umount(new, old);
\treturn;
'''
new = '''#ifdef CONFIG_KSU_SUSFS
\ttask_lock(current);
\tcurrent->susfs_task_state |= TASK_STRUCT_NON_ROOT_USER_APP_PROC;
\ttask_unlock(current);
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
\tsusfs_try_umount(new_uid);
#endif
\t// Preserve xxKSU's own kernel-unmount layer after SUSFS targets.
\tksu_handle_umount(new, old);
\treturn;
'''
if s.count(old) != 1:
    raise SystemExit(f'xxKSU setuid unmount anchor count={s.count(old)}')
setuid.write_text(s.replace(old, new, 1))

# Modern xxKSU userspace transport adapted to the pinned command/API set.
supercall = ksu / 'kernel/supercall/supercall.c'
s = supercall.read_text()
start_anchor = 'static int anon_ksu_release(struct inode *inode, struct file *filp)\n'
if s.count(start_anchor) != 1:
    raise SystemExit(f'xxKSU supercall start anchor count={s.count(start_anchor)}')
s = s.replace(start_anchor, '''#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#define N45_SUSFS_SUPERCALL_MAGIC 0xFAFAFAFAu
#endif

''' + start_anchor, 1)
anchor = '''\t// only root is allowed for these commands
\tif (current_uid().val != 0)
\t\treturn 0;
\t
\t// extensions
'''
bridge = '''\t// only root is allowed for these commands
\tif (current_uid().val != 0)
\t\treturn 0;

#ifdef CONFIG_KSU_SUSFS
\tif ((unsigned int)magic2 == N45_SUSFS_SUPERCALL_MAGIC) {
\t\tswitch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\t\tcase CMD_SUSFS_ADD_SUS_PATH: susfs_add_sus_path((struct st_susfs_sus_path __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tcase CMD_SUSFS_ADD_SUS_MOUNT: susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tcase CMD_SUSFS_ADD_SUS_KSTAT:
\t\tcase CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY: susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg4); return 0;
\t\tcase CMD_SUSFS_UPDATE_SUS_KSTAT: susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
\t\tcase CMD_SUSFS_ADD_TRY_UMOUNT: susfs_add_try_umount((struct st_susfs_try_umount __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\t\tcase CMD_SUSFS_SET_UNAME: susfs_set_uname((struct st_susfs_uname __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
\t\tcase CMD_SUSFS_ENABLE_LOG: { int enabled; if (!copy_from_user(&enabled, arg4, sizeof(enabled))) susfs_set_log(enabled != 0); return 0; }
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\t\tcase CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG: susfs_set_cmdline_or_bootconfig((char __user *)arg4); return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
\t\tcase CMD_SUSFS_ADD_OPEN_REDIRECT: susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg4); return 0;
#endif
\t\tcase CMD_SUSFS_SHOW_VERSION: (void)copy_to_user(arg4, SUSFS_VERSION, sizeof(SUSFS_VERSION)); return 0;
\t\tcase CMD_SUSFS_SHOW_VARIANT: (void)copy_to_user(arg4, SUSFS_VARIANT, sizeof(SUSFS_VARIANT)); return 0;
\t\tdefault: return 0;
\t\t}
\t}
#endif
\t
\t// extensions
'''
if s.count(anchor) != 1:
    raise SystemExit(f'xxKSU supercall bridge anchor count={s.count(anchor)}')
supercall.write_text(s.replace(anchor, bridge, 1))


def remove_diff(marker, required):
    lines = patch.read_text().splitlines(keepends=True)
    try:
        begin = next(i for i,l in enumerate(lines) if l.rstrip('\r\n') == marker)
    except StopIteration:
        raise SystemExit(f'missing patch diff: {marker}')
    end = len(lines)
    for i in range(begin + 1, len(lines)):
        if lines[i].startswith('diff --git '):
            end = i; break
    removed = ''.join(lines[begin:end])
    for token in required:
        if token not in removed:
            raise SystemExit(f'unexpected {marker}: missing {token!r}')
    del lines[begin:end]
    text = ''.join(lines)
    if not text.endswith('\n'): text += '\n'
    patch.write_text(text)
    print(f'[N45] removed SUSFS-2.x-only xxKSU diff: {marker}')

# Keep only Kconfig + ksu.c init from the modern adapter. Everything below is
# 2.x policy/glue replaced above or unnecessary for v1.5.5.
for marker, tokens in [
    ('diff --git a/kernel/downstream/ksu_hostsredirect.h b/kernel/downstream/ksu_hostsredirect.h', ['ksu_kernel_umount_enabled']),
    ('diff --git a/kernel/feature/kernel_umount.c b/kernel/feature/kernel_umount.c', ['ksu_webview_zygote_umount_enabled', 'CONFIG_KSU_SUSFS_TRY_UMOUNT']),
    ('diff --git a/kernel/hook/setuid_hook.c b/kernel/hook/setuid_hook.c', ['susfs_extra_works', 'susfs_set_current_proc_umounted']),
    ('diff --git a/kernel/selinux/rules.c b/kernel/selinux/rules.c', ['CONFIG_KSU_SUSFS']),
    ('diff --git a/kernel/selinux/selinux.c b/kernel/selinux/selinux.c', ['susfs_zygote_sid']),
    ('diff --git a/kernel/selinux/selinux.h b/kernel/selinux/selinux.h', ['susfs_set_zygote_sid']),
    ('diff --git a/kernel/supercall/dispatch.c b/kernel/supercall/dispatch.c', ['CONFIG_KSU_SUSFS']),
    ('diff --git a/kernel/supercall/supercall.c b/kernel/supercall/supercall.c', ['SUSFS_MAGIC', 'CMD_SUSFS_ADD_SUS_PATH_LOOP', 'CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING']),
]:
    remove_diff(marker, tokens)

print('[N45] xxKSU SUSFS v1.5.5 source-specific adaptation complete')
