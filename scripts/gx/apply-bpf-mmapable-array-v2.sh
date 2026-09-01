#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re


def patch(path, pattern, repl, label, flags=re.M):
    p = Path(path)
    s = p.read_text()
    ns, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f'{path}: {label}: anchor not found')
    p.write_text(ns)
    print(f'[bpf-mmap] {label}: applied')

# UAPI flag used by Android Connectivity netd.o blocked_ports_map.
p = Path('include/uapi/linux/bpf.h')
s = p.read_text()
if 'BPF_F_MMAPABLE' not in s:
    s, n = re.subn(
        r'(?P<line>^\s*BPF_F_RDONLY_PROG\s*=\s*\(1U\s*<<\s*7\),\s*$)',
        r'\g<line>\n\tBPF_F_MMAPABLE\t\t= (1U << 10),',
        s, count=1, flags=re.M)
    if n != 1:
        raise SystemExit('include/uapi/linux/bpf.h: BPF_F_MMAPABLE anchor not found')
    p.write_text(s)
    print('[bpf-mmap] uapi BPF_F_MMAPABLE: applied')
else:
    print('[bpf-mmap] uapi BPF_F_MMAPABLE: already present')

# Forward declaration for map mmap operation.
p = Path('include/linux/bpf.h')
s = p.read_text()
if 'struct vm_area_struct;' not in s:
    s, n = re.subn(r'(?m)^(struct bpf_map;\s*)$', r'\1\nstruct vm_area_struct;', s, count=1)
    if n != 1:
        raise SystemExit('include/linux/bpf.h: vm_area forward declaration anchor not found')
    p.write_text(s)
    print('[bpf-mmap] vm_area forward declaration: applied')
else:
    print('[bpf-mmap] vm_area forward declaration: already present')

# map->ops mmap callback.
p = Path('include/linux/bpf.h')
s = p.read_text()
if 'int (*map_mmap)(struct bpf_map *map, struct vm_area_struct *vma);' not in s:
    s, n = re.subn(
        r'(?m)^(\s*void \(\*map_release_uref\)\(struct bpf_map \*map\);\s*)$',
        r'\1\n\tint (*map_mmap)(struct bpf_map *map, struct vm_area_struct *vma);',
        s, count=1)
    if n != 1:
        raise SystemExit('include/linux/bpf.h: map mmap op anchor not found')
    p.write_text(s)
    print('[bpf-mmap] map mmap op: applied')
else:
    print('[bpf-mmap] map mmap op: already present')

# mmapable allocator declaration.
p = Path('include/linux/bpf.h')
s = p.read_text()
if 'bpf_map_area_mmapable_alloc' not in s:
    s, n = re.subn(
        r'(?m)^(void \*bpf_map_area_alloc\(size_t size, int numa_node\);\s*)$',
        r'\1\nvoid *bpf_map_area_mmapable_alloc(size_t size, int numa_node);',
        s, count=1)
    if n != 1:
        raise SystemExit('include/linux/bpf.h: mmapable allocator declaration anchor not found')
    p.write_text(s)
    print('[bpf-mmap] mmapable allocator declaration: applied')
else:
    print('[bpf-mmap] mmapable allocator declaration: already present')

# syscall.c: mm include and mmapable vmalloc helper.
p = Path('kernel/bpf/syscall.c')
s = p.read_text()
if '#include <linux/mm.h>' not in s:
    s, n = re.subn(r'(?m)^(#include <linux/memcontrol.h>\s*)$', r'\1\n#include <linux/mm.h>', s, count=1)
    if n != 1:
        raise SystemExit('kernel/bpf/syscall.c: mm include anchor not found')
    p.write_text(s)
    print('[bpf-mmap] mm include: applied')
else:
    print('[bpf-mmap] mm include: already present')

p = Path('kernel/bpf/syscall.c')
s = p.read_text()
if 'void *bpf_map_area_mmapable_alloc' not in s:
    pat = r'(void \*bpf_map_area_alloc\(size_t size, int numa_node\)\s*\{.*?^\})'
    m = re.search(pat, s, flags=re.M | re.S)
    if not m:
        raise SystemExit('kernel/bpf/syscall.c: bpf_map_area_alloc function not found')
    extra = r'''

void *bpf_map_area_mmapable_alloc(size_t size, int numa_node)
{
	/* vmalloc backing is page aligned and remap_vmalloc_range() can expose it
	 * through a BPF map fd. Keep the 4.14 accounting/NUMA behavior identical
	 * to bpf_map_area_alloc() where possible.
	 */
	const gfp_t flags = GFP_KERNEL | __GFP_NOWARN | __GFP_ZERO;
	void *area;

	if (size <= (PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER)) {
		area = kmalloc_node(size, flags | __GFP_NORETRY, numa_node);
		if (area != NULL)
			return area;
	}

	return __vmalloc_node_flags_caller(size, numa_node,
					 flags | __GFP_HIGHMEM,
					 __builtin_return_address(0));
}
'''
    s = s[:m.end()] + extra + s[m.end():]
    p.write_text(s)
    print('[bpf-mmap] mmapable BPF allocation: applied')
