#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
from pathlib import Path
import re


def sub_once(path, pattern, repl, label, flags=re.M | re.S):
    p = Path(path)
    s = p.read_text()
    ns, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"{path}: {label}: expected one match, got {n}")
    p.write_text(ns)
    print(f"[bpf-mmap] {label}: applied")


def insert_after(path, pattern, text, present, label):
    p = Path(path)
    s = p.read_text()
    if present in s:
        print(f"[bpf-mmap] {label}: already applied")
        return
    m = re.search(pattern, s, flags=re.M)
    if not m:
        raise SystemExit(f"{path}: {label}: anchor not found")
    p.write_text(s[:m.end()] + text + s[m.end():])
    print(f"[bpf-mmap] {label}: applied")


# UAPI bit used by Android's Connectivity APEX BPF map metadata.
insert_after(
    "include/uapi/linux/bpf.h",
    r'^#define\s+BPF_F_RDONLY_PROG\s+\(1U\s*<<\s*7\)\s*$',
    "\n\n/* Enable memory-mapping BPF map */\n#define BPF_F_MMAPABLE\t\t(1U << 10)",
    "BPF_F_MMAPABLE",
    "uapi BPF_F_MMAPABLE",
)

# Map operation and allocator declarations.
insert_after(
    "include/linux/bpf.h",
    r'^struct bpf_map;$',
    "\nstruct vm_area_struct;",
    "struct vm_area_struct;",
    "vm_area forward declaration",
)
insert_after(
    "include/linux/bpf.h",
    r'^\s*u32 \(\*map_fd_sys_lookup_elem\)\(void \*ptr\);$',
    "\n\tint (*map_mmap)(struct bpf_map *map, struct vm_area_struct *vma);",
    "int (*map_mmap)(struct bpf_map *map, struct vm_area_struct *vma);",
    "map mmap op",
)
insert_after(
    "include/linux/bpf.h",
    r'^void \*bpf_map_area_alloc\(size_t size, int numa_node\);$',
    "\nvoid *bpf_map_area_mmapable_alloc(size_t size, int numa_node);",
    "bpf_map_area_mmapable_alloc",
    "mmapable allocator declaration",
)

# syscall.c needs VMA definitions.
insert_after(
    "kernel/bpf/syscall.c",
    r'^#include <linux/vmalloc\.h>$',
    "\n#include <linux/mm.h>",
    "#include <linux/mm.h>",
    "mm include",
)

# Keep the old allocator for ordinary maps and force mmapable maps into
# VM_USERMAP vmalloc backing. __vmalloc_node_range exists in this 4.14 tree.
sub_once(
    "kernel/bpf/syscall.c",
    r'void \*bpf_map_area_alloc\(size_t size, int numa_node\)\n\{.*?\n\}\n(?=\nvoid bpf_map_area_free)',
    '''static void *__bpf_map_area_alloc(size_t size, int numa_node, bool mmapable)
{
\tconst gfp_t flags = __GFP_NOWARN | __GFP_NORETRY | __GFP_ZERO;
\tvoid *area;

\tif (!mmapable && size <= (PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER)) {
\t\tarea = kmalloc_node(size, GFP_USER | flags, numa_node);
\t\tif (area != NULL)
\t\t\treturn area;
\t}

\tif (mmapable) {
\t\tBUG_ON(!PAGE_ALIGNED(size));
\t\treturn __vmalloc_node_range(size, PAGE_SIZE,
\t\t\t\tVMALLOC_START, VMALLOC_END,
\t\t\t\tGFP_KERNEL | flags, PAGE_KERNEL,
\t\t\t\tVM_USERMAP, numa_node,
\t\t\t\t__builtin_return_address(0));
\t}

\treturn __vmalloc_node_flags_caller(size, numa_node, GFP_KERNEL | flags,
\t\t\t\t\t   __builtin_return_address(0));
}

void *bpf_map_area_alloc(size_t size, int numa_node)
{
\treturn __bpf_map_area_alloc(size, numa_node, false);
}

void *bpf_map_area_mmapable_alloc(size_t size, int numa_node)
{
\treturn __bpf_map_area_alloc(size, numa_node, true);
}
''',
    "mmapable BPF allocation",
)

