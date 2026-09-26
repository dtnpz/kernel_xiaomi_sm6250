#!/usr/bin/env python3
"""Backport the exact KernelSU-Next v3.4.0 kernel core to Linux 4.14.

Keep upstream v3.4.0 behavior intact.  This adapter only substitutes kernel APIs
that do not exist in the N45 4.14 vendor tree; it must not reintroduce the old
legacy/UAPI2 selinux_hide implementation.
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


# Linux 4.14 predates copy_to_kernel_nofault().  The mapped FIX_TEXT_POKE0
# destination is kernel memory, and probe_kernel_write() is the 4.14 nofault
# kernel-write primitive with the same success/error convention.
replace_once(
    "KernelSU-Next/kernel/hook/arm64/patch_memory.c",
    "    ret = (int)copy_to_kernel_nofault(map, src, len);",
    "    ret = (int)probe_kernel_write(map, src, len);",
    "patch_memory nofault kernel write",
)

# Guardrails: the port must stay on the real v3.4.0/UAPI4 SELinux hide engine.
uapi = Path("KernelSU-Next/uapi/supercall.h").read_text()
hide = Path("KernelSU-Next/kernel/feature/selinux_hide.c").read_text()
if "static const __u32 KERNEL_SU_UAPI_VERSION = 4;" not in uapi:
    raise SystemExit("[KSUN340-414] expected v3.4.0 UAPI4 core")
if "static bool ksu_selinux_hide_enabled __read_mostly = false;" not in hide:
    raise SystemExit("[KSUN340-414] selinux_hide must start disabled")
if "blocked transaction_write from uid=" in hide:
    raise SystemExit("[KSUN340-414] legacy transaction_write blocker detected")

print("[KSUN340-414] v3.4.0 Linux 4.14 API adapter ready")
