#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock
# shellcheck disable=SC1091
source .gx-variant

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"
KSUN_DIR="$ROOT_DIR/KernelSU-Next"

rm -rf "$KSUN_DIR" drivers/kernelsu

if [[ "${GX_SUSFS:-0}" == "1" ]]; then
  KSU_REPO="$KSUN_SUSFS_REPO"
  KSU_COMMIT="$KSUN_SUSFS_COMMIT"
  echo "[GXT] integrating KernelSU-Next SUSFS-v2 compatibility tree @ $KSU_COMMIT"
else
  # N45 is Linux 4.14. Use KernelSU-Next's own legacy/manual-hook branch.
  # Do not force the stable v3.3.0 KPROBES path onto this old vendor kernel.
  KSU_REPO="$KSUN_REPO"
  KSU_COMMIT="$KSUN_LEGACY_COMMIT"
  echo "[GXT] integrating official KernelSU-Next ${KSUN_LEGACY_BRANCH} manual-hook tree @ $KSU_COMMIT"
fi

git clone -q "$KSU_REPO" "$KSUN_DIR"
git -C "$KSUN_DIR" checkout -q "$KSU_COMMIT"
actual="$(git -C "$KSUN_DIR" rev-parse HEAD)"
if [[ "$actual" != "$KSU_COMMIT" ]]; then
  echo "KSUN pin mismatch: expected $KSU_COMMIT got $actual" >&2
  exit 4
fi

# KernelSU-Next legacy's SELinux hide code stores page_address(fake_page) in
# file->private_data. N45 Linux 4.14 selinuxfs expects a struct page * there and
# calls page_address() later in sel_read_handle_status/sel_mmap_handle_status.
# Patch only the no-SUSFS official legacy lane to match this kernel ABI.
if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  python3 scripts/gx/fix-ksun-legacy-selinux-status.py
  grep -Fq 'filp->private_data = data;' "$KSUN_DIR/kernel/feature/selinux_hide.c"
  if grep -Fq 'filp->private_data = page_address(data);' "$KSUN_DIR/kernel/feature/selinux_hide.c"; then
    echo "[N45][KSUN-legacy] stale SELinux status fake-page ABI remains" >&2
    exit 5
  fi

  # Official legacy runs kernel_umount from the zygote setresuid path. Keep the
  # unmount/hiding behavior, but do not emit KERN_INFO messages for every app
  # spawn, every module mount, or repeated namespace miss. On module-heavy
  # systems that printk traffic sits directly on the app-launch path.
  python3 - "$KSUN_DIR/kernel/feature/kernel_umount.c" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
replacements = (
    ('pr_info("umount %s failed: %d\\n", mnt, err);',
     'pr_debug("umount %s failed: %d\\n", mnt, err);'),
    ('pr_info("%s: unmounting: %s flags: 0x%x\\n", __func__, entry->umountable, entry->flags);',
     'pr_debug("%s: unmounting: %s flags: 0x%x\\n", __func__, entry->umountable, entry->flags);'),
    ('pr_info("handle umount ignore non zygote child: %d\\n", current->pid);',
     'pr_debug("handle umount ignore non zygote child: %d\\n", current->pid);'),
    ('pr_info("handle umount for uid: %d, pid: %d\\n", new_uid, current->pid);',
     'pr_debug("handle umount for uid: %d, pid: %d\\n", new_uid, current->pid);'),
)
for old, new in replacements:
    if old not in s:
        raise SystemExit(f"kernel_umount log anchor missing: {old}")
    s = s.replace(old, new, 1)
p.write_text(s)
print("[N45][KSUN-legacy] quieted kernel_umount app-spawn hot-path logging")
PY
  grep -Fq 'pr_debug("handle umount for uid:' "$KSUN_DIR/kernel/feature/kernel_umount.c"
  grep -Fq 'pr_debug("%s: unmounting:' "$KSUN_DIR/kernel/feature/kernel_umount.c"

  # The pinned legacy allowlist does an O(n) RCU list walk in
  # ksu_get_app_profile(), and ksu_uid_should_umount() calls it from the zygote
  # app-spawn path. Keep the legacy list for ABI/persistence ordering, but add a
  # secondary UID hash index so hot-path profile lookup only scans one bucket.
  # This mirrors the direction of upstream's newer hash-table allowlist without
  # importing its much larger current_uid/curr_uid ABI refactor.
  python3 - "$KSUN_DIR/kernel/policy/allowlist.c" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global s
    if old not in s:
        raise SystemExit(f"allowlist hash patch anchor missing ({label})")
    s = s.replace(old, new, 1)

