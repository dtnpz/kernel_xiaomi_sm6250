#!/usr/bin/env bash
set -euo pipefail

# OpenELA 4.14.352 backports:
#   ARM: 9324/1: fix get_user() broken with veneer
# which requires r12/ip to be clobbered by the hidden BL call.
#
# Velvet already routes the call through __asmbl() for its ARM module/PLT
# handling.  Preserve that mechanism, but make ip/lr/cc unconditional as
# required by the OpenELA fix.

expected='arch/arm/include/asm/uaccess.h'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.352 resolution: unexpected conflict set." >&2
  echo "Expected: $expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

git checkout --ours -- arch/arm/include/asm/uaccess.h

python3 <<'PY'
from pathlib import Path

p = Path('arch/arm/include/asm/uaccess.h')
s = p.read_text()

clobber_block = '''#define __GUP_CLOBBER_1\t"lr", "cc" __asmbl_clobber("ip")
#ifdef CONFIG_CPU_USE_DOMAINS
#define __GUP_CLOBBER_2\t"ip", "lr", "cc"
#else
#define __GUP_CLOBBER_2 "lr", "cc" __asmbl_clobber("ip")
#endif
#define __GUP_CLOBBER_4\t"lr", "cc" __asmbl_clobber("ip")
#define __GUP_CLOBBER_32t_8 "lr", "cc" __asmbl_clobber("ip")
#define __GUP_CLOBBER_8\t"lr", "cc" __asmbl_clobber("ip")

'''

if s.count(clobber_block) != 1:
    raise SystemExit('reviewed __GUP_CLOBBER block not found exactly once')
s = s.replace(clobber_block, '', 1)

old = '\t\t: __GUP_CLOBBER_##__s)'
new = '\t\t: "ip", "lr", "cc")'
count = s.count(old)
if count != 2:
    raise SystemExit(f'expected two __GUP_CLOBBER uses, found {count}')
s = s.replace(old, new)

# Ensure Velvet's __asmbl() mechanism was preserved for both calls.
if s.count('__asmbl("", "ip", "__get_user_" #__s)') != 1:
    raise SystemExit('Velvet __asmbl get_user call was not preserved')
if s.count('__asmbl("", "ip", "__get_user_64t_" #__s)') != 1:
    raise SystemExit('Velvet __asmbl get_user_64t call was not preserved')

p.write_text(s)
PY

git add arch/arm/include/asm/uaccess.h
git diff --check --cached

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.352 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.352 ARM uaccess conflict successfully."
