#!/usr/bin/env python3
from pathlib import Path

idr = Path("lib/idr.c")
hdr = Path("include/linux/idr.h")

s = idr.read_text()

# The modern IDA API prerequisite chain used by SUSFS was imported from a
# kernel that already had XArray. N45 4.14 intentionally stays radix-tree
# based, so retain the new ida_alloc*/ida_free API while restoring the original
# global IDA locking model instead of dragging the XArray subsystem into 4.14.
xarray_inc = "#include <linux/xarray.h>\n"
if s.count(xarray_inc) != 1:
    raise SystemExit(
        f"lib/idr.c: expected one xarray include after IDA series, got {s.count(xarray_inc)}"
    )
s = s.replace(xarray_inc, "", 1)

percpu = "DEFINE_PER_CPU(struct ida_bitmap *, ida_bitmap);\n"
lock_decl = "static DEFINE_SPINLOCK(simple_ida_lock);\n"
if s.count(percpu) != 1:
    raise SystemExit("lib/idr.c: IDA per-cpu anchor changed")
if lock_decl not in s:
    s = s.replace(percpu, percpu + lock_decl, 1)

old_lock = "xa_lock_irqsave(&ida->ida_rt, flags);"
old_unlock = "xa_unlock_irqrestore(&ida->ida_rt, flags);"
locks = s.count(old_lock)
unlocks = s.count(old_unlock)
if locks < 3 or locks != unlocks:
    raise SystemExit(
        f"lib/idr.c: unexpected XArray lock shape locks={locks} unlocks={unlocks}"
    )
s = s.replace(old_lock, "spin_lock_irqsave(&simple_ida_lock, flags);")
s = s.replace(old_unlock, "spin_unlock_irqrestore(&simple_ida_lock, flags);")

if "xarray.h" in s or "xa_lock" in s or "xa_unlock" in s:
    raise SystemExit("lib/idr.c: XArray dependency remains after 4.14 adaptation")

idr.write_text(s)

hs = hdr.read_text()
required = (
    "int ida_alloc_range(struct ida *",
    "static inline int ida_alloc(struct ida *ida",
    "static inline int ida_alloc_min(struct ida *ida",
    "static inline int ida_alloc_max(struct ida *ida",
    "#define ida_simple_remove(ida, id)\tida_free(ida, id)",
)
for needle in required:
    if needle not in hs:
        raise SystemExit(f"include/linux/idr.h: missing new IDA API: {needle}")

for needle in ("int ida_alloc_range(struct ida *ida", "void ida_free(struct ida *ida"):
    if needle not in s:
        raise SystemExit(f"lib/idr.c: missing IDA implementation: {needle}")

print(
    f"[N45][IDA] retained modern IDA API with 4.14 radix-tree locking; "
    f"converted {locks} XArray lock pairs"
)