replace_once(
    '#include <linux/list.h>\n',
    '#include <linux/list.h>\n#include <linux/hashtable.h>\n',
    'hashtable include',
)

replace_once(
    'struct perm_data {\n'
    '    struct list_head list;\n'
    '    struct rcu_head rcu;\n'
    '    struct app_profile profile;\n'
    '};\n',
    'struct perm_data {\n'
    '    struct list_head list;\n'
    '    struct hlist_node uid_hash;\n'
    '    struct rcu_head rcu;\n'
    '    struct app_profile profile;\n'
    '};\n',
    'perm_data hash node',
)

replace_once(
    'static struct list_head allow_list;\n\n',
    'static struct list_head allow_list;\n\n'
    '#define ALLOW_LIST_UID_HASH_BITS 8\n'
    'static DEFINE_HASHTABLE(allow_list_uid_hash, ALLOW_LIST_UID_HASH_BITS);\n\n'
    'static inline void allow_list_uid_hash_add(struct perm_data *p)\n'
    '{\n'
    '    unsigned long bucket =\n'
    '        hash_min(p->profile.current_uid, HASH_BITS(allow_list_uid_hash));\n'
    '    hlist_add_tail_rcu(&p->uid_hash, &allow_list_uid_hash[bucket]);\n'
    '}\n\n',
    'UID hash table',
)

replace_once(
    'bool ksu_get_app_profile(struct app_profile *profile)\n'
    '{\n'
    '    struct perm_data *p = NULL;\n'
    '    bool found = false;\n\n'
    '    rcu_read_lock();\n'
    '    list_for_each_entry_rcu (p, &allow_list, list) {\n'
    '        bool uid_match = profile->current_uid == p->profile.current_uid;\n'
    '        if (uid_match) {\n'
    '            // found it, override it with ours\n'
    '            memcpy(profile, &p->profile, sizeof(*profile));\n'
    '            found = true;\n'
    '            goto exit;\n'
    '        }\n'
    '    }\n\n'
    'exit:\n'
    '    rcu_read_unlock();\n'
    '    return found;\n'
    '}\n',
    'bool ksu_get_app_profile(struct app_profile *profile)\n'
    '{\n'
    '    struct perm_data *p = NULL;\n'
    '    bool found = false;\n'
    '    uid_t uid = profile->current_uid;\n\n'
    '    rcu_read_lock();\n'
    '    hash_for_each_possible_rcu(allow_list_uid_hash, p, uid_hash, uid) {\n'
    '        if (uid == p->profile.current_uid) {\n'
    '            // found it, override it with ours\n'
    '            memcpy(profile, &p->profile, sizeof(*profile));\n'
    '            found = true;\n'
    '            break;\n'
    '        }\n'
    '    }\n'
    '    rcu_read_unlock();\n'
    '    return found;\n'
    '}\n',
    'hot-path profile lookup',
)

replace_once(
    '            memcpy(&np->profile, profile, sizeof(*profile));\n'
    '            list_replace_rcu(&p->list, &np->list);\n'
    '            kfree_rcu(p, rcu);\n',
    '            memcpy(&np->profile, profile, sizeof(*profile));\n'
    '            list_replace_rcu(&p->list, &np->list);\n'
    '            hlist_replace_rcu(&p->uid_hash, &np->uid_hash);\n'
    '            kfree_rcu(p, rcu);\n',
    'profile replacement index',
)

replace_once(
    '    list_add_tail_rcu(&p->list, &allow_list);\n',
    '    list_add_tail_rcu(&p->list, &allow_list);\n'
    '    allow_list_uid_hash_add(p);\n',
    'profile insertion index',
)

replace_once(
    '            list_del_rcu(&np->list);\n'
    '            kfree_rcu(np, rcu);\n',
    '            hlist_del_rcu(&np->uid_hash);\n'
    '            list_del_rcu(&np->list);\n'
    '            kfree_rcu(np, rcu);\n',
    'prune index removal',
)

