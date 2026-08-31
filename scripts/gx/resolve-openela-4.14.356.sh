#!/usr/bin/env bash
set -euo pipefail

expected=$'arch/arm64/include/asm/cputype.h\ndrivers/usb/dwc3/core.c\nfs/f2fs/file.c\nfs/f2fs/xattr.c\ninclude/linux/clk.h\nnet/qrtr/qrtr.c\nsecurity/selinux/selinuxfs.c'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.356 resolution: unexpected conflict set." >&2
  echo "Expected:" >&2
  printf '%s\n' "$expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

python3 <<'PY'
from pathlib import Path


def split_conflict(lines, start):
    sep = base = end = None
    i = start + 1
    while i < len(lines):
        line = lines[i]
        if line.startswith('||||||| ') and base is None and sep is None:
            base = i
        elif line.startswith('=======') and sep is None:
            sep = i
        elif line.startswith('>>>>>>> '):
            end = i
            break
        elif line.startswith('<<<<<<< '):
            raise SystemExit('nested merge conflict marker found')
        i += 1
    if sep is None or end is None:
        raise SystemExit('malformed merge conflict block')
    ours_end = base if base is not None else sep
    ours = ''.join(lines[start + 1:ours_end])
    base_text = ''.join(lines[base + 1:sep]) if base is not None else ''
    theirs = ''.join(lines[sep + 1:end])
    return end, ours, base_text, theirs


def resolve(path, expected_count, chooser):
    p = Path(path)
    lines = p.read_text().splitlines(keepends=True)
    out = []
    i = 0
    count = 0
    while i < len(lines):
        if lines[i].startswith('<<<<<<< '):
            end, ours, base, theirs = split_conflict(lines, i)
            count += 1
            out.append(chooser(count, ours, base, theirs))
            i = end + 1
        else:
            out.append(lines[i])
            i += 1
    if count != expected_count:
        raise SystemExit(f'{path}: expected {expected_count} conflicts, found {count}')
    text = ''.join(out)
    if any(marker in text for marker in ('<<<<<<< ', '||||||| ', '>>>>>>> ')):
        raise SystemExit(f'{path}: conflict markers remain')
    p.write_text(text)
    return text


# cputype.h: OpenELA adds Cortex-A715/Neoverse-N3 while Velvet adds Qualcomm
# Kryo IDs. A715 auto-merges; the N3 lines conflict with the adjacent Qualcomm
# additions. Keep both sides of the two additive conflict blocks.
def cputype_choice(n, ours, base, theirs):
    if base.strip():
        raise SystemExit('cputype.h: expected empty base conflict')
    if n == 1:
        for needle in ('ARM_CPU_PART_KRYO3S', 'ARM_CPU_PART_KRYO2XX_SILVER'):
            if needle not in ours:
                raise SystemExit(f'cputype.h conflict 1 missing Velvet {needle}')
        if 'ARM_CPU_PART_NEOVERSE_N3' not in theirs:
            raise SystemExit('cputype.h conflict 1 missing OpenELA N3 part')
    elif n == 2:
        if 'MIDR_KRYO3S' not in ours or 'MIDR_NEOVERSE_N3' not in theirs:
            raise SystemExit('cputype.h conflict 2 does not match reviewed MIDR additions')
    return ours + theirs

cputype = resolve('arch/arm64/include/asm/cputype.h', 2, cputype_choice)
for needle in (
    'ARM_CPU_PART_CORTEX_A715', 'ARM_CPU_PART_NEOVERSE_N3',
    'MIDR_CORTEX_A715', 'MIDR_NEOVERSE_N3',
    'ARM_CPU_PART_KRYO3S', 'MIDR_KRYO3S',
    'ARM_CPU_PART_KRYO2XX_GOLD', 'MIDR_KRYO2XX_GOLD',
):
    if needle not in cputype:
        raise SystemExit(f'cputype.h semantic check failed: {needle}')


