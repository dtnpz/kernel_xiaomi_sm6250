#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import re

p = Path("kernel/bpf/syscall.c")
s = p.read_text()

marker = "N45-BPFDBG"
if marker in s:
    print("[bpf-debug] failure trace already applied")
    raise SystemExit(0)

pattern = re.compile(
    r'(\tcase BPF_BTF_LOAD:\n'
    r'\t\terr = bpf_btf_load\(&attr\);\n'
    r'\t\tbreak;\n'
    r'\tdefault:\n'
    r'\t\terr = -EINVAL;\n'
    r'\t\tbreak;\n'
    r'\t\}\n)'
    r'(\n\treturn err;\n\})',
    re.M,
)

trace = r'''\1
\t/* Temporary N45 boot diagnostic: keep Android's BPF behavior unchanged,
\t * but surface failures from the networking loaders into the kernel log so
\t * ramoops/pstore survives init's reboot_on_failure path.
\t */
\tif (unlikely(err < 0) &&
\t    (!strcmp(current->comm, "netbpfload") ||
\t     !strcmp(current->comm, "bpfloader") ||
\t     !strcmp(current->comm, "netd"))) {
\t\tif (cmd == BPF_MAP_CREATE) {
\t\t\tpr_err("N45-BPFDBG comm=%s cmd=MAP_CREATE err=%d type=%u key=%u value=%u max=%u flags=%#x name=%.16s\\n",
\t\t\t       current->comm, err, attr.map_type, attr.key_size,
\t\t\t       attr.value_size, attr.max_entries, attr.map_flags,
\t\t\t       attr.map_name);
\t\t} else if (cmd == BPF_PROG_LOAD) {
\t\t\tpr_err("N45-BPFDBG comm=%s cmd=PROG_LOAD err=%d type=%u insns=%u flags=%#x expected_attach=%u name=%.16s\\n",
\t\t\t       current->comm, err, attr.prog_type, attr.insn_cnt,
\t\t\t       attr.prog_flags, attr.expected_attach_type,
\t\t\t       attr.prog_name);
\t\t} else {
\t\t\tpr_err("N45-BPFDBG comm=%s cmd=%d err=%d size=%u\\n",
\t\t\t       current->comm, cmd, err, size);
\t\t}
\t}
\2'''

ns, n = pattern.subn(trace, s, count=1)
if n != 1:
    raise SystemExit(f"kernel/bpf/syscall.c: syscall tail anchor expected once, got {n}")

p.write_text(ns)
print("[bpf-debug] netbpfload/bpfloader/netd failure trace applied")
PY

git diff --check -- kernel/bpf/syscall.c
grep -q 'N45-BPFDBG' kernel/bpf/syscall.c
echo '[bpf-debug] ready'