replace_once(
    '\tINIT_LIST_HEAD(&allow_list);\n',
    '\tINIT_LIST_HEAD(&allow_list);\n'
    '\thash_init(allow_list_uid_hash);\n',
    'hash init',
)

replace_once(
    '\tlist_for_each_entry_safe (np, n, &allow_list, list) {\n'
    '\t\tlist_del(&np->list);\n'
    '\t\tkfree(np);\n'
    '\t}\n',
    '\tlist_for_each_entry_safe (np, n, &allow_list, list) {\n'
    '\t\thlist_del(&np->uid_hash);\n'
    '\t\tlist_del(&np->list);\n'
    '\t\tkfree(np);\n'
    '\t}\n',
    'exit index removal',
)

required = (
    '#include <linux/hashtable.h>',
    'DEFINE_HASHTABLE(allow_list_uid_hash, ALLOW_LIST_UID_HASH_BITS)',
    'hash_for_each_possible_rcu(allow_list_uid_hash, p, uid_hash, uid)',
    'hlist_replace_rcu(&p->uid_hash, &np->uid_hash)',
    'hlist_del_rcu(&np->uid_hash)',
    'hash_init(allow_list_uid_hash)',
)
for marker in required:
    if marker not in s:
        raise SystemExit(f"allowlist hash patch verification failed: {marker}")

p.write_text(s)
print("[N45][KSUN-legacy] added RCU UID hash index for app-profile lookup")
PY
  grep -Fq 'DEFINE_HASHTABLE(allow_list_uid_hash' "$KSUN_DIR/kernel/policy/allowlist.c"
  grep -Fq 'hash_for_each_possible_rcu(allow_list_uid_hash' "$KSUN_DIR/kernel/policy/allowlist.c"
  grep -Fq 'hlist_replace_rcu(&p->uid_hash, &np->uid_hash)' "$KSUN_DIR/kernel/policy/allowlist.c"
fi

ln -s "../KernelSU-Next/kernel" drivers/kernelsu
if ! grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

python3 - "$DEFCONFIG" "${GX_SUSFS:-0}" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); susfs = sys.argv[2] == '1'; s = p.read_text()

def set_cfg(key, value):
    global s
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}={value}' if value != 'n' else f'# CONFIG_{key} is not set'
    if pat.search(s):
        s = pat.sub(line, s, count=1)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'

def drop_cfg(key):
    global s
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)\n?', re.M)
    s = pat.sub('', s)

set_cfg('KSU', 'y')
set_cfg('EXT4_FS', 'y')
set_cfg('KSU_MANUAL_HOOK', 'y')
set_cfg('KSU_KPROBES_HOOK', 'n')
# Keep the Miatoll baseline for generic MODULES/KPROBES. The official legacy
# branch explicitly supports manual hooks and warns against its kprobe hook
# engine on kernels below 5.10.
if not susfs:
    drop_cfg('KSU_SUSFS')
else:
    set_cfg('KSU_SUSFS', 'y')

p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_EXT4_FS=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"

if [[ "${GX_SUSFS:-0}" == "0" ]]; then
  test -f "$KSUN_DIR/kernel/core/init.c"
  test -f "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  test -f "$KSUN_DIR/kernel/supercall/supercall.c"
  grep -Fq 'config KSU_MANUAL_HOOK' "$KSUN_DIR/kernel/Kconfig"
  grep -Fq 'This should not be used on kernel below 5.10' "$KSUN_DIR/kernel/Kconfig"
  grep -Fq 'int ksu_handle_execveat(' "$KSUN_DIR/kernel/core/init.c"
  grep -Fq 'ksu_handle_vfs_read' "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  grep -Fq 'ksu_handle_input_handle_event' "$KSUN_DIR/kernel/runtime/ksud_integration.c"
  grep -Fq 'ksu_handle_sys_reboot' "$KSUN_DIR/kernel/supercall/supercall.c"
  grep -Fq 'No hooks were defined, please integrate manual hooks in your kernel!' "$KSUN_DIR/kernel/Kbuild"
  echo "[GXT] official KernelSU-Next legacy manual-hook integration ready"
else
  grep -Fq 'config KSU_SUSFS' "$KSUN_DIR/kernel/Kconfig"
  grep -Fxq 'CONFIG_KSU_SUSFS=y' "$DEFCONFIG"
  echo "[GXT] KernelSU-Next SUSFS compatibility integration ready"
fi
