#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('kernel/bpf/syscall.c')
s = p.read_text()

if 'N45-BPFDBG' in s:
    print('[bpf-debug] trace already present')
    raise SystemExit(0)

m = re.search(r'(SYSCALL_DEFINE3\(bpf, int, cmd, union bpf_attr __user \*, uattr, unsigned int, size\)\s*\{)(.*?)(^\})', s, re.M | re.S)
if not m:
    raise SystemExit('kernel/bpf/syscall.c: bpf syscall function not found')

body = m.group(2)
# Capture the final return value without changing dispatch behavior.
old = '\treturn err;'
if old not in body:
    raise SystemExit('kernel/bpf/syscall.c: final bpf return anchor not found')

trace = r'''
	if (err < 0) {
		if (cmd == BPF_MAP_CREATE) {
			pr_err("N45-BPFDBG: cmd=%d ret=%d MAP type=%u key=%u value=%u max=%u flags=0x%x name=%.16s\n",
			       cmd, err, attr.map_type, attr.key_size, attr.value_size,
			       attr.max_entries, attr.map_flags, attr.map_name);
		} else if (cmd == BPF_PROG_LOAD) {
			pr_err("N45-BPFDBG: cmd=%d ret=%d PROG type=%u insns=%u flags=0x%x name=%.16s\n",
			       cmd, err, attr.prog_type, attr.insn_cnt, attr.prog_flags,
			       attr.prog_name);
		} else if (cmd == BPF_BTF_LOAD) {
			pr_err("N45-BPFDBG: cmd=%d ret=%d BTF size=%u log_level=%u log_size=%u\n",
			       cmd, err, attr.btf_size, attr.btf_log_level, attr.btf_log_size);
		} else {
			pr_err("N45-BPFDBG: cmd=%d ret=%d\n", cmd, err);
		}
	}

	return err;'''
body = body.replace(old, trace, 1)
s = s[:m.start(2)] + body + s[m.end(2):]
p.write_text(s)
print('[bpf-debug] installed BPF syscall failure tracing')
PY
