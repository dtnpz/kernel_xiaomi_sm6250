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

# ARM64 4.14 exposes the PTE frame through pte_pfn() and the public
# instruction-cache flush through flush_icache_range().
replace_once(
    "KernelSU-Next/kernel/hook/arm64/patch_memory.c",
    "    return __pte_to_phys(*pte) + ((addr & ~PAGE_MASK));\n",
    "    return ((phys_addr_t)pte_pfn(*pte) << PAGE_SHIFT) + ((addr & ~PAGE_MASK));\n",
    "4.14 ARM64 PTE physical address helper",
)
replace_once(
    "KernelSU-Next/kernel/hook/arm64/patch_memory.c",
    "#define ksu_flush_icache(start, end) __flush_icache_range(start, end)\n",
    "#define ksu_flush_icache(start, end) flush_icache_range(start, end)\n",
    "4.14 ARM64 instruction-cache flush helper",
)

# v3.4.0 includes linux/pgtable.h for newer kernels, but N45 4.14 has
# the required page-table helpers through the architecture headers instead.
sucompat_path = Path("KernelSU-Next/kernel/feature/sucompat.c")
sucompat_text = sucompat_path.read_text()
if "#include <linux/pgtable.h>\n" not in sucompat_text:
    raise SystemExit("[KSUN340-414] sucompat pgtable include anchor missing")
sucompat_path.write_text(sucompat_text.replace("#include <linux/pgtable.h>\n", "", 1))
print("[KSUN340-414] adapted: drop post-4.14 linux/pgtable.h include")

# 4.14 lacks strncpy_from_user_nofault(). These sucompat reads execute from
# native syscall call-sites in this port, so the regular user-copy primitive
# is the correct 4.14 equivalent.
sucompat_text = sucompat_path.read_text()
if "strncpy_from_user_nofault" not in sucompat_text:
    raise SystemExit("[KSUN340-414] expected v3.4.0 nofault user-string API")
sucompat_path.write_text(sucompat_text.replace("strncpy_from_user_nofault", "strncpy_from_user"))
print("[KSUN340-414] adapted: 4.14 user-string copy API")

# The event bridge uses strncpy_from_user(), which 4.14 declares in uaccess.h.
replace_once(
    "KernelSU-Next/kernel/hook/syscall_event_bridge.c",
    "#include <linux/ptrace.h>\n",
    "#include <linux/ptrace.h>\n#include <linux/uaccess.h>\n",
    "syscall event bridge uaccess declaration",
)

