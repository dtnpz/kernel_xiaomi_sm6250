#!/usr/bin/env python3
"""Backport the exact KernelSU-Next v3.4.0 kernel core to N45 Linux 4.14.

The v3.4.0 policy/features/UAPI stay intact.  Only APIs absent from 4.14 and
arm64 syscall interception are adapted.  In particular, this file must never
copy the legacy/UAPI2 selinux_hide implementation back into the build.
"""
from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"[KSUN340-414] {label}: expected one anchor, got {count}")
    p.write_text(s.replace(old, new, 1))
    print(f"[KSUN340-414] adapted: {label}")


def require(path: str, needle: str, label: str) -> None:
    if needle not in Path(path).read_text():
        raise SystemExit(f"[KSUN340-414] missing {label}: {path}")


# Linux 4.14 predates copy_to_kernel_nofault().
replace_once(
    "KernelSU-Next/kernel/hook/arm64/patch_memory.c",
    "    ret = (int)copy_to_kernel_nofault(map, src, len);",
    "    ret = (int)probe_kernel_write(map, src, len);",
    "patch_memory nofault kernel write",
)

# Linux 4.14 task_work_add() takes a boolean notify argument.
for task_work_path in (
    "KernelSU-Next/kernel/policy/allowlist.c",
    "KernelSU-Next/kernel/supercall/supercall.c",
):
    p = Path(task_work_path)
    text = p.read_text()
    if "TWA_RESUME" not in text:
        raise SystemExit(f"[KSUN340-414] task_work anchor missing: {task_work_path}")
    p.write_text(text.replace("TWA_RESUME", "true"))
    print(f"[KSUN340-414] adapted: 4.14 task_work notify API ({task_work_path})")


# v3.4.0 arm64 assumes the newer pt_regs syscall-table ABI.  4.14 arm64 has
# the classic C-argument sys_call_table, so that dispatcher cannot be used
# safely. Keep the v3.4.0 hook API linkable, but make the table bridge inert;
# native 4.14 source callbacks below perform the actual interception.
hook_h = Path("KernelSU-Next/kernel/hook/syscall_hook.h")
s = hook_h.read_text()
anchor = "#include <asm/syscall.h>\n"
if anchor not in s:
    raise SystemExit("[KSUN340-414] syscall_hook.h include anchor missing")
s = s.replace(
    anchor,
    anchor
    + "#include <linux/version.h>\n"
      "struct pt_regs;\n"
      "#if defined(__aarch64__) && LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n"
      "typedef long (*syscall_fn_t)(const struct pt_regs *regs);\n"
      "#endif\n",
    1,
)
hook_h.write_text(s)
print("[KSUN340-414] adapted: 4.14 arm64 syscall_fn_t compatibility type")

arm64_hook = Path("KernelSU-Next/kernel/hook/arm64/syscall_hook.c")
old_arm64 = arm64_hook.read_text()
if "ksu_syscall_dispatcher" not in old_arm64 or "ksu_syscall_table_hook" not in old_arm64:
    raise SystemExit("[KSUN340-414] unexpected v3.4.0 arm64 syscall hook source")
arm64_hook.write_text(r'''#ifdef __aarch64__

#include "../syscall_hook.h"
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/printk.h>

syscall_fn_t *ksu_syscall_table = NULL;
int ksu_dispatcher_nr = -1;

void ksu_syscall_table_hook(int nr, syscall_fn_t fn, syscall_fn_t *old)
{
    if (old)
        *old = NULL;
    pr_warn_once("KernelSU: syscall-table hook disabled on GXT Linux 4.14; using native call-site bridge\n");
}

void ksu_syscall_table_unhook(int nr)
{
}

int ksu_register_syscall_hook(int nr, ksu_syscall_hook_fn fn)
{
    return -EOPNOTSUPP;
}

void ksu_unregister_syscall_hook(int nr)
{
}

bool ksu_has_syscall_hook(int nr)
{
    return false;
}

void __init ksu_syscall_hook_init(void)
{
    pr_info("KernelSU: GXT Linux 4.14 native syscall bridge active\n");
}

void __exit ksu_syscall_hook_exit(void)
{
}

#endif /* __aarch64__ */
''')
print("[KSUN340-414] adapted: disabled incompatible pt_regs syscall-table dispatcher")

manager = Path("KernelSU-Next/kernel/hook/syscall_hook_manager.c")
manager_text = manager.read_text()
if "ksu_register_syscall_hook(__NR_setresuid" not in manager_text:
    raise SystemExit("[KSUN340-414] unexpected v3.4.0 syscall hook manager")
