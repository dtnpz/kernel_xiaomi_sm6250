#!/usr/bin/env python3
"""Remove obsolete ProjectVelvet manual KernelSU callbacks for modern KSU cores.

Modern backslashxx KernelSU and KernelSU-Next v3.3.0 provide their own hook
engines and do not export Velvet's old ksu_handle_* callback ABI.  Leaving the
old CONFIG_KSU blocks in the 4.14 vendor tree causes undefined symbols at link.
"""
from pathlib import Path

mandatory = {
    Path('fs/open.c'): 'ksu_handle_faccessat',
    Path('fs/read_write.c'): 'ksu_handle_vfs_read',
    Path('fs/stat.c'): 'ksu_handle_stat',
    Path('fs/exec.c'): 'ksu_handle_execveat',
    Path('drivers/input/input.c'): 'ksu_handle_input_handle_event',
}
optional = {
    Path('kernel/sys.c'): 'ksu_handle_setresuid',
    Path('kernel/reboot.c'): 'ksu_handle_sys_reboot',
}
OPENERS = ('#if ', '#if\t', '#ifdef ', '#ifndef ')

def strip_blocks(path: Path, symbol: str, required: bool) -> int:
    if not path.is_file():
        if required:
            raise SystemExit(f'missing vendor source: {path}')
        return 0
    lines = path.read_text().splitlines(keepends=True)
    out, removed, i = [], 0, 0
    while i < len(lines):
        if lines[i].strip() != '#ifdef CONFIG_KSU':
            out.append(lines[i]); i += 1; continue
        depth, j = 1, i + 1
        while j < len(lines) and depth:
            stripped = lines[j].lstrip()
            if stripped.startswith(OPENERS):
                depth += 1
            elif stripped.startswith('#endif'):
                depth -= 1
            j += 1
        if depth:
            raise SystemExit(f'{path}: unterminated CONFIG_KSU block near line {i + 1}')
        block = ''.join(lines[i:j])
        if symbol in block:
            removed += 1
        else:
            out.extend(lines[i:j])
        i = j
    text = ''.join(out)
    if symbol in text:
        raise SystemExit(f'{path}: {symbol} remains outside removable CONFIG_KSU blocks')
    if required and removed < 1:
        raise SystemExit(f'{path}: found no CONFIG_KSU block containing {symbol}')
    path.write_text(text)
    return removed

for path, symbol in mandatory.items():
    count = strip_blocks(path, symbol, True)
    print(f'[GXT] removed {count} legacy block(s): {path}:{symbol}')
for path, symbol in optional.items():
    count = strip_blocks(path, symbol, False)
    if count:
        print(f'[GXT] removed {count} optional legacy block(s): {path}:{symbol}')
print('[GXT] legacy Velvet KSU callback cleanup complete')