# Map-fd mmap support. The initial mmap must take one user ref; vm_ops.open
# accounts for subsequent VMA clones and close drops every VMA ref.
insert_after(
    "kernel/bpf/syscall.c",
    r'static ssize_t bpf_dummy_write\(struct file \*filp, const char __user \*buf,\n.*?^\}$',
    '''

static void bpf_map_mmap_open(struct vm_area_struct *vma)
{
\tstruct bpf_map *map = vma->vm_file->private_data;

\tWARN_ON_ONCE(IS_ERR(bpf_map_inc(map, true)));
}

static void bpf_map_mmap_close(struct vm_area_struct *vma)
{
\tstruct bpf_map *map = vma->vm_file->private_data;

\tbpf_map_put_with_uref(map);
}

static const struct vm_operations_struct bpf_map_default_vmops = {
\t.open = bpf_map_mmap_open,
\t.close = bpf_map_mmap_close,
};

static int bpf_map_mmap(struct file *filp, struct vm_area_struct *vma)
{
\tstruct bpf_map *map = filp->private_data;
\tstruct bpf_map *ref;
\tint err;

\tif (!map->ops->map_mmap)
\t\treturn -ENOTSUPP;
\tif (!(vma->vm_flags & VM_SHARED))
\t\treturn -EINVAL;
\tif ((vma->vm_flags & VM_WRITE) && !(filp->f_mode & FMODE_WRITE))
\t\treturn -EPERM;
\tif ((vma->vm_flags & VM_READ) && !(filp->f_mode & FMODE_READ))
\t\treturn -EPERM;

\tref = bpf_map_inc(map, true);
\tif (IS_ERR(ref))
\t\treturn PTR_ERR(ref);

\tvma->vm_ops = &bpf_map_default_vmops;
\terr = map->ops->map_mmap(map, vma);
\tif (err) {
\t\tvma->vm_ops = NULL;
\t\tbpf_map_put_with_uref(map);
\t}
\treturn err;
}
''',
    "static int bpf_map_mmap(struct file *filp",
    "BPF map mmap implementation",
)

# Add mmap only to bpf_map_fops, not bpf_prog_fops.
sub_once(
    "kernel/bpf/syscall.c",
    r'(const struct file_operations bpf_map_fops = \{.*?\n\s*\.write\s*=\s*bpf_dummy_write,)(\n\};)',
    r'\1\n\t.mmap\t\t= bpf_map_mmap,\2',
    "map fd mmap handler",
)

# Plain ARRAY maps accept BPF_F_MMAPABLE. Other array-derived map types do not.
sub_once(
    "kernel/bpf/arraymap.c",
    r'#define ARRAY_CREATE_FLAG_MASK \\\n\s*\(BPF_F_NUMA_NODE \| BPF_F_RDONLY \| BPF_F_WRONLY\)',
    '#define ARRAY_CREATE_FLAG_MASK \\\n\t(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY | BPF_F_MMAPABLE)',
    "array flag mask",
)

insert_after(
    "kernel/bpf/arraymap.c",
    r'^\s*\(percpu && numa_node != NUMA_NO_NODE\)\)\n\s*return ERR_PTR\(-EINVAL\);$',
    '''

\tif (attr->map_type != BPF_MAP_TYPE_ARRAY &&
\t    (attr->map_flags & BPF_F_MMAPABLE))
\t\treturn ERR_PTR(-EINVAL);''',
    "attr->map_type != BPF_MAP_TYPE_ARRAY &&",
    "mmap only plain array",
)

sub_once(
    "kernel/bpf/arraymap.c",
    r'\tarray_size = sizeof\(\*array\);\n\tif \(percpu\)\n\t\tarray_size \+= \(u64\) max_entries \* sizeof\(void \*\);\n\telse\n\t\tarray_size \+= \(u64\) max_entries \* elem_size;',
    '''\tarray_size = sizeof(*array);
\tif (percpu) {
\t\tarray_size += (u64) max_entries * sizeof(void *);
\t} else if (attr->map_flags & BPF_F_MMAPABLE) {
\t\t/* vmalloc is page-aligned; make array->value start on page 2 */
\t\tarray_size = PAGE_ALIGN(array_size);
\t\tarray_size += PAGE_ALIGN((u64) max_entries * elem_size);
\t} else {
\t\tarray_size += (u64) max_entries * elem_size;
\t}''',
    "page aligned mmapable array size",
)

