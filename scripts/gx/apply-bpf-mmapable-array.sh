#!/usr/bin/env bash
set -euo pipefail

# Android 12's Connectivity/Tethering APEX ships critical BPF maps using
# BPF_F_MMAPABLE (for example netd's blocked_ports_map).  The Velvet 4.14
# baseline has many Android BPF backports but lacks the mmapable-array API,
# so libbpf gets -EINVAL during BPF_MAP_CREATE and netbpfload triggers its
# reboot_on_failure path.
#
# This is a 4.14-compatible adaptation of upstream commit
# fc9702273e2edb90400a34b3be76f7b08fa3344b.  It deliberately omits the
# later map-freeze/writecnt machinery which is not present in this 4.14 tree,
# while preserving the required ABI, VM_USERMAP allocation, VMA lifetime
# references, and array mmap semantics.

python3 <<'PY'
from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if new in s:
        print(f"[bpf-mmap] {label}: already applied")
        return
    if s.count(old) != 1:
        raise SystemExit(f"{path}: {label}: expected block not found exactly once")
    p.write_text(s.replace(old, new, 1))
    print(f"[bpf-mmap] {label}: applied")


# UAPI flag consumed numerically by Android's libbpf/object metadata.
replace_once(
    "include/uapi/linux/bpf.h",
    "#define BPF_F_RDONLY_PROG\\t(1U << 7)\n",
    "#define BPF_F_RDONLY_PROG\\t(1U << 7)\n\n"
    "/* Enable memory-mapping BPF map */\n"
    "#define BPF_F_MMAPABLE\\t\\t(1U << 10)\n",
    "uapi BPF_F_MMAPABLE",
)

# Map operation and allocator declarations.
replace_once(
    "include/linux/bpf.h",
    "struct perf_event;\nstruct bpf_prog;\nstruct bpf_map;\n",
    "struct perf_event;\nstruct bpf_prog;\nstruct bpf_map;\nstruct vm_area_struct;\n",
    "vm_area forward declaration",
)
replace_once(
    "include/linux/bpf.h",
    "\\tu32 (*map_gen_lookup)(struct bpf_map *map, struct bpf_insn *insn_buf);\n"
    "\\tu32 (*map_fd_sys_lookup_elem)(void *ptr);\n"
    "};\n",
    "\\tu32 (*map_gen_lookup)(struct bpf_map *map, struct bpf_insn *insn_buf);\n"
    "\\tu32 (*map_fd_sys_lookup_elem)(void *ptr);\n"
    "\\tint (*map_mmap)(struct bpf_map *map, struct vm_area_struct *vma);\n"
    "};\n",
    "map mmap op",
)
replace_once(
    "include/linux/bpf.h",
    "void *bpf_map_area_alloc(size_t size, int numa_node);\n"
    "void bpf_map_area_free(void *base);\n",
    "void *bpf_map_area_alloc(size_t size, int numa_node);\n"
    "void *bpf_map_area_mmapable_alloc(size_t size, int numa_node);\n"
    "void bpf_map_area_free(void *base);\n",
    "mmapable allocator declaration",
)

