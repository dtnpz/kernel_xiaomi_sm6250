#!/usr/bin/env python3
"""Remove obsolete Velvet manual-KSU call sites for modern xxKSU.

The ProjectVelvet base carries legacy in-kernel callbacks intended for older
manual-hook KernelSU integrations.  backslashxx v3.3.0-2 instead provides its
own syscall-table, LSM, read and input implementations.  Leaving both paths
enabled makes CONFIG_KSU reference legacy symbols that xxKSU does not export.

Only CONFIG_KSU preprocessor blocks containing the explicitly-listed legacy
symbols are removed.  Nested preprocessor blocks are parsed structurally and
every expected symbol must be completely gone afterwards.
"""
from pathlib import Path
import sys

if len(sys.argv) != 1:
    raise SystemExit("usage: strip-xxksu-legacy-vendor-hooks.py")

targets = {
    Path("fs/open.c"): "ksu_handle_faccessat",
    Path("fs/read_write.c"): "ksu_handle_vfs_read",
    Path("fs/stat.c"): "ksu_handle_stat",
    Path("fs/exec.c"): "ksu_handle_execveat",
    Path("drivers/input/input.c"): "ksu_handle_input_handle_event",
}

OPENERS = ("#if ", "#if\t", "#ifdef ", "#ifndef ")

def strip_blocks(path: Path, symbol: str) -> int:
    if not path.is_file():
        raise SystemExit(f"missing vendor source: {path}")
    lines = path.read_text().splitlines(keepends=True)
    out = []
    removed = 0
    i = 0
    while i < len(lines):
        if lines[i].strip() != "#ifdef CONFIG_KSU":
            out.append(lines[i])
            i += 1
            continue

        depth = 1
        j = i + 1
        while j < len(lines) and depth:
            stripped = lines[j].lstrip()
            if stripped.startswith(OPENERS):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1
            j += 1
        if depth:
            raise SystemExit(f"{path}: unterminated CONFIG_KSU block near line {i + 1}")

        block = "".join(lines[i:j])
        if symbol in block:
            removed += 1
        else:
            out.extend(lines[i:j])
        i = j

    text = "".join(out)
    if symbol in text:
        raise SystemExit(
            f"{path}: {symbol} remains outside removable CONFIG_KSU blocks"
        )
    if removed < 1:
        raise SystemExit(f"{path}: found no CONFIG_KSU block containing {symbol}")
    path.write_text(text)
    return removed

for path, symbol in targets.items():
    count = strip_blocks(path, symbol)
    print(f"[N45] xxKSU removed {count} obsolete vendor block(s): {path}:{symbol}")

print("[N45] xxKSU legacy Velvet manual-hook cleanup complete")