sub_once(
    "kernel/bpf/arraymap.c",
    r'\t/\* allocate all map elements and zero-initialize them \*/\n\tarray = bpf_map_area_alloc\(array_size, numa_node\);\n\tif \(!array\)\n\t\treturn ERR_PTR\(-ENOMEM\);',
    '''\t/* allocate all map elements and zero-initialize them */
\tif (attr->map_flags & BPF_F_MMAPABLE) {
\t\tvoid *data;

\t\tdata = bpf_map_area_mmapable_alloc(array_size, numa_node);
\t\tif (!data)
\t\t\treturn ERR_PTR(-ENOMEM);
\t\tarray = data + PAGE_ALIGN(sizeof(struct bpf_array))
\t\t\t- offsetof(struct bpf_array, value);
\t} else {
\t\tarray = bpf_map_area_alloc(array_size, numa_node);
\t}
\tif (!array)
\t\treturn ERR_PTR(-ENOMEM);''',
    "vmalloc mmapable arrays",
)

# Replace only the plain array free routine and add mmap implementation before
# array_map_ops. fd-array/percpu paths remain unchanged.
sub_once(
    "kernel/bpf/arraymap.c",
    r'/\* Called when map->refcnt goes to zero, either from workqueue or from syscall \*/\nstatic void array_map_free\(struct bpf_map \*map\)\n\{.*?\n\}\n\n(?=const struct bpf_map_ops array_map_ops)',
    '''static void *array_map_vmalloc_addr(struct bpf_array *array)
{
\treturn (void *)round_down((unsigned long)array, PAGE_SIZE);
}

/* Called when map->refcnt goes to zero, either from workqueue or from syscall */
static void array_map_free(struct bpf_map *map)
{
\tstruct bpf_array *array = container_of(map, struct bpf_array, map);

\tsynchronize_rcu();

\tif (array->map.map_type == BPF_MAP_TYPE_PERCPU_ARRAY)
\t\tbpf_array_free_percpu(array);

\tif (array->map.map_flags & BPF_F_MMAPABLE)
\t\tbpf_map_area_free(array_map_vmalloc_addr(array));
\telse
\t\tbpf_map_area_free(array);
}

static int array_map_mmap(struct bpf_map *map, struct vm_area_struct *vma)
{
\tstruct bpf_array *array = container_of(map, struct bpf_array, map);
\tpgoff_t pgoff = PAGE_ALIGN(sizeof(*array)) >> PAGE_SHIFT;
\tu64 data_size = PAGE_ALIGN((u64)array->map.max_entries * array->elem_size);
\tu64 req_off = (u64)vma->vm_pgoff << PAGE_SHIFT;
\tu64 req_size = vma->vm_end - vma->vm_start;

\tif (!(map->map_flags & BPF_F_MMAPABLE))
\t\treturn -EINVAL;
\tif (req_off > data_size || req_size > data_size - req_off)
\t\treturn -EINVAL;

\treturn remap_vmalloc_range(vma, array_map_vmalloc_addr(array),
\t\t\t\t   vma->vm_pgoff + pgoff);
}

''',
    "array mmap/free support",
)

sub_once(
    "kernel/bpf/arraymap.c",
    r'(const struct bpf_map_ops array_map_ops = \{.*?\n\s*\.map_gen_lookup\s*=\s*array_map_gen_lookup,)(\n\};)',
    r'\1\n\t.map_mmap = array_map_mmap,\2',
    "array mmap op registration",
)

PY

git diff --check -- include/uapi/linux/bpf.h include/linux/bpf.h \
  kernel/bpf/syscall.c kernel/bpf/arraymap.c

grep -q 'BPF_F_MMAPABLE' include/uapi/linux/bpf.h
grep -q 'map_mmap = array_map_mmap' kernel/bpf/arraymap.c
grep -q '\.mmap.*bpf_map_mmap' kernel/bpf/syscall.c

echo '[bpf-mmap] Android 12 mmapable ARRAY backport ready'
