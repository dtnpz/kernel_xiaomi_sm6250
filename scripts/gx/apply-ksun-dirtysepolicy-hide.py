#!/usr/bin/env python3
"""Add N45/4.14 DirtySepolicy parity to KernelSU-Next legacy.

This intentionally keeps the official legacy/manual-hook core. It only adds
the userspace-facing SELinux view that xxKSU provides: app UIDs see stock-like
selinuxfs context/access/status results while KernelSU continues to use the
real modified policy internally.
"""
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"[N45][KSUN-dirtyhide] expected one anchor for {label}, got {count}"
        )
    return text.replace(old, new, 1)


path = "KernelSU-Next/kernel/feature/selinux_hide.h"
s = read(path)
if "ksu_selinux_hide_transaction_pre" not in s:
    s = replace_once(
        s,
        "void ksu_selinux_hide_exit();\n\n#endif",
        """void ksu_selinux_hide_exit();

void ksu_selinux_hide_track_policy_cmd(u32 cmd, u32 subcmd,
                                        const char **args);
int ksu_selinux_hide_transaction_pre(ino_t ino, const char *data,
                                     size_t size);
ssize_t ksu_selinux_hide_transaction_post(ino_t ino, char *data,
                                          ssize_t rv);
int ksu_selinux_hide_setprocattr_pre(const char *name, const void *value,
                                     size_t size);

#endif""",
        "selinux hide helper prototypes",
    )
    s = replace_once(
        s,
        "#include <linux/types.h>\n",
        "#include <linux/types.h>\n#include <linux/fs.h>\n",
        "selinux hide header fs types",
    )
write(path, s)