# Keep the v3.4.0 get_wrapper_fd path on Linux 4.14. Its wrapper fops need
# version guards around members introduced after this kernel, and its secure
# anon-file fallback needs the alloc_file_pseudo implementation from 4.14 APIs.
file_wrapper_path = "KernelSU-Next/kernel/infra/file_wrapper.c"
replace_once(
    file_wrapper_path,
    "#include <linux/cred.h>\n",
    "#include <linux/cred.h>\n#include <linux/dcache.h>\n",
    "file wrapper dcache API declaration",
)
replace_once(
    file_wrapper_path,
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll",
    "file wrapper iopoll version guard",
)
replace_once(
    file_wrapper_path,
    "#endif\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\nstatic int ksu_wrapper_iterate",
    "#endif\n#endif\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\nstatic int ksu_wrapper_iterate",
    "file wrapper iopoll 4.14 guard close",
)
replace_once(
    file_wrapper_path,
    "static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)\n"
    "static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)\n"
    "#else\n"
    "static unsigned int ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)\n"
    "#endif\n",
    "file wrapper poll return type",
)
replace_once(
    file_wrapper_path,
    "    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n"
    "    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n"
    "#endif\n",
    "file wrapper iopoll member guard",
)
replace_once(
    file_wrapper_path,
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)\n"
    "    p->ops.fop_flags = fp->f_op->fop_flags;\n"
    "#else\n"
    "    p->ops.mmap_supported_flags = fp->f_op->mmap_supported_flags;\n"
    "#endif\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)\n"
    "    p->ops.fop_flags = fp->f_op->fop_flags;\n"
    "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)\n"
    "    p->ops.mmap_supported_flags = fp->f_op->mmap_supported_flags;\n"
    "#endif\n",
    "file wrapper mmap flags member guard",
)
replace_once(
    file_wrapper_path,
    "    p->ops.remap_file_range =\n"
    "        fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n"
    "    p->ops.fadvise = fp->f_op->fadvise ? ksu_wrapper_fadvise : NULL;\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n"
    "    p->ops.remap_file_range =\n"
    "        fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n"
    "#else\n"
    "    p->ops.clone_file_range =\n"
    "        fp->f_op->clone_file_range ? ksu_wrapper_clone_file_range : NULL;\n"
    "    p->ops.dedupe_file_range =\n"
    "        fp->f_op->dedupe_file_range ? ksu_wrapper_dedupe_file_range : NULL;\n"
    "#endif\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 19, 0)\n"
    "    p->ops.fadvise = fp->f_op->fadvise ? ksu_wrapper_fadvise : NULL;\n"
    "#endif\n",
    "file wrapper clone, remap, and fadvise members",
)
# Linux 4.14 dispatches clone through the source fops and dedupe through the
# destination fops. Unwrap either endpoint before delegating to the real file.
replace_once(
    file_wrapper_path,
    "struct ksu_file_wrapper {\n"
    "    struct file *orig;\n"
    "    struct file_operations ops;\n"
    "};\n",
    "struct ksu_file_wrapper {\n"
    "    struct file *orig;\n"
    "    struct file_operations ops;\n"
    "};\n\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 20, 0)\n"
    "static int ksu_wrapper_release(struct inode *inode, struct file *filp);\n\n"
    "static struct file *ksu_unwrap_file(struct file *fp)\n"
    "{\n"
    "    if (fp->f_op && fp->f_op->release == ksu_wrapper_release)\n"
    "        return ((struct ksu_file_wrapper *)fp->private_data)->orig;\n"
    "    return fp;\n"
    "}\n"
    "#endif\n",
    "file wrapper 4.14 endpoint unwrapping",
)
replace_once(
    file_wrapper_path,
    "// no REMAP_FILE_DEDUP: use file_in\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n"
    "// no REMAP_FILE_DEDUP: use file_in\n",
    "file wrapper remap callback version guard",
)
replace_once(
    file_wrapper_path,
    "static int ksu_wrapper_fadvise(struct file *fp, loff_t off1, loff_t off2,\n",
    "#endif\n\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 19, 0)\n"
    "static int ksu_wrapper_fadvise(struct file *fp, loff_t off1, loff_t off2,\n",
    "file wrapper remap callback guard close",
)
replace_once(
    file_wrapper_path,
    "    return -EINVAL;\n}\n\nstatic void ksu_release_file_wrapper(struct ksu_file_wrapper *data);\n",
    "    return -EINVAL;\n}\n"
    "#endif\n\n"
    "static void ksu_release_file_wrapper(struct ksu_file_wrapper *data);\n",
    "file wrapper fadvise callback guard close",
)
replace_once(
    file_wrapper_path,
    "static ssize_t ksu_wrapper_copy_file_range(struct file *file_in, loff_t pos_in,\n"
    "                                           struct file *file_out,\n"
    "                                           loff_t pos_out, size_t len,\n"
    "                                           unsigned int flags)\n"
    "{\n"
    "    struct ksu_file_wrapper *data = file_out->private_data;\n"
    "    struct file *orig = data->orig;\n"
    "    return orig->f_op->copy_file_range(file_in, pos_in, orig, pos_out, len,\n"
    "                                       flags);\n"
    "}\n\n",
    "static ssize_t ksu_wrapper_copy_file_range(struct file *file_in, loff_t pos_in,\n"
    "                                           struct file *file_out,\n"
    "                                           loff_t pos_out, size_t len,\n"
    "                                           unsigned int flags)\n"
    "{\n"
    "    struct ksu_file_wrapper *data = file_out->private_data;\n"
    "    struct file *orig = data->orig;\n"
    "    return orig->f_op->copy_file_range(file_in, pos_in, orig, pos_out, len,\n"
    "                                       flags);\n"
    "}\n\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 20, 0)\n"
    "static int ksu_wrapper_clone_file_range(struct file *file_in, loff_t pos_in,\n"
    "                                        struct file *file_out, loff_t pos_out,\n"
    "                                        u64 len)\n"
    "{\n"
    "    struct file *orig_in = ksu_unwrap_file(file_in);\n"
    "    struct file *orig_out = ksu_unwrap_file(file_out);\n"
    "    if (!orig_in->f_op->clone_file_range)\n"
    "        return -EOPNOTSUPP;\n"
    "    return orig_in->f_op->clone_file_range(orig_in, pos_in, orig_out,\n"
    "                                            pos_out, len);\n"
    "}\n\n"
    "static ssize_t ksu_wrapper_dedupe_file_range(struct file *file_in, u64 off_in,\n"
    "                                            u64 len, struct file *file_out,\n"
    "                                            u64 off_out)\n"
    "{\n"
    "    struct file *orig_in = ksu_unwrap_file(file_in);\n"
    "    struct file *orig_out = ksu_unwrap_file(file_out);\n"
    "    if (!orig_out->f_op->dedupe_file_range)\n"
    "        return -EOPNOTSUPP;\n"
    "    return orig_out->f_op->dedupe_file_range(orig_in, off_in, len,\n"
    "                                             orig_out, off_out);\n"
    "}\n"
    "#endif\n\n",
    "file wrapper clone and dedupe compatibility callbacks",
)