else:
    print('[bpf-mmap] mmapable BPF allocation: already present')

# syscall.c map fd mmap path. Android only needs array-map fd mmap here.
p = Path('kernel/bpf/syscall.c')
s = p.read_text()
if 'static int bpf_map_mmap(struct file *filp, struct vm_area_struct *vma)' not in s:
    anchor = re.search(r'static ssize_t bpf_dummy_write\(struct file \*filp, const char __user \*buf,\s*size_t siz, loff_t \*ppos\)\s*\{.*?^\}', s, flags=re.M | re.S)
    if not anchor:
        raise SystemExit('kernel/bpf/syscall.c: BPF map mmap implementation: anchor not found')
    extra = r'''

static void bpf_map_mmap_open(struct vm_area_struct *vma)
{
	struct bpf_map *map = vma->vm_file->private_data;

	bpf_map_inc(map, false);
}

static void bpf_map_mmap_close(struct vm_area_struct *vma)
{
	struct bpf_map *map = vma->vm_file->private_data;

	bpf_map_put(map);
}

static const struct vm_operations_struct bpf_map_default_vmops = {
	.open = bpf_map_mmap_open,
	.close = bpf_map_mmap_close,
};

static int bpf_map_mmap(struct file *filp, struct vm_area_struct *vma)
{
	struct bpf_map *map = filp->private_data;
	int err;

	if (!map->ops->map_mmap)
		return -ENOTSUPP;

	if (vma->vm_pgoff)
		return -EINVAL;

	if ((vma->vm_flags & VM_WRITE) && !(vma->vm_flags & VM_SHARED))
		return -EINVAL;

	err = map->ops->map_mmap(map, vma);
	if (err)
		return err;

	vma->vm_ops = &bpf_map_default_vmops;
	bpf_map_inc(map, false);
	return 0;
}
'''
    s = s[:anchor.start()] + extra + '\n' + s[anchor.start():]
    p.write_text(s)
    print('[bpf-mmap] BPF map mmap implementation: applied')
else:
    print('[bpf-mmap] BPF map mmap implementation: already present')

# Add mmap to bpf_map_fops.
p = Path('kernel/bpf/syscall.c')
s = p.read_text()
if re.search(r'static const struct file_operations bpf_map_fops\s*=\s*\{[^}]*\.mmap\s*=\s*bpf_map_mmap', s, flags=re.S) is None:
    s, n = re.subn(
        r'(static const struct file_operations bpf_map_fops\s*=\s*\{.*?)(\n\};)',
        lambda m: m.group(1) + '\n\t.mmap\t\t= bpf_map_mmap,' + m.group(2),
        s, count=1, flags=re.M | re.S)
    if n != 1:
        raise SystemExit('kernel/bpf/syscall.c: bpf_map_fops anchor not found')
    p.write_text(s)
    print('[bpf-mmap] bpf_map_fops mmap: applied')
else:
    print('[bpf-mmap] bpf_map_fops mmap: already present')

# arraymap: permit only Android-compatible flags and page-align mmap storage.
p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
if '#include <linux/mm.h>' not in s:
    s, n = re.subn(r'(?m)^(#include <linux/filter.h>\s*)$', r'\1\n#include <linux/mm.h>', s, count=1)
    if n != 1:
        raise SystemExit('kernel/bpf/arraymap.c: mm include anchor not found')
    p.write_text(s)
    print('[bpf-mmap] arraymap mm include: applied')
else:
    print('[bpf-mmap] arraymap mm include: already present')

p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
old = r'if \(attr->map_flags & ~\(BPF_F_NUMA_NODE \| BPF_F_RDONLY \| BPF_F_WRONLY\)\)'
new = r'if (attr->map_flags & ~(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY |\n\t\t\t       BPF_F_MMAPABLE))'
if re.search(old, s):
    s = re.sub(old, new, s, count=1)
    p.write_text(s)
    print('[bpf-mmap] array allowed flags: applied')