path = "KernelSU-Next/kernel/feature/selinux_hide.c"
s = read(path)
if "N45 DirtySepolicy parity" not in s:
    s = replace_once(
        s,
        '#include  "uapi/feature.h"\n',
        '#include  "uapi/feature.h"\n#include "uapi/selinux.h"\n',
        "SELinux UAPI include",
    )

    anchor = "static bool ksu_selinux_hide_is_enabled __read_mostly = true;\n"
    parity = r'''
/*
 * N45 DirtySepolicy parity.
 *
 * KernelSU must modify the live policy to function, but normal app processes
 * should not learn about those private additions through selinuxfs. Track the
 * types and source/target pairs introduced by KernelSU or module sepolicy and
 * make the Linux 4.14 selinuxfs query path present a stock-like view.
 *
 * Fixed-size tables are deliberate: policy writes are rare, lookups are
 * bounded, and this avoids lifetime/RCU complexity in the old 4.14 tree.
 */
#define N45_KSU_HIDE_MAX_TYPES 96
#define N45_KSU_HIDE_MAX_PAIRS 192
#define N45_KSU_HIDE_NAME_MAX 64

struct n45_ksu_hide_pair {
	char src[N45_KSU_HIDE_NAME_MAX];
	char tgt[N45_KSU_HIDE_NAME_MAX];
};

static char n45_ksu_hide_types[N45_KSU_HIDE_MAX_TYPES][N45_KSU_HIDE_NAME_MAX];
static struct n45_ksu_hide_pair n45_ksu_hide_pairs[N45_KSU_HIDE_MAX_PAIRS];
static unsigned int n45_ksu_hide_type_count;
static unsigned int n45_ksu_hide_pair_count;
static DEFINE_MUTEX(n45_ksu_hide_lock);

static bool n45_ksu_hide_app_query(void)
{
	return READ_ONCE(ksu_selinux_hide_is_enabled) &&
	       current_uid().val >= 10000 &&
	       test_thread_flag(TIF_SECCOMP);
}

static bool n45_ksu_hide_name_ok(const char *name)
{
	size_t len;

	if (!name || !name[0])
		return false;
	len = strnlen(name, N45_KSU_HIDE_NAME_MAX);
	return len > 0 && len < N45_KSU_HIDE_NAME_MAX;
}

static void n45_ksu_hide_add_type(const char *name)
{
	unsigned int i;

	if (!n45_ksu_hide_name_ok(name))
		return;

	mutex_lock(&n45_ksu_hide_lock);
	for (i = 0; i < n45_ksu_hide_type_count; i++) {
		if (!strcmp(n45_ksu_hide_types[i], name))
			goto out;
	}
	if (n45_ksu_hide_type_count >= N45_KSU_HIDE_MAX_TYPES) {
		pr_warn("ksu_selinux_hide: type tracking table full\n");
		goto out;
	}
	strlcpy(n45_ksu_hide_types[n45_ksu_hide_type_count], name,
		N45_KSU_HIDE_NAME_MAX);
	smp_wmb();
	n45_ksu_hide_type_count++;
out:
	mutex_unlock(&n45_ksu_hide_lock);
}

static void n45_ksu_hide_add_pair(const char *src, const char *tgt)
{
	unsigned int i;

	if (!n45_ksu_hide_name_ok(src) || !n45_ksu_hide_name_ok(tgt))
		return;

	mutex_lock(&n45_ksu_hide_lock);
	for (i = 0; i < n45_ksu_hide_pair_count; i++) {
		if (!strcmp(n45_ksu_hide_pairs[i].src, src) &&
		    !strcmp(n45_ksu_hide_pairs[i].tgt, tgt))
			goto out;
	}
	if (n45_ksu_hide_pair_count >= N45_KSU_HIDE_MAX_PAIRS) {
		pr_warn("ksu_selinux_hide: rule tracking table full\n");
		goto out;
	}
	strlcpy(n45_ksu_hide_pairs[n45_ksu_hide_pair_count].src, src,
		N45_KSU_HIDE_NAME_MAX);
	strlcpy(n45_ksu_hide_pairs[n45_ksu_hide_pair_count].tgt, tgt,
		N45_KSU_HIDE_NAME_MAX);
	smp_wmb();
	n45_ksu_hide_pair_count++;
out:
	mutex_unlock(&n45_ksu_hide_lock);
}

static bool n45_ksu_hide_context_matches(const char *text, const char *type)
{
	char needle[N45_KSU_HIDE_NAME_MAX + 3];

	if (!text || !n45_ksu_hide_name_ok(type))
		return false;
	scnprintf(needle, sizeof(needle), ":%s:", type);
	return strstr(text, needle) != NULL;
}

static bool n45_ksu_hide_query_matches(const char *data, size_t size,
					bool pairs)
{
	char query[512];
	char *second;
	size_t len;
	unsigned int i, type_count, pair_count;

	if (!data || !size)
		return false;
	len = size < sizeof(query) - 1 ? size : sizeof(query) - 1;
	memcpy(query, data, len);
	query[len] = '\0';

	type_count = READ_ONCE(n45_ksu_hide_type_count);
	smp_rmb();
	for (i = 0; i < type_count && i < N45_KSU_HIDE_MAX_TYPES; i++) {
		if (n45_ksu_hide_context_matches(query, n45_ksu_hide_types[i]))
			return true;
	}

	if (!pairs)
		return false;

	second = strchr(query, ' ');
	if (!second)
		return false;
	while (*second == ' ')
		second++;

	pair_count = READ_ONCE(n45_ksu_hide_pair_count);
	smp_rmb();
	for (i = 0; i < pair_count && i < N45_KSU_HIDE_MAX_PAIRS; i++) {
		if (n45_ksu_hide_context_matches(query,
						 n45_ksu_hide_pairs[i].src) &&
		    n45_ksu_hide_context_matches(second,
						 n45_ksu_hide_pairs[i].tgt))
			return true;
	}
	return false;
}

static void n45_ksu_hide_seed_policy(void)
{
	n45_ksu_hide_add_type(KERNEL_SU_DOMAIN);
	n45_ksu_hide_add_type(KERNEL_SU_FILE);
	n45_ksu_hide_add_pair("kernel", "adb_data_file");
	n45_ksu_hide_add_pair("init", "adb_data_file");
	n45_ksu_hide_add_pair("zygote", "adb_data_file");
}

void ksu_selinux_hide_track_policy_cmd(u32 cmd, u32 subcmd,
					const char **args)
{
	if (!args)
		return;

	switch (cmd) {
	case KSU_SEPOLICY_CMD_NORMAL_PERM:
		if (subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW)
			n45_ksu_hide_add_pair(args[0], args[1]);
		break;
	case KSU_SEPOLICY_CMD_XPERM:
		if (subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW)
			n45_ksu_hide_add_pair(args[0], args[1]);
		break;
	case KSU_SEPOLICY_CMD_TYPE:
	case KSU_SEPOLICY_CMD_TYPE_ATTR:
	case KSU_SEPOLICY_CMD_TYPE_STATE:
		n45_ksu_hide_add_type(args[0]);
		break;
	case KSU_SEPOLICY_CMD_TYPE_TRANSITION:
		n45_ksu_hide_add_pair(args[0], args[1]);
		n45_ksu_hide_add_type(args[3]);
		break;
	case KSU_SEPOLICY_CMD_TYPE_CHANGE:
		n45_ksu_hide_add_pair(args[0], args[1]);
		n45_ksu_hide_add_type(args[3]);
		break;
	default:
		break;
	}
}

/* SEL_CONTEXT=5 and SEL_ACCESS=6 on the N45 4.14 selinuxfs ABI. */
int ksu_selinux_hide_transaction_pre(ino_t ino, const char *data, size_t size)
{
	if (!n45_ksu_hide_app_query())
		return 0;
	if (ino != 5 && ino != 6)
		return 0;
	if (n45_ksu_hide_query_matches(data, size, ino == 6))
		return -EINVAL;
	return 0;
}

ssize_t ksu_selinux_hide_transaction_post(ino_t ino, char *data, ssize_t rv)
{
	u32 allowed, decided, auditallow, auditdeny, seqno, flags;
	int parsed;

	if (!n45_ksu_hide_app_query() || ino != 6 || !data || rv <= 0)
		return rv;

	parsed = sscanf(data, "%x %x %x %x %u %x",
		       &allowed, &decided, &auditallow, &auditdeny,
		       &seqno, &flags);
	if (parsed != 6)
		return rv;

	return scnprintf(data, SIMPLE_TRANSACTION_LIMIT,
			 "%x %x %x %x %u %x",
			 allowed, decided, auditallow, auditdeny, 1U, flags);
}

int ksu_selinux_hide_setprocattr_pre(const char *name, const void *value,
				      size_t size)
{
	if (!n45_ksu_hide_app_query() || !name || strcmp(name, "current"))
		return 0;
	if (!value || !size)
		return 0;
	if (n45_ksu_hide_query_matches(value, size, false))
		return -EINVAL;
	return 0;
}
'''
    s = replace_once(s, anchor, anchor + parity,
                     "N45 DirtySepolicy parity helper block")

    old_status = """\tstruct selinux_kernel_status *new_status = page_address(new_page);
\tmemcpy(new_status, status, sizeof(*status));
\tif (ksu_late_loaded && !new_status->enforcing) {
\t\t/*
\t\t * In late_load mode we may be loaded after setenforce 0.
\t\t * Adjust sequence to look like a normal enforcing boot.
\t\t * Assumes setenforce 0 was called exactly once.
\t\t */
\t\tnew_status->enforcing = 1;
\t\tnew_status->sequence = 4;
\t}
"""
    new_status = """\tstruct selinux_kernel_status *new_status = page_address(new_page);
\tmemcpy(new_status, status, sizeof(*status));
\t/* Stock userspace-facing status; never expose KSU policy reload counters. */
\tnew_status->enforcing = 1;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
\tnew_status->sequence = 4;
\tnew_status->policyload = 1;
#else
\tnew_status->sequence = 0;
\tnew_status->policyload = 0;
#endif
"""
    s = replace_once(s, old_status, new_status,
                     "stock SELinux status counters")

    s = replace_once(
        s,
        "\t\t\tfilp->private_data = page_address(data);\n",
        "\t\t\t/* N45/4.14 selinuxfs expects struct page * here. */\n"
        "\t\t\tfilp->private_data = data;\n",
        "N45 status-page private_data ABI",
    )

    s = replace_once(
        s,
        "void __init ksu_selinux_hide_init(void)\n{\n",
        "void __init ksu_selinux_hide_init(void)\n{\n"
        "\tn45_ksu_hide_seed_policy();\n",
        "seed private policy view",
    )