# The older secure-file path exists below 5.16; backport its allocator with
# 4.14's d_alloc_pseudo() and alloc_file() primitives.
replace_once(
    file_wrapper_path,
    "// Borrow kernel's anon_inode_mnt, so that we don't need to mount one by ourselves.\n",
    "static struct file *ksu_alloc_file_pseudo_compat(\n"
    "    struct inode *inode, struct vfsmount *mnt, const char *name, int flags,\n"
    "    const struct file_operations *fops)\n"
    "{\n"
    "    static const struct dentry_operations anon_ops = { .d_dname = simple_dname };\n"
    "    struct qstr this = QSTR_INIT(name, strlen(name));\n"
    "    struct path path;\n"
    "    struct file *file;\n\n"
    "    path.dentry = d_alloc_pseudo(mnt->mnt_sb, &this);\n"
    "    if (!path.dentry)\n"
    "        return ERR_PTR(-ENOMEM);\n"
    "    if (!mnt->mnt_sb->s_d_op)\n"
    "        d_set_d_op(path.dentry, &anon_ops);\n"
    "    path.mnt = mntget(mnt);\n"
    "    d_instantiate(path.dentry, inode);\n"
    "    file = alloc_file(&path, flags, fops);\n"
    "    if (IS_ERR(file)) {\n"
    "        ihold(inode);\n"
    "        path_put(&path);\n"
    "    }\n"
    "    return file;\n"
    "}\n\n"
    "// Borrow kernel's anon_inode_mnt, so that we don't need to mount one by ourselves.\n",
    "file wrapper alloc_file_pseudo backport",
)
replace_once(
    file_wrapper_path,
    "    const struct qstr qname = QSTR_INIT(name, strlen(name));\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)\n"
    "    const struct qstr qname = QSTR_INIT(name, strlen(name));\n"
    "#endif\n",
    "file wrapper anon security qstr version guard",
)
replace_once(
    file_wrapper_path,
    "    error = security_inode_init_security_anon(inode, &qname, context_inode);\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)\n"
    "    error = security_inode_init_security_anon(inode, &qname, context_inode);\n"
    "#else\n"
    "    error = context_inode ? -EOPNOTSUPP : 0;\n"
    "#endif\n",
    "file wrapper 4.14 anon inode security initialization",
)
replace_once(
    file_wrapper_path,
    "    file = alloc_file_pseudo(inode, anon_inode_mnt, name,\n",
    "    file = ksu_alloc_file_pseudo_compat(inode, anon_inode_mnt, name,\n",
    "file wrapper 4.14 pseudo-file allocator",
)
replace_once(
    file_wrapper_path,
    "    struct inode_security_struct *wrapper_sec = selinux_inode(wrapper_inode);\n",
    "    struct inode_security_struct *wrapper_sec =\n"
    "        (struct inode_security_struct *)wrapper_inode->i_security;\n",
    "file wrapper 4.14 SELinux inode accessor",
)

