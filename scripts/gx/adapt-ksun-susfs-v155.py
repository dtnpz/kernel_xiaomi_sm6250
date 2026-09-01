#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: adapt-ksun-susfs-v155.py <KernelSU-Next-dir> <temporary-patch>')
ksu = Path(sys.argv[1])
patch = Path(sys.argv[2])

# Install only the v1.5.5-compatible parts that KSUN actually needs.  The
# fetched Aug-20 adapter targets SUSFS 2.2.0; its setuid/SELinux/dispatch code
# calls APIs that are absent from our pinned 4.14 SUSFS source.
setuid = ksu / 'kernel/hook/setuid_hook.c'
s = setuid.read_text()
include_anchor = '#include "compat/kernel_compat.h"\n'
include_repl = include_anchor + '''#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#include <linux/susfs_def.h>
#endif
'''
if s.count(include_anchor) != 1:
    raise SystemExit(f'KSUN setuid include anchor count={s.count(include_anchor)}')
s = s.replace(include_anchor, include_repl, 1)

else_anchor = '''\t} else {
#ifdef KSU_KPROBES_HOOK
\t\tksu_clear_task_tracepoint_flag_if_needed(current);
#endif
    }

    // Handle kernel umount
    ksu_handle_umount(old_uid, new_uid);
'''
else_repl = '''\t} else {
#ifdef KSU_KPROBES_HOOK
\t\tksu_clear_task_tracepoint_flag_if_needed(current);
#endif
#ifdef CONFIG_KSU_SUSFS
\t\ttask_lock(current);
\t\tcurrent->susfs_task_state |= TASK_STRUCT_NON_ROOT_USER_APP_PROC;
\t\ttask_unlock(current);
#endif
    }

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
    susfs_try_umount(new_uid);
#endif
    // Preserve KSUN's own unmount layer after SUSFS-specific targets.
    ksu_handle_umount(old_uid, new_uid);
'''
if s.count(else_anchor) != 1:
    raise SystemExit(f'KSUN setuid behavior anchor count={s.count(else_anchor)}')
setuid.write_text(s.replace(else_anchor, else_repl, 1))

supercall = ksu / 'kernel/supercall/supercall.c'
s = supercall.read_text()
inc_anchor = '#include <linux/utsname.h> // utsname() and uts_sem\n'
inc = inc_anchor + '''#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#define N45_SUSFS_SUPERCALL_MAGIC 0xFAFAFAFAu
#endif
'''
if s.count(inc_anchor) != 1:
    raise SystemExit(f'KSUN supercall include anchor count={s.count(inc_anchor)}')
s = s.replace(inc_anchor, inc, 1)
anchor = '''#ifdef CONFIG_KSU_DEBUG
\tpr_info("sys_reboot: intercepted call! magic: 0x%x id: %d\\n", magic1,
\t\tmagic2);
#endif

\t// Check if this is a request to install KSU fd
'''
bridge = '''#ifdef CONFIG_KSU_DEBUG
\tpr_info("sys_reboot: intercepted call! magic: 0x%x id: %d\\n", magic1,
\t\tmagic2);
#endif

#ifdef CONFIG_KSU_SUSFS
\tif ((unsigned int)magic2 == N45_SUSFS_SUPERCALL_MAGIC && current_uid().val == 0) {
\t\tvoid __user *arg4 = (void __user *)*arg;
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

\t// Check if this is a request to install KSU fd
'''
if s.count(anchor) != 1:
    raise SystemExit(f'KSUN supercall bridge anchor count={s.count(anchor)}')
supercall.write_text(s.replace(anchor, bridge, 1))


def remove_diff(marker, required):
    lines = patch.read_text().splitlines(keepends=True)
    try:
        start = next(i for i,l in enumerate(lines) if l.rstrip('\r\n') == marker)
    except StopIteration:
        raise SystemExit(f'missing patch diff {marker}')
    end = len(lines)
    for i in range(start+1, len(lines)):
        if lines[i].startswith('diff --git '):
            end = i
            break
    removed = ''.join(lines[start:end])
    for token in required:
        if token not in removed:
            raise SystemExit(f'unexpected {marker}: missing {token}')
    del lines[start:end]
    text = ''.join(lines)
    if not text.endswith('\n'): text += '\n'
    patch.write_text(text)
    print(f'[N45] removed SUSFS-2.2-only KSUN diff: {marker}')

# Preserve KSUN's existing umount/SELinux/task-mark implementation; v1.5.5
# integration is handled by the guarded setuid transform above and SUSFS core.
for marker, tokens in [
    ('diff --git a/kernel/feature/kernel_umount.c b/kernel/feature/kernel_umount.c', ['ksu_kernel_umount_enabled', 'CONFIG_KSU_SUSFS_TRY_UMOUNT']),
    ('diff --git a/kernel/feature/kernel_umount.h b/kernel/feature/kernel_umount.h', ['ksu_handle_umount']),
    ('diff --git a/kernel/hook/setuid_hook.c b/kernel/hook/setuid_hook.c', ['susfs_extra_works', 'susfs_set_current_proc_umounted']),
    ('diff --git a/kernel/selinux/rules.c b/kernel/selinux/rules.c', ['susfs_set_zygote_sid']),
    ('diff --git a/kernel/selinux/selinux.c b/kernel/selinux/selinux.c', ['susfs_zygote_sid', 'susfs_is_sid_equal']),
    ('diff --git a/kernel/selinux/selinux.h b/kernel/selinux/selinux.h', ['susfs_is_sid_equal']),
    ('diff --git a/kernel/supercall/dispatch.c b/kernel/supercall/dispatch.c', ['susfs_start_sdcard_monitor_fn', 'susfs_is_current_proc_umounted']),
    ('diff --git a/kernel/supercall/supercall.c b/kernel/supercall/supercall.c', ['SUSFS_MAGIC', 'CMD_SUSFS_ADD_SUS_PATH_LOOP', 'CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING']),
]:
    remove_diff(marker, tokens)

print('[N45] KSUN SUSFS v1.5.5 source-specific adaptation complete')
