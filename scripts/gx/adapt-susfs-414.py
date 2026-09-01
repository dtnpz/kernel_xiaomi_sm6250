#!/usr/bin/env python3
"""Adapt the pinned SUSFS 4.14 patch to the Miatoll/OpenELA 4.14.356 tree.

Only hunks proven to fail in CI are adapted here.  Each source transform uses
an exact anchor and each matching obsolete hunk is removed from a temporary
copy of the upstream SUSFS patch.  The caller still dry-runs every remaining
hunk before applying anything else.
"""

from pathlib import Path
import re
import sys


if len(sys.argv) != 2:
    raise SystemExit("usage: adapt-susfs-414.py <temporary-kernel-patch>")

patch_path = Path(sys.argv[1])
if not patch_path.is_file():
    raise SystemExit(f"missing patch: {patch_path}")


def replace_once(path: str, old: str, new: str, desc: str) -> None:
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{desc}: expected one exact anchor in {path}, found {count}")
    p.write_text(s.replace(old, new, 1))
    print(f"[N45] adapted {path}: {desc}")


namespace_anchor = "#include <linux/sched/task.h>\n\n#include \"pnode.h\""
namespace_repl = """#include <linux/sched/task.h>

#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);

static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);
static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;
static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;

#define CL_ZYGOTE_COPY_MNT_NS BIT(24) /* used by copy_mnt_ns() */
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif

#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif

#include \"pnode.h\""""
replace_once("fs/namespace.c", namespace_anchor, namespace_repl,
             "SUSFS mount declarations on vendor include layout")

task_anchor = "#include <linux/uaccess.h>\n\n#include <asm/elf.h>"
task_repl = """#include <linux/uaccess.h>
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
#include <linux/susfs_def.h>
#endif

#include <asm/elf.h>"""
replace_once("fs/proc/task_mmu.c", task_anchor, task_repl,
             "SUSFS kstat include on vendor proc-maps layout")

readdir = Path("fs/readdir.c")
s = readdir.read_text()
fill64_marker = "static int filldir64(struct dir_context *ctx, const char *name, int namlen,"
fill64_pos = s.find(fill64_marker)
if fill64_pos < 0:
    raise SystemExit("filldir64 marker missing")
compat_pos = s.find("static int compat_filldir(struct dir_context *ctx, const char *name, int namlen,")
if compat_pos < 0:
    raise SystemExit("compat_filldir marker missing")
fill64_chunk = s[fill64_pos:compat_pos]
fill64_anchor = """\tbuf->error = verify_dirent_name(name, namlen);
\tif (unlikely(buf->error))
\t\treturn buf->error;
\tbuf->error = -EINVAL;\t/* only used if we fail.. */"""
fill64_repl = """\tbuf->error = verify_dirent_name(name, namlen);
\tif (unlikely(buf->error))
\t\treturn buf->error;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {
\t\treturn 0;
\t}
#endif
\tbuf->error = -EINVAL;\t/* only used if we fail.. */"""
if fill64_chunk.count(fill64_anchor) != 1:
    raise SystemExit(f"filldir64 exact anchor count={fill64_chunk.count(fill64_anchor)}")
fill64_chunk = fill64_chunk.replace(fill64_anchor, fill64_repl, 1)
s = s[:fill64_pos] + fill64_chunk + s[compat_pos:]
compat_pos = s.find("static int compat_filldir(struct dir_context *ctx, const char *name, int namlen,")
compat_chunk = s[compat_pos:]
compat_anchor = """\tbuf->error = -EINVAL;\t/* only used if we fail.. */
\tif (reclen > buf->count)
\t\treturn -EINVAL;
\td_ino = ino;"""
compat_repl = """\tbuf->error = -EINVAL;\t/* only used if we fail.. */
\tif (reclen > buf->count)
\t\treturn -EINVAL;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {
\t\treturn 0;
\t}
#endif
\td_ino = ino;"""
if compat_chunk.count(compat_anchor) != 1:
    raise SystemExit(f"compat_filldir exact anchor count={compat_chunk.count(compat_anchor)}")
compat_chunk = compat_chunk.replace(compat_anchor, compat_repl, 1)
s = s[:compat_pos] + compat_chunk
readdir.write_text(s)
print("[N45] adapted fs/readdir.c: filldir64 + compat_filldir SUSFS filters")

fdinfo = Path("fs/notify/fdinfo.c")
s = fdinfo.read_text()
func = "static void inotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)"
pos = s.find(func)
if pos < 0:
    raise SystemExit("inotify_fdinfo marker missing")
end = s.find("\n}\n\nvoid inotify_show_fdinfo", pos)
if end < 0:
    raise SystemExit("inotify_fdinfo end marker missing")