# 4.14 uses unsigned int poll masks and gets EPOLL readiness bits from
# eventpoll.h. Keep the v3.4.0 event queue API typed across both versions.
event_queue_h = "KernelSU-Next/kernel/infra/event_queue.h"
replace_once(
    event_queue_h,
    "#include <linux/types.h>\n",
    "#include <linux/types.h>\n#include <linux/version.h>\n",
    "event queue kernel version declaration",
)
replace_once(
    event_queue_h,
    "#define KSU_EVENT_RECORD_FLAG_INTERNAL (1U << 0)\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)\n"
    "typedef __poll_t ksu_event_poll_t;\n"
    "#else\n"
    "typedef unsigned int ksu_event_poll_t;\n"
    "#endif\n\n"
    "#define KSU_EVENT_RECORD_FLAG_INTERNAL (1U << 0)\n",
    "event queue 4.14 poll mask type",
)
replace_once(
    event_queue_h,
    "__poll_t ksu_event_queue_poll(struct ksu_event_queue *queue, struct file *file, poll_table *wait);\n",
    "ksu_event_poll_t ksu_event_queue_poll(struct ksu_event_queue *queue, struct file *file, poll_table *wait);\n",
    "event queue poll prototype type",
)
event_queue_c = "KernelSU-Next/kernel/infra/event_queue.c"
replace_once(
    event_queue_c,
    "#include <linux/poll.h>\n",
    "#include <linux/poll.h>\n#include <linux/eventpoll.h>\n",
    "event queue eventpoll readiness declarations",
)
replace_once(
    event_queue_c,
    "__poll_t ksu_event_queue_poll(struct ksu_event_queue *queue, struct file *file, poll_table *wait)\n",
    "ksu_event_poll_t ksu_event_queue_poll(struct ksu_event_queue *queue, struct file *file, poll_table *wait)\n",
    "event queue poll implementation type",
)
replace_once(
    event_queue_c,
    "    __poll_t mask = 0;\n",
    "    ksu_event_poll_t mask = 0;\n",
    "event queue poll mask local type",
)
replace_once(
    "KernelSU-Next/kernel/sulog/fd.c",
    "static __poll_t ksu_sulog_poll(struct file *file, poll_table *wait)\n",
    "static ksu_event_poll_t ksu_sulog_poll(struct file *file, poll_table *wait)\n",
    "sulog fd poll return type",
)

# 4.14 arm64 exposes the native syscall count as NR_syscalls.
replace_once(
    "KernelSU-Next/kernel/infra/seccomp_cache.c",
    "#include <linux/seccomp.h>\n",
    "#include <linux/seccomp.h>\n"
    "#include <asm/unistd.h>\n\n"
    "#ifndef SECCOMP_ARCH_NATIVE_NR\n"
    "#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n"
    "#endif\n",
    "seccomp cache native syscall bound",
)

# ksys_close() was introduced after this vendor kernel. Linux 4.14 exposes
# sys_close() and KernelSU already includes linux/syscalls.h through util.h.
util_path = Path("KernelSU-Next/kernel/include/util.h")
util_text = util_path.read_text()
if "#define ksu_close_fd ksys_close" not in util_text:
    raise SystemExit("[KSUN340-414] ksu_close_fd compatibility anchor missing")