# BPF map backing storage: VM_USERMAP is required by remap_vmalloc_range().
replace_once(
    "kernel/bpf/syscall.c",
    "#include <linux/vmalloc.h>\n#include <linux/mmzone.h>\n",
    "#include <linux/vmalloc.h>\n#include <linux/mm.h>\n#include <linux/mmzone.h>\n",
    "mm include",
)
replace_once(
    "kernel/bpf/syscall.c",
    '''void *bpf_map_area_alloc(size_t size, int numa_node)
{
\t/* We definitely need __GFP_NORETRY, so OOM killer doesn't
\t * trigger under memory pressure as we really just want to
\t * fail instead.
\t */
\tconst gfp_t flags = __GFP_NOWARN | __GFP_NORETRY | __GFP_ZERO;
\tvoid *area;

\tif (size <= (PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER)) {
\t\tarea = kmalloc_node(size, GFP_USER | flags, numa_node);
\t\tif (area != NULL)
\t\t\treturn area;
\t}

\treturn __vmalloc_node_flags_caller(size, numa_node, GFP_KERNEL | flags,
\t\t\t\t\t   __builtin_return_address(0));
}
''',
    '''static void *__bpf_map_area_alloc(size_t size, int numa_node, bool mmapable)
{
\t/* We definitely need __GFP_NORETRY, so OOM killer doesn't
\t * trigger under memory pressure as we really just want to
\t * fail instead.
\t */
\tconst gfp_t flags = __GFP_NOWARN | __GFP_NORETRY | __GFP_ZERO;
\tvoid *area;

\tif (!mmapable && size <= (PAGE_SIZE << PAGE_ALLOC_COSTLY_ORDER)) {
\t\tarea = kmalloc_node(size, GFP_USER | flags, numa_node);
\t\tif (area != NULL)
\t\t\treturn area;
\t}

\tif (mmapable)
\t\treturn __vmalloc_node_range(size, PAGE_SIZE, VMALLOC_START, VMALLOC_END,
\t\t\t\tGFP_KERNEL | flags, PAGE_KERNEL, VM_USERMAP,
\t\t\t\tnuma_node, __builtin_return_address(0));

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

replace_once(
    "kernel/bpf/syscall.c",
    '''static ssize_t bpf_dummy_write(struct file *filp, const char __user *buf,
\t\t\t       size_t siz, loff_t *ppos)
{
\t/* We need this handler such that alloc_file() enables
\t * f_mode with FMODE_CAN_WRITE.
\t */
\treturn -EINVAL;
}

const struct file_operations bpf_map_fops = {
''',
    '''static ssize_t bpf_dummy_write(struct file *filp, const char __user *buf,
\t\t\t       size_t siz, loff_t *ppos)
{
\t/* We need this handler such that alloc_file() enables
\t * f_mode with FMODE_CAN_WRITE.
\t */
\treturn -EINVAL;
}

/* vm_ops->open is not called for the initial mmap, only for cloned VMAs. */
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
\t.open\t= bpf_map_mmap_open,
\t.close\t= bpf_map_mmap_close,
};

static int bpf_map_mmap(struct file *filp, struct vm_area_struct *vma)
{
\tstruct bpf_map *map = filp->private_data;
\tstruct bpf_map *map_ref;
\tint err;

\tif (!map->ops->map_mmap)
\t\treturn -ENOTSUPP;

\tif (!(vma->vm_flags & VM_SHARED))
\t\treturn -EINVAL;

\tif ((vma->vm_flags & VM_WRITE) && !(filp->f_mode & FMODE_WRITE))
\t\treturn -EPERM;
\tif ((vma->vm_flags & VM_READ) && !(filp->f_mode & FMODE_READ))
\t\treturn -EPERM;

\tmap_ref = bpf_map_inc(map, true);
\tif (IS_ERR(map_ref))
\t\treturn PTR_ERR(map_ref);

\tvma->vm_ops = &bpf_map_default_vmops;
\terr = map->ops->map_mmap(map, vma);
\tif (err) {
\t\tvma->vm_ops = NULL;
\t\tbpf_map_put_with_uref(map);
\t}

\treturn err;
}

const struct file_operations bpf_map_fops = {
''',
    "BPF map mmap fops",
)
replace_once(
    "kernel/bpf/syscall.c",
    "\\t.release\\t= bpf_map_release,\n\\t.read\\t\\t= bpf_dummy_read,\n\\t.write\\t\\t= bpf_dummy_write,\n};\n",
    "\\t.release\\t= bpf_map_release,\n\\t.read\\t\\t= bpf_dummy_read,\n\\t.write\\t\\t= bpf_dummy_write,\n\\t.mmap\\t\\t= bpf_map_mmap,\n};\n",
    "map fd mmap handler",
)

# Plain ARRAY mmap support.  Per-CPU/fd-array variants remain rejected.
replace_once(
    "kernel/bpf/arraymap.c",
    "#define ARRAY_CREATE_FLAG_MASK \\\\\n\\t(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY)\n",
    "#define ARRAY_CREATE_FLAG_MASK \\\\\n\\t(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY | BPF_F_MMAPABLE)\n",
    "array flag mask",
)
replace_once(
    "kernel/bpf/arraymap.c",
    '''\tif (attr->max_entries == 0 || attr->key_size != 4 ||
\t    attr->value_size == 0 ||
\t    attr->map_flags & ~ARRAY_CREATE_FLAG_MASK ||
\t    (percpu && numa_node != NUMA_NO_NODE))
\t\treturn ERR_PTR(-EINVAL);

\tif (attr->value_size > KMALLOC_MAX_SIZE)
''',
    '''\tif (attr->max_entries == 0 || attr->key_size != 4 ||
\t    attr->value_size == 0 ||
\t    attr->map_flags & ~ARRAY_CREATE_FLAG_MASK ||
\t    (percpu && numa_node != NUMA_NO_NODE))
\t\treturn ERR_PTR(-EINVAL);

\tif (attr->map_type != BPF_MAP_TYPE_ARRAY &&
\t    (attr->map_flags & BPF_F_MMAPABLE))
\t\treturn ERR_PTR(-EINVAL);

\tif (attr->value_size > KMALLOC_MAX_SIZE)
''',
    "mmap only plain array",
)
replace_once(
    "kernel/bpf/arraymap.c",
    '''\tarray_size = sizeof(*array);
\tif (percpu)
\t\tarray_size += (u64) max_entries * sizeof(void *);
\telse
\t\tarray_size += (u64) max_entries * elem_size;

\t/* make sure there is no u32 overflow later in round_up() */
''',
    '''\tarray_size = sizeof(*array);
\tif (percpu) {
\t\tarray_size += (u64) max_entries * sizeof(void *);
\t} else if (attr->map_flags & BPF_F_MMAPABLE) {
\t\t/* Keep array->value exactly page aligned for userspace mmap. */
\t\tarray_size = PAGE_ALIGN(array_size);
\t\tarray_size += PAGE_ALIGN((u64) max_entries * elem_size);
\t} else {
\t\tarray_size += (u64) max_entries * elem_size;
\t}

\t/* make sure there is no u32 overflow later in round_up() */
''',
    "page aligned mmapable array size",
)
replace_once(
    "kernel/bpf/arraymap.c",
    '''\t/* allocate all map elements and zero-initialize them */
\tarray = bpf_map_area_alloc(array_size, numa_node);
\tif (!array)
\t\treturn ERR_PTR(-ENOMEM);
\tarray->index_mask = index_mask;
''',
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
\t\treturn ERR_PTR(-ENOMEM);
\tarray->index_mask = index_mask;
''',
    "vmalloc mmapable arrays",
)
replace_once(
    "kernel/bpf/arraymap.c",
    '''static void array_map_free(struct bpf_map *map)
{
\tstruct bpf_array *array = container_of(map, struct bpf_array, map);

\t/* at this point bpf_prog->aux->refcnt == 0 and this map->refcnt == 0,
\t * so the programs (can be more than one that used this map) were
\t * disconnected from events. Wait for outstanding programs to complete
\t * and free the array
\t */
\tsynchronize_rcu();

\tif (array->map.map_type == BPF_MAP_TYPE_PERCPU_ARRAY)
\t\tbpf_array_free_percpu(array);

\tbpf_map_area_free(array);
}

const struct bpf_map_ops array_map_ops = {
''',
    '''static void *array_map_vmalloc_addr(struct bpf_array *array)
{
\treturn (void *)round_down((unsigned long)array, PAGE_SIZE);
}

static void array_map_free(struct bpf_map *map)
{
\tstruct bpf_array *array = container_of(map, struct bpf_array, map);

\t/* at this point bpf_prog->aux->refcnt == 0 and this map->refcnt == 0,
\t * so the programs (can be more than one that used this map) were
\t * disconnected from events. Wait for outstanding programs to complete
\t * and free the array
\t */
\tsynchronize_rcu();

\tif (array->map.map_type == BPF_MAP_TYPE_PERCPU_ARRAY)
\t\tbpf_array_free_percpu(array);

\tif (map->map_flags & BPF_F_MMAPABLE)
\t\tbpf_map_area_free(array_map_vmalloc_addr(array));
\telse
\t\tbpf_map_area_free(array);
}

static int array_map_mmap(struct bpf_map *map, struct vm_area_struct *vma)
{
\tstruct bpf_array *array = container_of(map, struct bpf_array, map);
\tpgoff_t pgoff = PAGE_ALIGN(sizeof(*array)) >> PAGE_SHIFT;
\tu64 map_size = PAGE_ALIGN((u64)array->map.max_entries * array->elem_size);
\tu64 req_start = (u64)vma->vm_pgoff << PAGE_SHIFT;
\tu64 req_size = vma->vm_end - vma->vm_start;

\tif (!(map->map_flags & BPF_F_MMAPABLE))
\t\treturn -EINVAL;
\tif (req_start > map_size || req_size > map_size - req_start)
\t\treturn -EINVAL;

\treturn remap_vmalloc_range(vma, array_map_vmalloc_addr(array),
\t\t\t\t   vma->vm_pgoff + pgoff);
}

const struct bpf_map_ops array_map_ops = {
''',
    "array mmap/free support",
)
replace_once(
    "kernel/bpf/arraymap.c",
    "\\t.map_delete_elem = array_map_delete_elem,\n\\t.map_gen_lookup = array_map_gen_lookup,\n};\n",
    "\\t.map_delete_elem = array_map_delete_elem,\n\\t.map_gen_lookup = array_map_gen_lookup,\n\\t.map_mmap = array_map_mmap,\n};\n",
    "array mmap op registration",
)

PY

git diff --check -- include/uapi/linux/bpf.h include/linux/bpf.h \
  kernel/bpf/syscall.c kernel/bpf/arraymap.c

echo "[bpf-mmap] Android mmapable BPF array backport ready"