manager.write_text(r'''#include <linux/init.h>
#include <linux/printk.h>

#include "hook/syscall_hook_manager.h"
#include "hook/syscall_hook.h"
#include "hook/setuid_hook.h"
#include "feature/sucompat.h"

void __init ksu_syscall_hook_manager_init(void)
{
    pr_info("hook_manager: GXT Linux 4.14 native call-site bridge\n");
    ksu_setuid_hook_init();
    ksu_sucompat_init();
    ksu_avc_spoof_init();
}

void __exit ksu_syscall_hook_manager_exit(void)
{
    ksu_sucompat_exit();
    ksu_setuid_hook_exit();
    ksu_avc_spoof_exit();
    ksu_syscall_hook_exit();
}
''')
print("[KSUN340-414] adapted: v3.4.0 hook manager uses 4.14 source callbacks")


# Manual su-compat callbacks keep v3.4.0 feature state/root-profile logic while
# matching the callbacks already present in this 4.14 vendor tree.
sucompat = Path("KernelSU-Next/kernel/feature/sucompat.c")
su = sucompat.read_text()
su_anchor = "// sucompat: permitted process can execute 'su' to gain root access.\n"
if su_anchor not in su:
    raise SystemExit("[KSUN340-414] sucompat insertion anchor missing")
manual_su = r'''
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
static char __user *gxt_414_sh_user_path(void)
{
    static const char sh_path[] = SH_PATH;
    return userspace_stack_buffer(sh_path, sizeof(sh_path));
}

static bool gxt_414_is_su_path(const char __user *filename_user)
{
    char path[sizeof(su_path) + 1];

    if (!filename_user)
        return false;
    memset(path, 0, sizeof(path));
    if (strncpy_from_user_nofault(path, filename_user, sizeof(path)) <= 0)
        return false;
    return !memcmp(path, su_path, sizeof(su_path));
}

int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags)
{
    if (!ksu_su_compat_enabled || !filename_user ||
        !ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    if (gxt_414_is_su_path(*filename_user)) {
        ksu_compat_sulog('a');
        *filename_user = gxt_414_sh_user_path();
        pr_info("GXT414 faccessat su->sh compatibility\n");
    }
    return 0;
}

int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
    if (!ksu_su_compat_enabled || !filename_user ||
        !ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    if (gxt_414_is_su_path(*filename_user)) {
        ksu_compat_sulog('s');
        *filename_user = gxt_414_sh_user_path();
        pr_info("GXT414 stat su->sh compatibility\n");
    }
    return 0;
}

int ksu_handle_execveat_sucompat_manual(struct filename **filename_ptr)
{
    struct filename *filename;
    int ret;

    if (!ksu_su_compat_enabled || !filename_ptr ||
        !ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    filename = *filename_ptr;
    if (IS_ERR_OR_NULL(filename) ||
        memcmp(filename->name, su_path, sizeof(su_path)))
        return 0;

    if (sizeof(KSUD_PATH) > sizeof(su_path)) {
        pr_err("GXT414: ksud path does not fit su filename buffer\n");
        return 0;
    }

    ksu_compat_sulog('x');
    memcpy((void *)filename->name, KSUD_PATH, sizeof(KSUD_PATH));
    ret = escape_with_root_profile();
    if (ret)
        pr_err("GXT414 escape_with_root_profile failed: %d\n", ret);
    else
        pr_info("GXT414 execve su->ksud compatibility\n");
    return 0;
}
#endif

'''
sucompat.write_text(su.replace(su_anchor, manual_su + su_anchor, 1))
print("[KSUN340-414] adapted: v3.4.0 sucompat callbacks for native 4.14 syscall ABI")


# ksud bootstrap/read/input callbacks are routed through existing vendor
# call-sites rather than the incompatible syscall-table dispatcher.
runtime = Path("KernelSU-Next/kernel/runtime/ksud_integration.c")
rt = runtime.read_text()
rt = rt.replace(
    "static struct work_struct stop_input_hook_work;\n",
    "static struct work_struct stop_input_hook_work;\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n"
    "static bool gxt_414_init_rc_hook = true;\n"
    "static bool gxt_414_input_hook = true;\n"
    "#endif\n",
    1,
)

old_input = """int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value)
{
    if (*type == EV_KEY && *code == KEY_VOLUMEDOWN) {"""
new_input = """int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
    if (!gxt_414_input_hook)
        return 0;
#endif
    if (*type == EV_KEY && *code == KEY_VOLUMEDOWN) {"""
if old_input not in rt:
    raise SystemExit("[KSUN340-414] input handler anchor missing")
rt = rt.replace(old_input, new_input, 1)