elif 'BPF_F_MMAPABLE' in s:
    print('[bpf-mmap] array allowed flags: already present')
else:
    raise SystemExit('kernel/bpf/arraymap.c: array allowed flags anchor not found')

# Reject unsupported percpu mmap and calculate normal arrays with page rounding.
p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
if 'percpu && (attr->map_flags & BPF_F_MMAPABLE)' not in s:
    s, n = re.subn(
        r'(?m)^(\s*bool percpu = map_type == BPF_MAP_TYPE_PERCPU_ARRAY;\s*)$',
        r'\1\n\n\tif (percpu && (attr->map_flags & BPF_F_MMAPABLE))\n\t\treturn ERR_PTR(-EINVAL);',
        s, count=1)
    if n != 1:
        raise SystemExit('kernel/bpf/arraymap.c: percpu mmap reject anchor not found')
    p.write_text(s)
    print('[bpf-mmap] percpu mmap rejection: applied')
else:
    print('[bpf-mmap] percpu mmap rejection: already present')

p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
if 'if (attr->map_flags & BPF_F_MMAPABLE)' not in s[s.find('static struct bpf_map *array_map_alloc'):s.find('static void array_map_free')]:
    s, n = re.subn(
        r'(array_size = sizeof\(\*array\) \+ array->map.max_entries \* elem_size;)',
        r'\1\n\tif (attr->map_flags & BPF_F_MMAPABLE)\n\t\tarray_size = PAGE_ALIGN(array_size);',
        s, count=1)
    if n != 1:
        raise SystemExit('kernel/bpf/arraymap.c: array size anchor not found')
    p.write_text(s)
    print('[bpf-mmap] mmap array size alignment: applied')
else:
    print('[bpf-mmap] mmap array size alignment: already present')

# Use mmapable allocator for mmap arrays.
p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
needle = 'array = bpf_map_area_alloc(array_size, numa_node);'
if needle in s:
    s = s.replace(needle,
'''if (attr->map_flags & BPF_F_MMAPABLE)
		array = bpf_map_area_mmapable_alloc(array_size, numa_node);
	else
		array = bpf_map_area_alloc(array_size, numa_node);''', 1)
    p.write_text(s)
    print('[bpf-mmap] mmap array allocator selection: applied')
elif 'bpf_map_area_mmapable_alloc(array_size, numa_node)' in s:
    print('[bpf-mmap] mmap array allocator selection: already present')
else:
    raise SystemExit('kernel/bpf/arraymap.c: allocator selection anchor not found')

# Array mmap op. We map only array->value through offset=offsetof(struct bpf_array, value).
p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
if 'static int array_map_mmap(struct bpf_map *map, struct vm_area_struct *vma)' not in s:
    anchor = re.search(r'(?m)^static void array_map_free\(struct bpf_map \*map\)\s*\{', s)
    if not anchor:
        raise SystemExit('kernel/bpf/arraymap.c: array mmap op insertion anchor not found')
    extra = r'''static int array_map_mmap(struct bpf_map *map, struct vm_area_struct *vma)
{
	struct bpf_array *array = container_of(map, struct bpf_array, map);
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long data_size = PAGE_ALIGN((unsigned long)map->max_entries *
					      array->elem_size);
	unsigned long pgoff = PAGE_ALIGN(offsetof(struct bpf_array, value)) >> PAGE_SHIFT;

	if (!(map->map_flags & BPF_F_MMAPABLE))
		return -EINVAL;
	if (size > data_size)
		return -EINVAL;

	return remap_vmalloc_range(vma, array, pgoff);
}

'''
    s = s[:anchor.start()] + extra + s[anchor.start():]
    p.write_text(s)
    print('[bpf-mmap] array mmap op: applied')
else:
    print('[bpf-mmap] array mmap op: already present')

# Register mmap on both array ops tables if present.
p = Path('kernel/bpf/arraymap.c')
s = p.read_text()
for ops_name in ('array_map_ops',):
    m = re.search(rf'(const struct bpf_map_ops {ops_name}\s*=\s*\{{)(.*?)(\n\}};)', s, flags=re.S)
    if not m:
        continue
    body = m.group(2)
    if '.map_mmap' in body:
        print(f'[bpf-mmap] {ops_name} mmap registration: already present')
        continue
    body += '\n\t.map_mmap = array_map_mmap,'
    s = s[:m.start()] + m.group(1) + body + m.group(3) + s[m.end():]
    print(f'[bpf-mmap] {ops_name} mmap registration: applied')
p.write_text(s)

print('[bpf-mmap] Android mmapable array backport complete')
PY
