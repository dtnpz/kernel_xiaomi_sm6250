#!/usr/bin/env bash
set -euo pipefail

# OpenELA 4.14.353 carries two F2FS fixes relevant to the conflicts here:
#   - f2fs: prevent newly created inode from being dirtied incorrectly
#   - f2fs: fix to don't dirty inode for readonly filesystem
#
# Velvet's newer F2FS already sets FI_NEW_INODE before encryption setup, so
# preserve Velvet's namei.c. Add only the missing readonly guard to Velvet's
# newer f2fs_mark_inode_dirty_sync(). Refuse any unexpected conflict set.

expected=$'fs/f2fs/inode.c\nfs/f2fs/namei.c'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.353 resolution: unexpected conflict set." >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

# Velvet's newer namei.c already has the semantic change from OpenELA:
# FI_NEW_INODE is set before f2fs_may_encrypt()/f2fs_set_encrypted_inode().
git checkout --ours -- fs/f2fs/namei.c

# Start from Velvet's newer inode.c and add only the OpenELA readonly guard.
git checkout --ours -- fs/f2fs/inode.c

python3 <<'PY'
from pathlib import Path

p = Path('fs/f2fs/inode.c')
s = p.read_text()

old = '''void f2fs_mark_inode_dirty_sync(struct inode *inode, bool sync)
{
\tif (is_inode_flag_set(inode, FI_NEW_INODE))
\t\treturn;

\tif (f2fs_inode_dirtied(inode, sync))
'''
new = '''void f2fs_mark_inode_dirty_sync(struct inode *inode, bool sync)
{
\tif (is_inode_flag_set(inode, FI_NEW_INODE))
\t\treturn;

\tif (f2fs_readonly(F2FS_I_SB(inode)->sb))
\t\treturn;

\tif (f2fs_inode_dirtied(inode, sync))
'''

if s.count(old) != 1:
    raise SystemExit('reviewed f2fs_mark_inode_dirty_sync context not found exactly once')
s = s.replace(old, new, 1)
p.write_text(s)

# Verify the newer Velvet namei ordering remains intact.
n = Path('fs/f2fs/namei.c').read_text()
needle = '''\tset_inode_flag(inode, FI_NEW_INODE);

\tif (f2fs_may_encrypt(dir, inode))
\t\tf2fs_set_encrypted_inode(inode);
'''
if n.count(needle) != 1:
    raise SystemExit('Velvet FI_NEW_INODE-before-encryption ordering was not preserved')
PY

git add fs/f2fs/inode.c fs/f2fs/namei.c
git diff --check --cached

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.353 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.353 F2FS conflicts successfully."