write(path, s)


path = "KernelSU-Next/kernel/selinux/rules.c"
s = read(path)
if "apply_one_sepolicy_cmd_raw" not in s:
    s = replace_once(
        s,
        '#include "compat/kernel_compat.h"\n',
        '#include "compat/kernel_compat.h"\n#include "feature/selinux_hide.h"\n',
        "rules selinux-hide include",
    )
    s = replace_once(
        s,
        "static int apply_one_sepolicy_cmd(struct policydb *db,\n",
        "static int apply_one_sepolicy_cmd_raw(struct policydb *db,\n",
        "raw sepolicy dispatcher rename",
    )

    wrapper_anchor = "\n#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS\nint handle_sepolicy"
    wrapper = """
static int apply_one_sepolicy_cmd(struct policydb *db,
                                  const struct sepol_data *header,
                                  const char **args)
{
\tint ret = apply_one_sepolicy_cmd_raw(db, header, args);

\tif (!ret)
\t\tksu_selinux_hide_track_policy_cmd(header->cmd, header->subcmd, args);
\treturn ret;
}

#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS
int handle_sepolicy"""
    s = replace_once(s, wrapper_anchor, "\n" + wrapper,
                     "sepolicy tracking dispatcher wrapper")
write(path, s)


path = "security/selinux/selinuxfs.c"
s = read(path)
if "ksu_selinux_hide_transaction_pre" not in s:
    old = """\tdata = simple_transaction_get(file, buf, size);
\tif (IS_ERR(data))
\t\treturn PTR_ERR(data);

\trv = write_op[ino](file, data, size);
\tif (rv > 0) {
"""
    new = """\tdata = simple_transaction_get(file, buf, size);
\tif (IS_ERR(data))
\t\treturn PTR_ERR(data);

#ifdef CONFIG_KSU
\t{
\t\textern int ksu_selinux_hide_transaction_pre(ino_t ino,
\t\t\t\t\t\t      const char *data,
\t\t\t\t\t\t      size_t size);
\t\trv = ksu_selinux_hide_transaction_pre(ino, data, size);
\t\tif (rv)
\t\t\treturn rv;
\t}
#endif

\trv = write_op[ino](file, data, size);
#ifdef CONFIG_KSU
\t{
\t\textern ssize_t ksu_selinux_hide_transaction_post(ino_t ino,
\t\t\t\t\t\t\t char *data,
\t\t\t\t\t\t\t ssize_t rv);
\t\trv = ksu_selinux_hide_transaction_post(ino, data, rv);
\t}
#endif
\tif (rv > 0) {
"""
    s = replace_once(s, old, new,
                     "N45 selinuxfs context/access query hooks")
