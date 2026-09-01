#!/usr/bin/env python3
"""Adapt the pinned modern xxKSU SUSFS patch to SUSFS v1.5.5 on Miatoll 4.14.

This deliberately handles only source-layout/API mismatches proven by CI.  It
performs exact guarded source transforms, removes only the superseded patch
sections, and leaves every remaining hunk for setup-susfs.sh to dry-run.
"""
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: adapt-xxksu-susfs-v155.py <KernelSU-dir> <temporary-patch>")

ksu = Path(sys.argv[1])
patch = Path(sys.argv[2])
if not ksu.is_dir() or not patch.is_file():
    raise SystemExit("missing KernelSU directory or temporary patch")

# 1) The Aug-22 adapter's first kernel_umount hunk targets a slightly newer
# xxKSU source that already had a webview-zygote toggle.  v3.3.0-2 does not.
# Preserve v3.3.0-2's effective behavior (webview unmount enabled) while making
# the kernel_umount flag externally visible for SUSFS and providing the helper
# required by the adapter's later setuid/umount code.
umount = ksu / "kernel/feature/kernel_umount.c"
s = umount.read_text()
old = """static bool ksu_kernel_umount_enabled __read_mostly = true;

static int kernel_umount_feature_get(u64 *value)
"""
new = """#ifndef CONFIG_KSU_SUSFS
static bool ksu_kernel_umount_enabled __read_mostly = true;
#else
bool ksu_kernel_umount_enabled __read_mostly = true;
#endif

bool ksu_is_webview_zygote_umount_enabled(void)
{
	/* v3.3.0-2 has no separate webview toggle: preserve its always-enabled behavior. */
	return true;
}

static int kernel_umount_feature_get(u64 *value)
"""
if s.count(old) != 1:
    raise SystemExit(f"xxKSU kernel_umount exact anchor count={s.count(old)}")
umount.write_text(s.replace(old, new, 1))
print("[N45] xxKSU: adapted kernel_umount visibility + webview compatibility helper")

# 2) The fetched adapter's supercall section is from a newer SUSFS protocol.
# The pinned 4.14 source is v1.5.5: use the established supercall magic only as
# transport, dispatch only commands actually defined by that pinned source, and
# pass arg4 (the user payload pointer), not the address of xxKSU's pointer slot.
supercall = ksu / "kernel/supercall/supercall.c"
s = supercall.read_text()
start_anchor = "static int anon_ksu_release(struct inode *inode, struct file *filp)\n"
if s.count(start_anchor) != 1:
    raise SystemExit(f"xxKSU supercall start anchor count={s.count(start_anchor)}")
preamble = """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs.h>
#define N45_SUSFS_SUPERCALL_MAGIC 0xFAFAFAFAu
#endif

"""
s = s.replace(start_anchor, preamble + start_anchor, 1)

bridge_anchor = """	// only root is allowed for these commands
	if (current_uid().val != 0)
		return 0;
	
	// extensions
"""
bridge = """	// only root is allowed for these commands
	if (current_uid().val != 0)
		return 0;

#ifdef CONFIG_KSU_SUSFS
	/* SUSFS v1.5.5 bridge for xxKSU's reboot supercall transport. */
	if ((unsigned int)magic2 == N45_SUSFS_SUPERCALL_MAGIC) {
		switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
		case CMD_SUSFS_ADD_SUS_PATH:
			susfs_add_sus_path((struct st_susfs_sus_path __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		case CMD_SUSFS_ADD_SUS_MOUNT:
			susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
		case CMD_SUSFS_ADD_SUS_KSTAT:
		case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
			susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg4);
			return 0;
		case CMD_SUSFS_UPDATE_SUS_KSTAT:
			susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
		case CMD_SUSFS_ADD_TRY_UMOUNT:
			susfs_add_try_umount((struct st_susfs_try_umount __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
		case CMD_SUSFS_SET_UNAME:
			susfs_set_uname((struct st_susfs_uname __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
		case CMD_SUSFS_ENABLE_LOG: {
			int enabled;
			if (!copy_from_user(&enabled, arg4, sizeof(enabled)))
				susfs_set_log(enabled != 0);
			return 0;
		}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
		case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
			susfs_set_cmdline_or_bootconfig((char __user *)arg4);
			return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
		case CMD_SUSFS_ADD_OPEN_REDIRECT:
			susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg4);
			return 0;
#endif
		case CMD_SUSFS_SHOW_VERSION:
			(void)copy_to_user(arg4, SUSFS_VERSION, sizeof(SUSFS_VERSION));
			return 0;
		case CMD_SUSFS_SHOW_VARIANT:
			(void)copy_to_user(arg4, SUSFS_VARIANT, sizeof(SUSFS_VARIANT));
			return 0;
		default:
			return 0;
		}
	}
#endif
	
	// extensions
"""
if s.count(bridge_anchor) != 1:
    raise SystemExit(f"xxKSU supercall bridge anchor count={s.count(bridge_anchor)}")