chunk = s[pos:end]
fd_anchor = """\tinode = igrab(mark->connector->inode);
\tif (inode) {
\t\tseq_printf(m, \"inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 \","""
fd_repl = """\tinode = igrab(mark->connector->inode);
\tif (inode) {
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) &&
\t\t\t\tunlikely(inode->i_state & INODE_STATE_SUS_KSTAT)) {
\t\t\tstruct path path;
\t\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\t\tif (pathname) {
\t\t\t\tchar *dpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\t\t\tif (!IS_ERR(dpath) && !kern_path(dpath, 0, &path)) {
\t\t\t\t\tseq_printf(m, \"inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 \",
\t\t\t\t\t\t   inode_mark->wd, path.dentry->d_inode->i_ino,
\t\t\t\t\t\t   path.dentry->d_inode->i_sb->s_dev,
\t\t\t\t\t\t   inotify_mark_user_mask(mark));
\t\t\t\t\tshow_mark_fhandle(m, path.dentry->d_inode);
\t\t\t\t\tseq_putc(m, '\\n');
\t\t\t\t\tpath_put(&path);
\t\t\t\t\tkfree(pathname);
\t\t\t\t\tiput(inode);
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t\tkfree(pathname);
\t\t\t}
\t\t}
#endif
\t\tseq_printf(m, \"inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 \","""
if chunk.count(fd_anchor) != 1:
    raise SystemExit(f"inotify exact anchor count={chunk.count(fd_anchor)}")
chunk = chunk.replace(fd_anchor, fd_repl, 1)
s = s[:pos] + chunk + s[end:]
fdinfo.write_text(s)
print("[N45] adapted fs/notify/fdinfo.c: Android inotify SUSFS reporting")

sysc = Path("kernel/sys.c")
s = sysc.read_text()
extern_anchor = "\nSYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)"
extern_repl = """
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
extern void susfs_spoof_uname(struct new_utsname *tmp);
#endif
SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)"""
if s.count(extern_anchor) != 1:
    raise SystemExit(f"newuname declaration anchor count={s.count(extern_anchor)}")
s = s.replace(extern_anchor, extern_repl, 1)
start = s.find("SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)")
end = s.find("\n}\n", start)
if start < 0 or end < 0:
    raise SystemExit("newuname function bounds missing")
chunk = s[start:end]
uname_anchor = """\t\tpr_debug(\"fake uname: %s/%d release=%s\\n\",
\t\t\t current->comm, current->pid, tmp.release);
\t}
\tup_read(&uts_sem);"""
uname_repl = """\t\tpr_debug(\"fake uname: %s/%d release=%s\\n\",
\t\t\t current->comm, current->pid, tmp.release);
\t}
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\tsusfs_spoof_uname(&tmp);
#endif
\tup_read(&uts_sem);"""
if chunk.count(uname_anchor) != 1:
    raise SystemExit(f"newuname body anchor count={chunk.count(uname_anchor)}")
chunk = chunk.replace(uname_anchor, uname_repl, 1)
s = s[:start] + chunk + s[end:]
sysc.write_text(s)
print("[N45] adapted kernel/sys.c: preserve bpfloader uname + add SUSFS spoof")


def remove_hunk(file_path: str, old_start: int, marker: str) -> None:
    lines = patch_path.read_text().splitlines(keepends=True)
    current_file = None
    target_start = target_end = None
    hunk_re = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
    for i, line in enumerate(lines):
        if line.startswith("diff --git a/"):
            m = re.match(r"diff --git a/(.+?) b/(.+?)\r?\n?$", line)
            current_file = m.group(1) if m else None
            continue
        if current_file == file_path and line.startswith("@@ "):
            m = hunk_re.match(line)
            if m and int(m.group(1)) == old_start:
                target_start = i
                for j in range(i + 1, len(lines)):
                    if lines[j].startswith("@@ ") or lines[j].startswith("diff --git "):
                        target_end = j
                        break
                if target_end is None:
                    target_end = len(lines)
                break
    if target_start is None:
        raise SystemExit(f"patch hunk not found: {file_path} old_start={old_start}")
    removed = "".join(lines[target_start:target_end])
    if marker not in removed:
        raise SystemExit(f"refusing unexpected hunk {file_path}:{old_start}; marker {marker!r} absent")
    del lines[target_start:target_end]
    text = "".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    patch_path.write_text(text)
    print(f"[N45] removed superseded SUSFS hunk {file_path}:{old_start}")


for spec in [
    ("fs/namespace.c", 30, "susfs_mnt_id_ida"),
    ("fs/notify/fdinfo.c", 90, "struct path path;"),
    ("fs/proc/task_mmu.c", 19, "#include <linux/susfs_def.h>"),
    ("fs/readdir.c", 260, "susfs_sus_ino_for_filldir64"),
    ("fs/readdir.c", 424, "susfs_sus_ino_for_filldir64"),
    ("kernel/sys.c", 1182, "susfs_spoof_uname"),
]:
    remove_hunk(*spec)

print("[N45] Miatoll SUSFS 4.14 patch adaptation ready; remaining hunks must still dry-run")
