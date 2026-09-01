#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path

p = Path('kernel/bpf/syscall.c')
s = p.read_text()

old = '''SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr __user *, uattr, unsigned int, size)
{
\tunion bpf_attr attr;
\tint err;

\tif (sysctl_unprivileged_bpf_disabled && !capable(CAP_SYS_ADMIN))
\t\treturn -EPERM;

\terr = check_uarg_tail_zero(uattr, sizeof(attr), size);
\tif (err)
\t\treturn err;
\tsize = min_t(u32, size, sizeof(attr));

\t/* copy attributes from user space, may be less than sizeof(bpf_attr) */
\tmemset(&attr, 0, sizeof(attr));
\tif (copy_from_user(&attr, uattr, size) != 0)
\t\treturn -EFAULT;

\terr = security_bpf(cmd, &attr, size);
\tif (err < 0)
\t\treturn err;
'''

new = '''SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr __user *, uattr, unsigned int, size)
{
\tunion bpf_attr attr;
\tint err;
\tbool n45_netbpfdbg = !strncmp(current->comm, "netbpfload", 10);

\tif (sysctl_unprivileged_bpf_disabled && !capable(CAP_SYS_ADMIN)) {
\t\tif (n45_netbpfdbg)
\t\t\tpr_err("N45-BPFDBG: stage=priv cmd=%d size=%u ret=%d\\n",
\t\t\t       cmd, size, -EPERM);
\t\treturn -EPERM;
\t}

\terr = check_uarg_tail_zero(uattr, sizeof(attr), size);
\tif (err) {
\t\tif (n45_netbpfdbg)
\t\t\tpr_err("N45-BPFDBG: stage=tail cmd=%d size=%u ret=%d known_attr=%zu\\n",
\t\t\t       cmd, size, err, sizeof(attr));
\t\treturn err;
\t}
\tsize = min_t(u32, size, sizeof(attr));

\t/* copy attributes from user space, may be less than sizeof(bpf_attr) */
\tmemset(&attr, 0, sizeof(attr));
\tif (copy_from_user(&attr, uattr, size) != 0) {
\t\tif (n45_netbpfdbg)
\t\t\tpr_err("N45-BPFDBG: stage=copy cmd=%d size=%u ret=%d\\n",
\t\t\t       cmd, size, -EFAULT);
\t\treturn -EFAULT;
\t}

\terr = security_bpf(cmd, &attr, size);
\tif (err < 0) {
\t\tif (n45_netbpfdbg)
\t\t\tpr_err("N45-BPFDBG: stage=security cmd=%d size=%u ret=%d\\n",
\t\t\t       cmd, size, err);
\t\treturn err;
\t}
'''

if old not in s:
    raise SystemExit('kernel/bpf/syscall.c: BPF syscall prologue anchor not found')
s = s.replace(old, new, 1)

old_tail = '''\tdefault:
\t\terr = -EINVAL;
\t\tbreak;
\t}

\treturn err;
}
'''

new_tail = '''\tdefault:
\t\terr = -EINVAL;
\t\tbreak;
\t}

\tif (n45_netbpfdbg && err < 0) {
\t\tswitch (cmd) {
\t\tcase BPF_MAP_CREATE:
\t\t\tpr_err("N45-BPFDBG: stage=dispatch cmd=%d ret=%d map_type=%u key=%u value=%u max=%u flags=%#x inner_fd=%u numa=%u name=%.*s\\n",
\t\t\t       cmd, err, attr.map_type, attr.key_size,
\t\t\t       attr.value_size, attr.max_entries, attr.map_flags,
\t\t\t       attr.inner_map_fd, attr.numa_node,
\t\t\t       BPF_OBJ_NAME_LEN, attr.map_name);
\t\t\tbreak;
\t\tcase BPF_PROG_LOAD:
\t\t\tpr_err("N45-BPFDBG: stage=dispatch cmd=%d ret=%d prog_type=%u insns=%u flags=%#x ifindex=%u attach=%u name=%.*s log_level=%u\\n",
\t\t\t       cmd, err, attr.prog_type, attr.insn_cnt,
\t\t\t       attr.prog_flags, attr.prog_ifindex,
\t\t\t       attr.expected_attach_type,
\t\t\t       BPF_OBJ_NAME_LEN, attr.prog_name, attr.log_level);
\t\t\tbreak;
\t\tcase BPF_BTF_LOAD:
\t\t\tpr_err("N45-BPFDBG: stage=dispatch cmd=%d ret=%d btf_size=%u log_size=%u log_level=%u\\n",
\t\t\t       cmd, err, attr.btf_size, attr.btf_log_size,
\t\t\t       attr.btf_log_level);
\t\t\tbreak;
\t\tdefault:
\t\t\tpr_err("N45-BPFDBG: stage=dispatch cmd=%d ret=%d size=%u\\n",
\t\t\t       cmd, err, size);
\t\t\tbreak;
\t\t}
\t}

\treturn err;
}
'''

if old_tail not in s:
    raise SystemExit('kernel/bpf/syscall.c: BPF syscall tail anchor not found')
s = s.replace(old_tail, new_tail, 1)
p.write_text(s)
print('[bpfdbg] netbpfload BPF failure diagnostics applied')
PY

git diff --check -- kernel/bpf/syscall.c
grep -q 'N45-BPFDBG: stage=dispatch' kernel/bpf/syscall.c
grep -q 'N45-BPFDBG: stage=tail' kernel/bpf/syscall.c

echo '[bpfdbg] ready'