# Qualcomm/Velvet replaced the old generic __dwc3_set_mode() with its own
# role/sleep handling. The two conflicts are that vendor implementation versus
# the old generic implementation. Preserve Velvet there, while retaining the
# OpenELA 4.14.356 dis-split property and PM-complete additions that Git merged
# outside the conflict hunks. Miatoll has no snps,dis-split-quirk DT property,
# so do not inject the Hisilicon-specific host-init write into Qualcomm's wrapper.
core = resolve('drivers/usb/dwc3/core.c', 2, lambda n, ours, base, theirs: ours)
for needle in (
    'void dwc3_set_prtcap(struct dwc3 *dwc, u32 mode)',
    'snps,dis-split-quirk',
    'static void dwc3_complete(struct device *dev)',
    '.complete = dwc3_complete,',
    'DWC3_GUCTL3_SPLITDISABLE',
):
    if needle not in core:
        raise SystemExit(f'dwc3/core.c semantic check failed: {needle}')


# Velvet has a much newer F2FS and removed volatile-write implementation.
# Keep its newer code in the sole conflict. The OpenELA FMODE_WRITE checks for
# the three atomic-write ioctls in Velvet auto-merge outside this conflict.
f2fs_file = resolve('fs/f2fs/file.c', 1, lambda n, ours, base, theirs: ours)
for fn in (
    'f2fs_ioc_start_atomic_write',
    'f2fs_ioc_commit_atomic_write',
    'f2fs_ioc_abort_atomic_write',
):
    start = f2fs_file.find(f'static int {fn}(struct file *filp)')
    if start < 0:
        raise SystemExit(f'fs/f2fs/file.c missing {fn}')
    end = f2fs_file.find('\n}\n', start)
    if end < 0:
        raise SystemExit(f'fs/f2fs/file.c cannot bound {fn}')
    body = f2fs_file[start:end]
    if 'if (!(filp->f_mode & FMODE_WRITE))' not in body or 'return -EBADF;' not in body:
        raise SystemExit(f'fs/f2fs/file.c missing OpenELA write guard in {fn}')
if 'F2FS_IOC_START_VOLATILE_WRITE:\n\tcase F2FS_IOC_RELEASE_VOLATILE_WRITE:\n\t\treturn -EOPNOTSUPP;' not in f2fs_file:
    raise SystemExit('fs/f2fs/file.c newer Velvet volatile-write behavior not preserved')


# Velvet already contains OpenELA's NULL-value safety condition, and its newer
# ACL path intentionally jumps to `same:` rather than the old `exit:`.
f2fs_xattr = resolve('fs/f2fs/xattr.c', 1, lambda n, ours, base, theirs: ours)
if 'if (value && f2fs_xattr_value_same(here, value, size))\n\t\t\tgoto same;' not in f2fs_xattr:
    raise SystemExit('fs/f2fs/xattr.c reviewed value/same path not preserved')


# OpenELA adds clk_get_optional() in the same hunk where Velvet intentionally
# widened the OF declarations from OF+COMMON_CLK to OF. Keep the new helper but
# retain the vendor conditional.
def clk_choice(n, ours, base, theirs):
    if n != 1:
        raise SystemExit('include/linux/clk.h unexpected conflict number')
    if ours.strip() != '#if defined(CONFIG_OF)':
        raise SystemExit('include/linux/clk.h Velvet side no longer matches reviewed conditional')
    old = '#if defined(CONFIG_OF) && defined(CONFIG_COMMON_CLK)\n'
    if theirs.count('static inline struct clk *clk_get_optional(') != 1 or theirs.count(old) != 1:
        raise SystemExit('include/linux/clk.h OpenELA side no longer matches reviewed helper hunk')
    return theirs.replace(old, '#if defined(CONFIG_OF)\n', 1)