util_path.write_text(util_text.replace("#define ksu_close_fd ksys_close", "#define ksu_close_fd sys_close", 1))
print("[KSUN340-414] adapted: 4.14 close syscall helper")

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


# Linux 4.14 stores security_hook_heads as list_head lists, while newer
# KernelSU-Next expects hlist_head on its pre-static-call path.  Keep the
# v3.4.0 hook contract but implement the runtime slot replacement against the
# actual 4.14 list layout.  v3.4.0 currently uses this for selinux_setprocattr.
lsm_path = Path("KernelSU-Next/kernel/hook/lsm_hook.c")
lsm_text = lsm_path.read_text()
if "struct hlist_head *head;" not in lsm_text or "hlist_for_each_entry" not in lsm_text:
    raise SystemExit("[KSUN340-414] unexpected v3.4.0 LSM hook implementation")
lsm_path.write_text(r'''#include <linux/compiler.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/lsm_hooks.h>
#include <linux/mutex.h>
#include <linux/rcupdate.h>
#include <linux/string.h>

#include "infra/symbol_resolver.h"
#include "hook/lsm_hook.h"
#include "hook/patch_memory.h"
#include "klog.h"

struct ksu_lsm_hook_entry {
    struct ksu_lsm_hook *hook;
};

static DEFINE_MUTEX(ksu_lsm_hook_lock);
static struct ksu_lsm_hook_entry ksu_lsm_hook_entries[16];
static int ksu_lsm_hook_count;

static bool ksu_lsm_hook_is_tracked(struct ksu_lsm_hook *hook)
{
    int i;
    for (i = 0; i < ksu_lsm_hook_count; i++)
        if (ksu_lsm_hook_entries[i].hook == hook)
            return true;
    return false;
}

static int ksu_lsm_hook_track(struct ksu_lsm_hook *hook)
{
    if (ksu_lsm_hook_is_tracked(hook))
        return 0;
    if (ksu_lsm_hook_count >= ARRAY_SIZE(ksu_lsm_hook_entries))
        return -ENOSPC;
    ksu_lsm_hook_entries[ksu_lsm_hook_count++].hook = hook;
    return 0;
}

static void ksu_lsm_hook_untrack(struct ksu_lsm_hook *hook)
{
    int i;
    for (i = 0; i < ksu_lsm_hook_count; i++) {
        if (ksu_lsm_hook_entries[i].hook != hook)
            continue;
        ksu_lsm_hook_entries[i] = ksu_lsm_hook_entries[--ksu_lsm_hook_count];
        return;
    }
}

static int ksu_lsm_hook_patch_slot(void **slot, void *value)
{
    void *patched = value;
    int ret = ksu_patch_text(slot, &patched, sizeof(patched), KSU_PATCH_TEXT_FLUSH_DCACHE);
    if (!ret)
        smp_wmb();
    return ret;
}

int ksu_lsm_hook(struct ksu_lsm_hook *hook)
{
    unsigned long heads_addr;
    struct list_head *head, *head_begin, *head_end;
    struct security_hook_list *entry;
    struct security_hook_list *selected_entry = NULL;
    void **selected_slot = NULL;
    void *selected_origin = NULL;
    void *target;
    int ret = 0;
    int i;

    if (!hook || !hook->replacement || !hook->target_name)
        return -EINVAL;

    mutex_lock(&ksu_lsm_hook_lock);
    if (hook->entry) {
        ret = -EALREADY;
        goto out;
    }

    target = hook->original;
    if (!target)
        target = ksu_resolve_symbol_for_functable_hook(hook->target_name);
    if (!target) {
        ret = -ENOENT;
        goto out;
    }

    heads_addr = find_kernel_symbol_exact("security_hook_heads");
    if (!heads_addr) {
        ret = -ENOENT;
        goto out;
    }

    head_begin = (struct list_head *)heads_addr;
    head_end = (struct list_head *)(heads_addr + sizeof(struct security_hook_heads));
    head = (struct list_head *)(heads_addr + hook->head_offset);
    if (head < head_begin || head >= head_end) {
        ret = -EINVAL;
        goto out;
    }

    list_for_each_entry(entry, head, list) {
        void **slot = (void **)((char *)entry + hook->hook_offset);
        void *current_origin = READ_ONCE(*slot);

        for (i = 0; i < ksu_lsm_hook_count; i++) {
            if (ksu_lsm_hook_entries[i].hook->replacement == current_origin) {
                current_origin = ksu_lsm_hook_entries[i].hook->original;
                break;
            }
        }

        if (current_origin == hook->replacement) {
            ret = -EALREADY;
            goto out;
        }
        if (current_origin == target) {
            selected_entry = entry;
            selected_slot = slot;
            selected_origin = current_origin;
            break;
        }
    }

    if (!selected_entry) {
        pr_err("lsm_hook: target %s not found in %s\n",
               hook->target_name, hook->head_name ?: "unknown");
        ret = -ENOENT;
        goto out;
    }

    if (hook->offset) {
        head += hook->offset;
        if (head < head_begin || head >= head_end || list_empty(head)) {
            ret = -EINVAL;
            goto out;
        }
        selected_entry = list_first_entry(head, struct security_hook_list, list);
        selected_slot = (void **)((char *)selected_entry + hook->hook_offset);
        selected_origin = READ_ONCE(*selected_slot);
    }

    ret = ksu_lsm_hook_track(hook);
    if (ret)
        goto out;

    ret = ksu_lsm_hook_patch_slot(selected_slot, hook->replacement);
    if (ret) {
        ksu_lsm_hook_untrack(hook);
        ret = -EFAULT;
        goto out;
    }

    hook->entry = selected_entry;
    hook->original = selected_origin;
    pr_info("lsm_hook: GXT414 patched %s slot %px from %px to %px\n",
            hook->head_name ?: "unknown", selected_slot,
            selected_origin, hook->replacement);
out:
    mutex_unlock(&ksu_lsm_hook_lock);
    return ret;
}

void ksu_lsm_unhook(struct ksu_lsm_hook *hook)
{
    void **slot;

    if (!hook)
        return;

    mutex_lock(&ksu_lsm_hook_lock);
    if (!hook->entry) {
        mutex_unlock(&ksu_lsm_hook_lock);
        return;
    }

    slot = (void **)((char *)hook->entry + hook->hook_offset);
    if (ksu_lsm_hook_patch_slot(slot, hook->original)) {
        pr_err("lsm_hook: failed to restore %s\n", hook->head_name ?: "unknown");
        mutex_unlock(&ksu_lsm_hook_lock);
        return;
    }

    synchronize_rcu();
    ksu_lsm_hook_untrack(hook);
    hook->entry = NULL;
    mutex_unlock(&ksu_lsm_hook_lock);
}

int ksu_register_lsm_hook(struct ksu_lsm_hook *hook)
{
    return ksu_lsm_hook(hook);
}

void ksu_unregister_lsm_hook(struct ksu_lsm_hook *hook)
{
    ksu_lsm_unhook(hook);
}

void __init ksu_lsm_hook_init(void)
{
    pr_info("lsm_hook: GXT Linux 4.14 list bridge ready\n");
}

void __exit ksu_lsm_hook_exit(void)
{
    struct ksu_lsm_hook *hooks[ARRAY_SIZE(ksu_lsm_hook_entries)];
    int count, i;

    mutex_lock(&ksu_lsm_hook_lock);
    count = ksu_lsm_hook_count;
    for (i = 0; i < count; i++)
        hooks[i] = ksu_lsm_hook_entries[i].hook;
    mutex_unlock(&ksu_lsm_hook_lock);

    for (i = count - 1; i >= 0; i--)
        ksu_lsm_unhook(hooks[i]);
}
''')
print("[KSUN340-414] adapted: Linux 4.14 list_head LSM hook bridge")

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
    if (strncpy_from_user(path, filename_user, sizeof(path)) <= 0)
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
