#!/usr/bin/env python3
"""Fix KernelSU-Next legacy SELinux status fake-page ABI for N45 Linux 4.14.

N45's security/selinux/selinuxfs.c stores a `struct page *` in
file->private_data for /sys/fs/selinux/status and calls page_address() only
when reading/mmaping it. KernelSU-Next legacy currently stores
page_address(fake_page) there instead, so N45 later treats that virtual address
as a struct page pointer and crashes in sel_read_handle_status.
"""
from pathlib import Path

p = Path("KernelSU-Next/kernel/feature/selinux_hide.c")
s = p.read_text()
old = "\t\t\tfilp->private_data = page_address(data);\n"
new = "\t\t\t/* N45/4.14 selinuxfs expects struct page * in private_data. */\n\t\t\tfilp->private_data = data;\n"
count = s.count(old)
if count != 1:
    raise SystemExit(f"[N45][KSUN-legacy] expected exactly one SELinux status private_data anchor, got {count}")
s = s.replace(old, new, 1)
p.write_text(s)
print("[N45][KSUN-legacy] fixed SELinux status fake-page ABI: private_data now stores struct page *")