clk = resolve('include/linux/clk.h', 1, clk_choice)
for needle in (
    'devm_clk_get_prepared', 'devm_clk_get_enabled',
    'devm_clk_get_optional', 'devm_clk_get_optional_prepared',
    'devm_clk_get_optional_enabled', 'static inline struct clk *clk_get_optional(',
    '#if defined(CONFIG_OF)\nstruct clk *of_clk_get(',
):
    if needle not in clk:
        raise SystemExit(f'include/linux/clk.h semantic check failed: {needle}')


# Preserve Velvet's newer QRTR endpoint list/locking/filtering, but take the
# OpenELA safety fix only in the broadcast copy path: clone -> pskb_copy.
def qrtr_choice(n, ours, base, theirs):
    if 'list_for_each_entry(node, &qrtr_all_epts, item)' not in ours:
        raise SystemExit('qrtr conflict no longer contains Velvet endpoint iteration')
    if 'node->nid == QRTR_EP_NID_AUTO' not in ours:
        raise SystemExit('qrtr conflict no longer contains Velvet auto-NID filter')
    old = 'skbn = skb_clone(skb, GFP_KERNEL);'
    if ours.count(old) != 1 or 'skbn = pskb_copy(skb, GFP_KERNEL);' not in theirs:
        raise SystemExit('qrtr conflict no longer matches reviewed skb copy change')
    return ours.replace(old, 'skbn = pskb_copy(skb, GFP_KERNEL);', 1)

qrtr = resolve('net/qrtr/qrtr.c', 1, qrtr_choice)
bcast_start = qrtr.find('static int qrtr_bcast_enqueue(')
bcast_end = qrtr.find('\nstatic int qrtr_sendmsg(', bcast_start)
if bcast_start < 0 or bcast_end < 0:
    raise SystemExit('qrtr broadcast function bounds not found')
bcast = qrtr[bcast_start:bcast_end]
if bcast.count('pskb_copy(skb, GFP_KERNEL)') != 1:
    raise SystemExit('qrtr broadcast path did not retain exactly one pskb_copy')


# OpenELA moves partial/empty/oversize policy validation ahead of allocation
# and locking. Keep that hardening, but use Velvet's per-superblock fsi mutex.
def selinux_choice(n, ours, base, theirs):
    if ours.strip() != 'mutex_lock(&fsi->mutex);':
        raise SystemExit('selinuxfs Velvet side no longer matches reviewed fsi mutex')
    for needle in ('if (*ppos)', 'if (!count)', 'if (count > 64 * 1024 * 1024)'):
        if needle not in theirs:
            raise SystemExit(f'selinuxfs OpenELA side missing reviewed check: {needle}')
    return '''\t/* no partial writes */
\tif (*ppos)
\t\treturn -EINVAL;
\t/* no empty policies */
\tif (!count)
\t\treturn -EINVAL;

\tif (count > 64 * 1024 * 1024)
\t\treturn -EFBIG;

\tmutex_lock(&fsi->mutex);
'''

selinux = resolve('security/selinux/selinuxfs.c', 1, selinux_choice)
for needle in (
    'mutex_lock(&fsi->mutex);',
    'mutex_unlock(&fsi->mutex);',
    'security_load_policy(fsi->state, data, count);',
    'if (!count)\n\t\treturn -EINVAL;',
    'if (count > 64 * 1024 * 1024)\n\t\treturn -EFBIG;',
    'if (!data) {\n\t\tlength = -ENOMEM;',
    'if (copy_from_user(data, buf, count) != 0) {\n\t\tlength = -EFAULT;',
):
    if needle not in selinux:
        raise SystemExit(f'selinuxfs semantic check failed: {needle}')

print('Reviewed OpenELA 4.14.356 conflict semantics applied successfully.')
PY

git add \
  arch/arm64/include/asm/cputype.h \
  drivers/usb/dwc3/core.c \
  fs/f2fs/file.c \
  fs/f2fs/xattr.c \
  include/linux/clk.h \
  net/qrtr/qrtr.c \
  security/selinux/selinuxfs.c

git diff --check --cached

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.356 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.356 conflicts successfully."