old_stop_init = r"""static void stop_init_rc_hook()
{
    ksu_syscall_table_unhook(__NR_read);
    ksu_syscall_table_unhook(__NR_fstat);
    pr_info("unregister init_rc syscall hook\n");
}"""
new_stop_init = r"""static void stop_init_rc_hook()
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
    gxt_414_init_rc_hook = false;
    pr_info("GXT414 stop init_rc source hook\n");
#else
    ksu_syscall_table_unhook(__NR_read);
    ksu_syscall_table_unhook(__NR_fstat);
    pr_info("unregister init_rc syscall hook\n");
#endif
}"""
if old_stop_init not in rt:
    raise SystemExit("[KSUN340-414] stop_init_rc_hook anchor missing")
rt = rt.replace(old_stop_init, new_stop_init, 1)

old_stop_input = r"""void ksu_stop_input_hook_runtime(void)
{
    static bool input_hook_stopped = false;
    if (input_hook_stopped) {
        return;
    }
    input_hook_stopped = true;
    bool ret = schedule_work(&stop_input_hook_work);
    pr_info("unregister input kprobe: %d!\n", ret);
}"""
new_stop_input = r"""void ksu_stop_input_hook_runtime(void)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
    gxt_414_input_hook = false;
    pr_info("GXT414 stop input source hook\n");
#else
    static bool input_hook_stopped = false;
    if (input_hook_stopped) {
        return;
    }
    input_hook_stopped = true;
    bool ret = schedule_work(&stop_input_hook_work);
    pr_info("unregister input kprobe: %d!\n", ret);
#endif
}"""
if old_stop_input not in rt:
    raise SystemExit("[KSUN340-414] stop_input_hook anchor missing")
rt = rt.replace(old_stop_input, new_stop_input, 1)

module_anchor = "// ksud: module support\n"
if module_anchor not in rt:
    raise SystemExit("[KSUN340-414] ksud module anchor missing")
manual_runtime = r'''
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
extern int ksu_handle_execveat_sucompat_manual(struct filename **filename_ptr);

int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                        size_t *count_ptr, loff_t **pos)
{
    if (!gxt_414_init_rc_hook || !file_ptr || IS_ERR_OR_NULL(*file_ptr))
        return 0;
    ksu_install_rc_hook(*file_ptr);
    return 0;
}

void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr)
{
    struct file *file;
    void __user *st_size_ptr;
    long size, new_size;
    size_t extra;

    if (!gxt_414_init_rc_hook || !fd || !statbuf_ptr || !*statbuf_ptr)
        return;

    file = fget(*fd);
    if (!file)
        return;
    if (!is_init_rc(file)) {
        fput(file);
        return;
    }
    fput(file);

    load_module_rc_once();
    extra = ksu_rc_len + module_rc_len;
    st_size_ptr = (void __user *)*statbuf_ptr + offsetof(struct stat, st_size);
    if (copy_from_user(&size, st_size_ptr, sizeof(size)))
        return;
    new_size = size + extra;
    if (copy_to_user(st_size_ptr, &new_size, sizeof(new_size)))
        pr_err("GXT414 fstat init.rc size patch failed\n");
}

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
                        void *envp, int *flags)
{
    struct filename *filename;

    if (!filename_ptr)
        return 0;
    filename = *filename_ptr;
    if (IS_ERR_OR_NULL(filename))
        return 0;

    ksu_handle_execveat_ksud(filename->name, (struct user_arg_ptr *)argv);
    return ksu_handle_execveat_sucompat_manual(filename_ptr);
}
#endif

'''
rt = rt.replace(module_anchor, manual_runtime + module_anchor, 1)

old_init = r"""void __init ksu_ksud_init()
{
    int ret;

    ksu_syscall_table_hook(__NR_read, ksu_sys_read, &orig_sys_read);
    ksu_syscall_table_hook(__NR_fstat, ksu_sys_fstat, &orig_sys_fstat);

    ret = register_kprobe(&input_event_kp);
    pr_info("ksud: input_event_kp: %d\n", ret);

    INIT_WORK(&stop_input_hook_work, do_stop_input_hook);
}"""
new_init = r"""void __init ksu_ksud_init()
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
    gxt_414_init_rc_hook = true;
    gxt_414_input_hook = true;
    pr_info("ksud: GXT Linux 4.14 source hooks ready\n");
#else
    int ret;

    ksu_syscall_table_hook(__NR_read, ksu_sys_read, &orig_sys_read);
    ksu_syscall_table_hook(__NR_fstat, ksu_sys_fstat, &orig_sys_fstat);

    ret = register_kprobe(&input_event_kp);
    pr_info("ksud: input_event_kp: %d\n", ret);

    INIT_WORK(&stop_input_hook_work, do_stop_input_hook);
#endif
}"""
if old_init not in rt:
    raise SystemExit("[KSUN340-414] ksu_ksud_init anchor missing")