supercall.write_text(s.replace(bridge_anchor, bridge, 1))
print("[N45] xxKSU: installed typed SUSFS v1.5.5 supercall bridge")

# Patch surgery helpers.  Each removal asserts markers unique to the exact
# superseded section so a changed upstream adapter fails closed.
def remove_diff(diff_marker: str, required_markers: list[str]) -> None:
    lines = patch.read_text().splitlines(keepends=True)
    try:
        begin = next(i for i, line in enumerate(lines) if line.rstrip("\r\n") == diff_marker)
    except StopIteration:
        raise SystemExit(f"missing patch diff: {diff_marker}")
    end = len(lines)
    for i in range(begin + 1, len(lines)):
        if lines[i].startswith("diff --git "):
            end = i
            break
    removed = "".join(lines[begin:end])
    for marker in required_markers:
        if marker not in removed:
            raise SystemExit(f"refusing unexpected patch diff {diff_marker}: missing {marker!r}")
    del lines[begin:end]
    text = "".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    patch.write_text(text)
    print(f"[N45] removed superseded xxKSU patch diff: {diff_marker}")


def remove_first_hunk(diff_marker: str, required_markers: list[str]) -> None:
    lines = patch.read_text().splitlines(keepends=True)
    try:
        d = next(i for i, line in enumerate(lines) if line.rstrip("\r\n") == diff_marker)
    except StopIteration:
        raise SystemExit(f"missing patch diff: {diff_marker}")
    h1 = None
    for i in range(d + 1, len(lines)):
        if lines[i].startswith("diff --git "):
            break
        if lines[i].startswith("@@ "):
            h1 = i
            break
    if h1 is None:
        raise SystemExit(f"missing first hunk: {diff_marker}")
    h2 = None
    for i in range(h1 + 1, len(lines)):
        if lines[i].startswith("@@ ") or lines[i].startswith("diff --git "):
            h2 = i
            break
    if h2 is None or not lines[h2].startswith("@@ "):
        raise SystemExit(f"expected second hunk after first: {diff_marker}")
    removed = "".join(lines[h1:h2])
    for marker in required_markers:
        if marker not in removed:
            raise SystemExit(f"refusing unexpected first hunk {diff_marker}: missing {marker!r}")
    del lines[h1:h2]
    text = "".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    patch.write_text(text)
    print(f"[N45] removed superseded first hunk: {diff_marker}")

remove_first_hunk(
    "diff --git a/kernel/feature/kernel_umount.c b/kernel/feature/kernel_umount.c",
    ["ksu_kernel_umount_enabled", "ksu_webview_zygote_umount_enabled"],
)
remove_diff(
    "diff --git a/kernel/supercall/supercall.c b/kernel/supercall/supercall.c",
    ["SUSFS_MAGIC", "CMD_SUSFS_ADD_SUS_PATH_LOOP", "CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING"],
)

print("[N45] xxKSU SUSFS v1.5.5 adapter complete; all remaining hunks must dry-run")
