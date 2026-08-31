#!/usr/bin/env bash
set -euo pipefail

# Deterministic resolver for the known OpenELA 4.14.350 merge conflict.
#
# Velvet carries newer Android cgroup-BPF hooks and an inet6_bind refactor,
# while OpenELA 4.14.350 fixes an IPV6_ADDRFORM race by snapshotting
# sk->sk_prot with READ_ONCE().  We must preserve both sides semantically.
#
# This script intentionally refuses to touch the merge if the conflict set is
# anything other than the two files reviewed below.

expected=$'net/ipv4/af_inet.c\nnet/ipv6/af_inet6.c'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.350 resolution: unexpected conflict set." >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

# Start from Velvet's versions because they contain the Android-specific BPF
# and inet6_bind structure.  The Python edit below then reapplies the exact
# OpenELA race-fix semantics.  This is NOT a global 'ours' conflict policy.
git checkout --ours -- net/ipv4/af_inet.c net/ipv6/af_inet6.c

python3 <<'PY'
from pathlib import Path

p4 = Path("net/ipv4/af_inet.c")
s4 = p4.read_text()
old4 = '''int inet_dgram_connect(struct socket *sock, struct sockaddr *uaddr,
\t\t       int addr_len, int flags)
{
\tstruct sock *sk = sock->sk;
\tint err;

\tif (addr_len < sizeof(uaddr->sa_family))
\t\treturn -EINVAL;
\tif (uaddr->sa_family == AF_UNSPEC)
\t\treturn sk->sk_prot->disconnect(sk, flags);

\tif (BPF_CGROUP_PRE_CONNECT_ENABLED(sk)) {
\t\terr = sk->sk_prot->pre_connect(sk, uaddr, addr_len);
\t\tif (err)
\t\t\treturn err;
\t}

\tif (!inet_sk(sk)->inet_num && inet_autobind(sk))
\t\treturn -EAGAIN;
\treturn sk->sk_prot->connect(sk, uaddr, addr_len);
}
'''
new4 = '''int inet_dgram_connect(struct socket *sock, struct sockaddr *uaddr,
\t\t       int addr_len, int flags)
{
\tstruct sock *sk = sock->sk;
\tconst struct proto *prot;
\tint err;

\tif (addr_len < sizeof(uaddr->sa_family))
\t\treturn -EINVAL;

\t/* IPV6_ADDRFORM can change sk->sk_prot under us. */
\tprot = READ_ONCE(sk->sk_prot);

\tif (uaddr->sa_family == AF_UNSPEC)
\t\treturn prot->disconnect(sk, flags);

\t/* Keep Velvet's Android cgroup-BPF pre-connect hook while using the
\t * same protocol snapshot as the OpenELA race fix.  The second check
\t * prevents calling through a NULL callback if sk_prot changed between
\t * the BPF enable test and our snapshot.
\t */
\tif (BPF_CGROUP_PRE_CONNECT_ENABLED(sk) && prot->pre_connect) {
\t\terr = prot->pre_connect(sk, uaddr, addr_len);
\t\tif (err)
\t\t\treturn err;
\t}

\tif (!inet_sk(sk)->inet_num && inet_autobind(sk))
\t\treturn -EAGAIN;
\treturn prot->connect(sk, uaddr, addr_len);
}
'''
if s4.count(old4) != 1:
    raise SystemExit("net/ipv4/af_inet.c: reviewed inet_dgram_connect block not found exactly once")
p4.write_text(s4.replace(old4, new4, 1))

p6 = Path("net/ipv6/af_inet6.c")
s6 = p6.read_text()
old6 = '''int inet6_bind(struct socket *sock, struct sockaddr *uaddr, int addr_len)
{
\tstruct sock *sk = sock->sk;
\tint err = 0;

\t/* If the socket has its own bind function then use it. */
\tif (sk->sk_prot->bind)
\t\treturn sk->sk_prot->bind(sk, uaddr, addr_len);

\tif (addr_len < SIN6_LEN_RFC2133)
\t\treturn -EINVAL;

\t/* BPF prog is run before any checks are done so that if the prog
\t * changes context in a wrong way it will be caught.
\t */
\terr = BPF_CGROUP_RUN_PROG_INET6_BIND(sk, uaddr);
\tif (err)
\t\treturn err;

\treturn __inet6_bind(sk, uaddr, addr_len, false, true);
}
'''
new6 = '''int inet6_bind(struct socket *sock, struct sockaddr *uaddr, int addr_len)
{
\tstruct sock *sk = sock->sk;
\tconst struct proto *prot;
\tint err = 0;

\t/* IPV6_ADDRFORM can change sk->sk_prot under us. */
\tprot = READ_ONCE(sk->sk_prot);

\t/* If the socket has its own bind function then use it. */
\tif (prot->bind)
\t\treturn prot->bind(sk, uaddr, addr_len);

\tif (addr_len < SIN6_LEN_RFC2133)
\t\treturn -EINVAL;

\t/* Preserve Velvet's Android BPF bind hook and its __inet6_bind()
\t * refactor; only the protocol pointer access comes from OpenELA.
\t */
\terr = BPF_CGROUP_RUN_PROG_INET6_BIND(sk, uaddr);
\tif (err)
\t\treturn err;

\treturn __inet6_bind(sk, uaddr, addr_len, false, true);
}
'''
if s6.count(old6) != 1:
    raise SystemExit("net/ipv6/af_inet6.c: reviewed inet6_bind block not found exactly once")
p6.write_text(s6.replace(old6, new6, 1))
PY

git add net/ipv4/af_inet.c net/ipv6/af_inet6.c

git diff --check --cached

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.350 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

# Complete the merge using Git's prepared MERGE_MSG, keeping both ancestry
# parents visible in history.
git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.350 conflicts successfully."