rt = rt.replace(old_init, new_init, 1)

old_exit = """void __exit ksu_ksud_exit()
{
    // TODO:
    // this should be done before unregister vfs_read_kp
    // stop_init_rc_hook();
    unregister_kprobe(&input_event_kp);

    if (module_rc_buf) {
        free_module_rc();
    }
}"""
new_exit = """void __exit ksu_ksud_exit()
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 17, 0)
    unregister_kprobe(&input_event_kp);
#endif

    if (module_rc_buf) {
        free_module_rc();
    }
}"""
if old_exit not in rt:
    raise SystemExit("[KSUN340-414] ksu_ksud_exit anchor missing")
rt = rt.replace(old_exit, new_exit, 1)
runtime.write_text(rt)
print("[KSUN340-414] adapted: ksud bootstrap/read/input source callbacks")


# Add the two 4.14 call-sites that were not present in the old vendor callback
# set: successful setresuid (for manager/allowlist task marking) and fstat
# return (for init.rc size extension).
sys_c = Path("kernel/sys.c")
ksys = sys_c.read_text()
setres_decl_anchor = """/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)"""
setres_decl_new = """#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid);
#endif

/*
 * This function implements a generic ability to update ruid, euid,
 * and suid.  This allows you to implement the 4.4 compatible seteuid().
 */
SYSCALL_DEFINE3(setresuid, uid_t, ruid, uid_t, euid, uid_t, suid)"""
if setres_decl_anchor not in ksys:
    raise SystemExit("[KSUN340-414] setresuid declaration anchor missing")
ksys = ksys.replace(setres_decl_anchor, setres_decl_new, 1)
setres_return = """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

	return commit_creds(new);

error:
	abort_creds(new);
	return retval;
}"""
setres_return_new = """	retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
	if (retval < 0)
		goto error;

#ifdef CONFIG_KSU
	{
		uid_t ksu_old_uid = from_kuid_munged(ns, old->uid);
		retval = commit_creds(new);
		if (!retval)
			ksu_handle_setresuid(ksu_old_uid, current_uid().val);
		return retval;
	}
#else
	return commit_creds(new);
#endif

error:
	abort_creds(new);
	return retval;
}"""
if setres_return not in ksys:
    raise SystemExit("[KSUN340-414] setresuid return anchor missing")
sys_c.write_text(ksys.replace(setres_return, setres_return_new, 1))
print("[KSUN340-414] adapted: setresuid source callback")

stat_c = Path("fs/stat.c")
kst = stat_c.read_text()
newfstat_anchor = """SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;
}"""
newfstat_new = """#ifdef CONFIG_KSU
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#endif

SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);
#ifdef CONFIG_KSU
	if (!error)
		ksu_handle_newfstat_ret(&fd, &statbuf);
#endif

	return error;
}"""
if newfstat_anchor not in kst:
    raise SystemExit("[KSUN340-414] newfstat anchor missing")
stat_c.write_text(kst.replace(newfstat_anchor, newfstat_new, 1))
print("[KSUN340-414] adapted: newfstat return source callback")

# Verify all pre-existing vendor bridge points are still present.
for path, symbol in {
    "fs/open.c": "ksu_handle_faccessat",
    "fs/read_write.c": "ksu_handle_vfs_read",
    "fs/stat.c": "ksu_handle_stat",
    "fs/exec.c": "ksu_handle_execveat",
    "drivers/input/input.c": "ksu_handle_input_handle_event",
}.items():
    require(path, symbol, f"vendor callback {symbol}")

# Guardrails: stay on the real v3.4.0/UAPI4 SELinux hide engine.
uapi = Path("KernelSU-Next/uapi/supercall.h").read_text()
hide = Path("KernelSU-Next/kernel/feature/selinux_hide.c").read_text()
if "static const __u32 KERNEL_SU_UAPI_VERSION = 4;" not in uapi:
    raise SystemExit("[KSUN340-414] expected v3.4.0 UAPI4 core")
if "static bool ksu_selinux_hide_enabled __read_mostly = false;" not in hide:
    raise SystemExit("[KSUN340-414] selinux_hide must start disabled")
if "blocked transaction_write from uid=" in hide:
    raise SystemExit("[KSUN340-414] legacy transaction_write blocker detected")
if "backup_sepolicy" not in hide or "my_write_context" not in hide:
    raise SystemExit("[KSUN340-414] expected v3.4.0 backup-policy selinux_hide engine")

print("[KSUN340-414] v3.4.0 Linux 4.14 native bridge ready")