write(path, s)


path = "security/selinux/hooks.c"
s = read(path)
if "ksu_selinux_hide_setprocattr_pre" not in s:
    old = """\tint error;
\tchar *str = value;

\t/*
"""
    new = """\tint error;
\tchar *str = value;

#ifdef CONFIG_KSU
\t{
\t\textern int ksu_selinux_hide_setprocattr_pre(const char *name,
\t\t\t\t\t\t\t     const void *value,
\t\t\t\t\t\t\t     size_t size);
\t\terror = ksu_selinux_hide_setprocattr_pre(name, value, size);
\t\tif (error)
\t\t\treturn error;
\t}
#endif

\t/*
"""
    pos = s.find("static int selinux_setprocattr(")
    if pos < 0:
        raise SystemExit("[N45][KSUN-dirtyhide] selinux_setprocattr not found")
    prefix, tail = s[:pos], s[pos:]
    tail = replace_once(tail, old, new,
                        "N45 setprocattr hidden-context hook")
    s = prefix + tail
write(path, s)


checks = {
    "KernelSU-Next/kernel/feature/selinux_hide.c": [
        "N45 DirtySepolicy parity",
        "new_status->sequence = 0;",
        "new_status->policyload = 0;",
        "filp->private_data = data;",
        "ksu_selinux_hide_transaction_pre",
        "ksu_selinux_hide_setprocattr_pre",
    ],
    "KernelSU-Next/kernel/selinux/rules.c": [
        "apply_one_sepolicy_cmd_raw",
        "ksu_selinux_hide_track_policy_cmd",
    ],
    "security/selinux/selinuxfs.c": [
        "ksu_selinux_hide_transaction_pre",
        "ksu_selinux_hide_transaction_post",
    ],
    "security/selinux/hooks.c": [
        "ksu_selinux_hide_setprocattr_pre",
    ],
}
for filename, needles in checks.items():
    text = read(filename)
    for needle in needles:
        if needle not in text:
            raise SystemExit(
                f"[N45][KSUN-dirtyhide] verification failed: "
                f"{filename}: {needle}"
            )

print("[N45][KSUN-dirtyhide] installed DirtySepolicy parity on legacy manual hooks")
