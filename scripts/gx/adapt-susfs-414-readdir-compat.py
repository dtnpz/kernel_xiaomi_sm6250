#!/usr/bin/env python3
"""Adapt the remaining SUSFS 4.14 compat_fillonedir hunk for Miatoll.

Android/OpenELA added verify_dirent_name() to compat_fillonedir(), so the
upstream kernel-4.14 SUSFS hunk at old line 352 no longer has its original
context. Insert the same inode filter after name validation, then remove only
that superseded hunk from the temporary SUSFS patch. The caller still dry-runs
all remaining hunks afterwards.
"""

from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: adapt-susfs-414-readdir-compat.py <temporary-kernel-patch>")

patch_path = Path(sys.argv[1])
if not patch_path.is_file():
    raise SystemExit(f"missing patch: {patch_path}")

readdir = Path("fs/readdir.c")
s = readdir.read_text()
marker = "static int compat_fillonedir(struct dir_context *ctx, const char *name,"
start = s.find(marker)
if start < 0:
    raise SystemExit("compat_fillonedir marker missing")
end = s.find("\n}\n\nCOMPAT_SYSCALL_DEFINE3(old_readdir", start)
if end < 0:
    raise SystemExit("compat_fillonedir end marker missing")
chunk = s[start:end]
anchor = """\tbuf->result = verify_dirent_name(name, namlen);
\tif (buf->result < 0)
\t\treturn buf->result;
\td_ino = ino;"""
replacement = """\tbuf->result = verify_dirent_name(name, namlen);
\tif (buf->result < 0)
\t\treturn buf->result;
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {
\t\treturn 0;
\t}
#endif
\td_ino = ino;"""
count = chunk.count(anchor)
if count != 1:
    raise SystemExit(f"compat_fillonedir exact anchor count={count}")
chunk = chunk.replace(anchor, replacement, 1)
s = s[:start] + chunk + s[end:]
readdir.write_text(s)
print("[N45] adapted fs/readdir.c: compat_fillonedir SUSFS filter")

lines = patch_path.read_text().splitlines(keepends=True)
current_file = None
target_start = target_end = None
hunk_re = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
for i, line in enumerate(lines):
    if line.startswith("diff --git a/"):
        m = re.match(r"diff --git a/(.+?) b/(.+?)\r?\n?$", line)
        current_file = m.group(1) if m else None
        continue
    if current_file == "fs/readdir.c" and line.startswith("@@ "):
        m = hunk_re.match(line)
        if m and int(m.group(1)) == 352:
            target_start = i
            for j in range(i + 1, len(lines)):
                if lines[j].startswith("@@ ") or lines[j].startswith("diff --git "):
                    target_end = j
                    break
            if target_end is None:
                target_end = len(lines)
            break
if target_start is None:
    raise SystemExit("patch hunk not found: fs/readdir.c old_start=352")
removed = "".join(lines[target_start:target_end])
for required in ("susfs_sus_ino_for_filldir64", "if (buf->result)", "d_ino = ino"):
    if required not in removed:
        raise SystemExit(f"refusing unexpected fs/readdir.c:352 hunk; {required!r} absent")
del lines[target_start:target_end]
text = "".join(lines)
if not text.endswith("\n"):
    text += "\n"
patch_path.write_text(text)
print("[N45] removed superseded SUSFS hunk fs/readdir.c:352")
