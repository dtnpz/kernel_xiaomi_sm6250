#!/usr/bin/env python3
"""Focused source regression checks for the official KSUN 3.4.0 4.14 bridge."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
KSU = ROOT / "KernelSU-Next" / "kernel"


def need(path: str, text: str, label: str) -> str:
    source = (KSU / path).read_text()
    if text not in source:
        raise SystemExit(f"[KSUN340-414-TEST] missing {label} in {path}")
    return source


arch = need(
    "include/arch.h",
    '#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n'
    '#define REBOOT_SYMBOL "sys_reboot"\n'
    '#else\n'
    '#define REBOOT_SYMBOL "__arm64_sys_reboot"\n'
    "#endif",
    "Linux 4.14 reboot symbol selection",
)
if arch.count('#define REBOOT_SYMBOL "sys_reboot"') != 1:
    raise SystemExit("[KSUN340-414-TEST] reboot symbol must be defined once")

supercall = need(
    "supercall/supercall.c",
    "#if defined(__aarch64__) && LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n"
    "    struct pt_regs *real_regs = regs;\n"
    "#else\n"
    "    struct pt_regs *real_regs = PT_REAL_REGS(regs);\n"
    "#endif",
    "Linux 4.14 direct C-ABI kprobe register handling",
)
need(
    "supercall/supercall.c",
    "unsigned long arg4 = (unsigned long)PT_REGS_CCALL_PARM4(real_regs);",
    "direct C-ABI fourth reboot argument",
)
if "register_kprobe(&reboot_kp)" not in supercall:
    raise SystemExit("[KSUN340-414-TEST] official reboot kprobe registration disappeared")

patch = need(
    "hook/arm64/patch_memory.c",
    "if (pud_sect(*pud))",
    "Linux 4.14 PUD section mapping",
)
for label, section, frame, bad in (
    ("PUD", "if (pud_sect(*pud))", "pud_pfn(*pud)", "pud_bad(*pud)"),
    ("PMD", "if (pmd_sect(*pmd))", "pmd_pfn(*pmd)", "pmd_bad(*pmd)"),
):
    section_at = patch.find(section)
    frame_at = patch.find(frame, section_at)
    bad_at = patch.find(bad, section_at)
    if min(section_at, frame_at, bad_at) < 0 or not section_at < frame_at < bad_at:
        raise SystemExit(f"[KSUN340-414-TEST] {label} section must resolve before bad-table rejection")
    mask = "PUD_MASK" if label == "PUD" else "PMD_MASK"
    if f"(addr & ~{mask})" not in patch[section_at:bad_at]:
        raise SystemExit(f"[KSUN340-414-TEST] {label} section offset calculation missing")

if 'failed at page-table level %s' not in patch or 'level = "pud";' not in patch:
    raise SystemExit("[KSUN340-414-TEST] page-table failure-level diagnostic missing")

print("[KSUN340-414-TEST] reboot FD and SELinux status patch bridges passed")
