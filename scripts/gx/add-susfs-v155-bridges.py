#!/usr/bin/env python3
"""Install the small SUSFS v1.5.5 ABI bridge required by modern KSU trees.

The pinned SUSFS 1.5.5 kernel layer still calls three legacy KernelSU symbols:
  - susfs_is_current_ksu_domain()
  - susfs_is_current_zygote_domain()
  - ksu_try_umount()

Both pinned root implementations already provide equivalent internal helpers.
This script exposes only those three compatibility entry points, using guarded
source anchors so an unexpected upstream layout fails loudly instead of being
patched with fuzz.
"""
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: add-susfs-v155-bridges.py <KSU-dir> <xxksu|ksun>")

ksu = Path(sys.argv[1])
kind = sys.argv[2]
if kind not in {"xxksu", "ksun"}:
    raise SystemExit(f"unsupported root kind: {kind}")

selinux = ksu / "kernel/selinux/selinux.c"
umount = ksu / "kernel/feature/kernel_umount.c"
for p in (selinux, umount):
    if not p.is_file():
        raise SystemExit(f"required KSU source missing: {p}")

s = selinux.read_text()
if "bool susfs_is_current_ksu_domain(void)" not in s:
    anchor = "\nvoid escape_to_root_for_adb_root(void)\n"
    if s.count(anchor) != 1:
        raise SystemExit(f"{selinux}: SELinux bridge anchor count={s.count(anchor)}")
    bridge = r'''
#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_ksu_domain(void)
{
    return is_ksu_domain();
}

bool susfs_is_current_zygote_domain(void)
{
    return is_zygote(current_cred());
}
#endif

'''
    s = s.replace(anchor, "\n" + bridge + "void escape_to_root_for_adb_root(void)\n", 1)
    selinux.write_text(s)

s = selinux.read_text()
for symbol in ("susfs_is_current_ksu_domain", "susfs_is_current_zygote_domain"):
    if s.count(f"bool {symbol}(void)") != 1:
        raise SystemExit(f"{selinux}: failed to install unique {symbol} bridge")

s = umount.read_text()
if "void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)" not in s:
    if kind == "xxksu":
        anchor = "\nstatic inline int ksu_handle_umount(struct cred *new, const struct cred *old)\n"
        required = (
            "static inline void ksu_umount_mnt(const char *mnt, struct path *path, int flags)",
            "static inline void try_umount(const char *mnt, int flags)",
        )
    else:
        anchor = "\nstruct umount_tw {\n"
        required = (
            "static void ksu_umount_mnt(const char *mnt, struct path *path, int flags)",
            "static void try_umount(const char *mnt, int flags)",
        )
    for token in required:
        if token not in s:
            raise SystemExit(f"{umount}: missing expected pinned-{kind} token: {token}")
    if s.count(anchor) != 1:
        raise SystemExit(f"{umount}: umount bridge anchor count={s.count(anchor)}")
    bridge = r'''
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern bool susfs_is_mnt_devname_ksu(struct path *path);

void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)
{
    struct path path;
    int err;

    (void)uid;
    err = kern_path(mnt, 0, &path);
    if (err)
        return;

    if (path.dentry != path.mnt->mnt_root) {
        path_put(&path);
        return;
    }

    if (check_mnt && !susfs_is_mnt_devname_ksu(&path)) {
        path_put(&path);
        return;
    }

    ksu_umount_mnt(mnt, &path, flags);
}
#endif

'''
    s = s.replace(anchor, "\n" + bridge + anchor.lstrip("\n"), 1)
    umount.write_text(s)

s = umount.read_text()
needle = "void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)"
if s.count(needle) != 1:
    raise SystemExit(f"{umount}: failed to install unique ksu_try_umount bridge")
if "check_mnt && !susfs_is_mnt_devname_ksu(&path)" not in s:
    raise SystemExit(f"{umount}: ksu_try_umount lost the guarded mount check")

print(f"[N45] installed guarded SUSFS v1.5.5 ABI bridges for {kind}")
