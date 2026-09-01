#!/usr/bin/env python3
"""Run adapt-susfs-414.py with only its brittle newuname parser corrected.

The existing adapter is already CI-proven through namespace/proc/readdir/fdinfo.
Keep it byte-for-byte otherwise; replace only the function-bound slicing with a
unique exact body transform, then execute the resulting source in-process.
"""
from pathlib import Path
import sys

src_path = Path("scripts/gx/adapt-susfs-414.py")
src = src_path.read_text()

old = '''start = s.find("SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)")
end = s.find("\\n}\\n", start)
if start < 0 or end < 0:
    raise SystemExit("newuname function bounds missing")
chunk = s[start:end]
uname_anchor = """\\t\\tpr_debug(\\"fake uname: %s/%d release=%s\\\\n\\",
\\t\\t\\t current->comm, current->pid, tmp.release);
\\t}
\\tup_read(&uts_sem);"""
uname_repl = """\\t\\tpr_debug(\\"fake uname: %s/%d release=%s\\\\n\\",
\\t\\t\\t current->comm, current->pid, tmp.release);
\\t}
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\\tsusfs_spoof_uname(&tmp);
#endif
\\tup_read(&uts_sem);"""
if chunk.count(uname_anchor) != 1:
    raise SystemExit(f"newuname body anchor count={chunk.count(uname_anchor)}")
chunk = chunk.replace(uname_anchor, uname_repl, 1)
s = s[:start] + chunk + s[end:]
sysc.write_text(s)
'''

new = '''uname_anchor = """\\t\\tpr_debug(\\"fake uname: %s/%d release=%s\\\\n\\",
\\t\\t\\t current->comm, current->pid, tmp.release);
\\t}
\\tup_read(&uts_sem);"""
uname_repl = """\\t\\tpr_debug(\\"fake uname: %s/%d release=%s\\\\n\\",
\\t\\t\\t current->comm, current->pid, tmp.release);
\\t}
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
\\tsusfs_spoof_uname(&tmp);
#endif
\\tup_read(&uts_sem);"""
if s.count(uname_anchor) != 1:
    raise SystemExit(f"newuname body anchor count={s.count(uname_anchor)}")
s = s.replace(uname_anchor, uname_repl, 1)
sysc.write_text(s)
'''

count = src.count(old)
if count != 1:
    raise SystemExit(f"refusing adapter rewrite: expected one brittle newuname block, found {count}")
patched = src.replace(old, new, 1)

# Preserve argv expected by the original adapter and execute it as __main__.
sys.argv[0] = str(src_path)
ns = {"__name__": "__main__", "__file__": str(src_path)}
exec(compile(patched, str(src_path), "exec"), ns, ns)
