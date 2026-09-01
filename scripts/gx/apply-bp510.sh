#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# Controlled BP delta for this already heavily-backported Android 4.14 tree.
# The UAPI already advertises BPF_FUNC_get_current_cgroup_id, but NBP does not
# implement or expose the helper. Complete that capability using the established
# Linux 4.19 implementation and expose it to tracing programs with CGROUPS.
python3 <<'PY'
from pathlib import Path
helpers=Path('kernel/bpf/helpers.c'); bpf_h=Path('include/linux/bpf.h'); trace=Path('kernel/trace/bpf_trace.c'); uapi=Path('include/uapi/linux/bpf.h')
hs,bs,ts,us=helpers.read_text(),bpf_h.read_text(),trace.read_text(),uapi.read_text()
if 'BPF_CALL_0(bpf_get_current_cgroup_id)' in hs: raise SystemExit('BP would not be distinct')
if 'FN(get_current_cgroup_id)' not in us: raise SystemExit('UAPI helper ID missing')
if 'task_dfl_cgroup' not in Path('include/linux/cgroup.h').read_text(): raise SystemExit('task_dfl_cgroup API missing')
inc='#include <linux/filter.h>\n'
if hs.count(inc)!=1: raise SystemExit(f'helpers include anchor count={hs.count(inc)}')
hs=hs.replace(inc,inc+'#include <linux/cgroup.h>\n',1)
a='''const struct bpf_func_proto bpf_get_current_comm_proto = {
\t.func\t\t= bpf_get_current_comm,
\t.gpl_only\t= false,
\t.ret_type\t= RET_INTEGER,
\t.arg1_type\t= ARG_PTR_TO_UNINIT_MEM,
\t.arg2_type\t= ARG_CONST_SIZE,
};
'''
b=a+'''
#ifdef CONFIG_CGROUPS
BPF_CALL_0(bpf_get_current_cgroup_id)
{
\tstruct cgroup *cgrp = task_dfl_cgroup(current);
\treturn cgrp->kn->id.id;
}
const struct bpf_func_proto bpf_get_current_cgroup_id_proto = {
\t.func\t\t= bpf_get_current_cgroup_id,
\t.gpl_only\t= false,
\t.ret_type\t= RET_INTEGER,
};
#endif
'''
if hs.count(a)!=1: raise SystemExit(f'helpers implementation anchor count={hs.count(a)}')
hs=hs.replace(a,b,1)
p='extern const struct bpf_func_proto bpf_get_current_comm_proto;\n'
if bs.count(p)!=1: raise SystemExit(f'bpf.h prototype anchor count={bs.count(p)}')
bs=bs.replace(p,p+'#ifdef CONFIG_CGROUPS\nextern const struct bpf_func_proto bpf_get_current_cgroup_id_proto;\n#endif\n',1)
d='''\tcase BPF_FUNC_get_current_comm:
\t\treturn &bpf_get_current_comm_proto;
\tcase BPF_FUNC_trace_printk:
'''
r='''\tcase BPF_FUNC_get_current_comm:
\t\treturn &bpf_get_current_comm_proto;
#ifdef CONFIG_CGROUPS
\tcase BPF_FUNC_get_current_cgroup_id:
\t\treturn &bpf_get_current_cgroup_id_proto;
#endif
\tcase BPF_FUNC_trace_printk:
'''
if ts.count(d)!=1: raise SystemExit(f'tracing dispatcher anchor count={ts.count(d)}')
ts=ts.replace(d,r,1)
helpers.write_text(hs); bpf_h.write_text(bs); trace.write_text(ts)
PY

grep -Fq 'BPF_CALL_0(bpf_get_current_cgroup_id)' kernel/bpf/helpers.c
grep -Fq 'return cgrp->kn->id.id;' kernel/bpf/helpers.c
grep -Fq 'bpf_get_current_cgroup_id_proto' include/linux/bpf.h
grep -Fq 'case BPF_FUNC_get_current_cgroup_id:' kernel/trace/bpf_trace.c
git diff --check -- kernel/bpf/helpers.c include/linux/bpf.h kernel/trace/bpf_trace.c
echo '[N45] BP: completed BPF_FUNC_get_current_cgroup_id support (Linux 4.19-style backport)'
