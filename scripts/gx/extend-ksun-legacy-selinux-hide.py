#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    s = path.read_text()
    if old in s:
        path.write_text(s.replace(old, new, 1))
        return
    if new in s:
        return
    raise SystemExit(f"{label}: expected anchor not found in {path}")


ksu_hide = Path("KernelSU-Next/kernel/feature/selinux_hide.c")
services = Path("security/selinux/ss/services.c")
selinuxfs = Path("security/selinux/selinuxfs.c")

for p in (ksu_hide, services, selinuxfs):
    if not p.is_file():
        raise SystemExit(f"missing expected file: {p}")

# Keep the upstream manager feature toggle authoritative.  N45 extends the
# existing SELinux-hide feature to the other userspace-visible SELinux query
# paths, so expose the flag to the vendor SELinux code instead of inventing a
# second toggle.
replace_once(
    ksu_hide,
    "static bool ksu_selinux_hide_is_enabled __read_mostly = true;",
    "bool ksu_selinux_hide_is_enabled __read_mostly = true;",
    "SELinux-hide feature flag",
)

# services.c: make root-framework-only contexts look invalid to sandboxed app
# queries.  This covers /sys/fs/selinux/context and the setcon fallback used by
# App-Zygote policy probes without changing the real policy or kernel AVC.
s = services.read_text()
if "#include <linux/cred.h>" not in s:
    anchor = "#include <linux/sched.h>\n"
    if anchor not in s:
        raise SystemExit("services.c: sched include anchor not found")
    s = s.replace(anchor, anchor + "#include <linux/cred.h>\n", 1)

helper_marker = "/* GXT KSUN legacy SELinux-hide context-query filter */"
if helper_marker not in s:
    fn_anchor = "int security_context_to_sid(struct selinux_state *state,"
    pos = s.find(fn_anchor)
    if pos < 0:
        raise SystemExit("services.c: security_context_to_sid anchor not found")
    helper = r'''/* GXT KSUN legacy SELinux-hide context-query filter */
#ifdef CONFIG_KSU
extern bool ksu_selinux_hide_is_enabled;

static bool ksu_hide_context_query(const char *scontext, u32 scontext_len)
{
	static const char *const hidden[] = {
		"u:r:magisk:s0",
		"u:object_r:magisk_file:s0",
		"u:r:ksu:s0",
		"u:object_r:ksu_file:s0",
		"u:r:adbroot:s0",
		"u:object_r:lsposed_file:s0",
		"u:object_r:xposed_data:s0",
		"u:object_r:xposed_file:s0",
	};
	size_t i;

	if (!ksu_selinux_hide_is_enabled || __kuid_val(current_uid()) < 10000)
		return false;
	if (!scontext || !scontext_len)
		return false;

	for (i = 0; i < ARRAY_SIZE(hidden); i++) {
		size_t len = strlen(hidden[i]);

		if ((scontext_len == len ||
		     (scontext_len == len + 1 && scontext[len] == '\0')) &&
		    !memcmp(scontext, hidden[i], len))
			return true;
	}

	return false;
}
#endif

'''
    s = s[:pos] + helper + s[pos:]

body_marker = "ksu_hide_context_query(scontext, scontext_len)"
if body_marker not in s[s.find("int security_context_to_sid(struct selinux_state *state,"):]:
    fn_pos = s.find("int security_context_to_sid(struct selinux_state *state,")
    brace = s.find("{", fn_pos)
    if brace < 0:
        raise SystemExit("services.c: security_context_to_sid body not found")
    inject = "\n#ifdef CONFIG_KSU\n\tif (ksu_hide_context_query(scontext, scontext_len))\n\t\treturn -EINVAL;\n#endif\n"
    s = s[:brace + 1] + inject + s[brace + 1:]

services.write_text(s)

# selinuxfs.c: DirtySepolicy and similar App-Zygote probes query the real AVC
# through /sys/fs/selinux/access.  Keep enforcement untouched; only sanitize
# the userspace query result for app UIDs while SELinux Hide is enabled.
s = selinuxfs.read_text()
if "#include <linux/cred.h>" not in s:
    anchor = "#include <linux/uaccess.h>\n"
    if anchor not in s:
        raise SystemExit("selinuxfs.c: uaccess include anchor not found")
    s = s.replace(anchor, anchor + "#include <linux/cred.h>\n", 1)

access_helper_marker = "/* GXT KSUN legacy SELinux-hide access-query filter */"
if access_helper_marker not in s:
    fn_anchor = "static ssize_t sel_write_access(struct file *file, char *buf, size_t size)"
    pos = s.find(fn_anchor)
    if pos < 0:
        raise SystemExit("selinuxfs.c: sel_write_access anchor not found")
    helper = r'''/* GXT KSUN legacy SELinux-hide access-query filter */
#ifdef CONFIG_KSU
extern bool ksu_selinux_hide_is_enabled;

static bool ksu_hide_access_pair(const char *scon, const char *tcon)
{
	if (!ksu_selinux_hide_is_enabled || __kuid_val(current_uid()) < 10000)
		return false;

	return (!strcmp(scon, "u:object_r:rootfs:s0") &&
		!strcmp(tcon, "u:object_r:tmpfs:s0")) ||
	       (!strcmp(scon, "u:r:kernel:s0") &&
		!strcmp(tcon, "u:object_r:tmpfs:s0")) ||
	       (!strcmp(scon, "u:r:kernel:s0") &&
		!strcmp(tcon, "u:object_r:adb_data_file:s0")) ||
	       (!strcmp(scon, "u:r:system_server:s0") &&
		!strcmp(tcon, "u:object_r:apk_data_file:s0")) ||
	       (!strcmp(scon, "u:r:dex2oat:s0") &&
		!strcmp(tcon, "u:object_r:dex2oat_exec:s0")) ||
	       (!strcmp(scon, "u:r:zygote:s0") &&
		!strcmp(tcon, "u:object_r:adb_data_file:s0"));
}
#endif

'''
    s = s[:pos] + helper + s[pos:]

sanitize_marker = "ksu_hide_access_pair(scon, tcon)"
if sanitize_marker not in s[s.find("static ssize_t sel_write_access(struct file *file, char *buf, size_t size)"):]:
    anchor = "\tsecurity_compute_av_user(state, ssid, tsid, tclass, &avd);\n"
    if anchor not in s:
        raise SystemExit("selinuxfs.c: security_compute_av_user anchor not found")
    inject = anchor + r'''
#ifdef CONFIG_KSU
	if (ksu_selinux_hide_is_enabled && __kuid_val(current_uid()) >= 10000) {
		/* App-Zygote expects the clean boot AVC sequence. */
		avd.seqno = 1;
		if (ksu_hide_access_pair(scon, tcon))
			avd.allowed = 0;
	}
#endif
'''
    s = s.replace(anchor, inject, 1)

selinuxfs.write_text(s)

# Fail closed if any expected edit disappeared.
checks = {
    ksu_hide: ["bool ksu_selinux_hide_is_enabled __read_mostly = true;"],
    services: [helper_marker, "ksu_hide_context_query(scontext, scontext_len)"],
    selinuxfs: [access_helper_marker, "ksu_hide_access_pair(scon, tcon)", "avd.seqno = 1;"],
}
for p, needles in checks.items():
    text = p.read_text()
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"{p}: missing verification marker: {needle}")

print("[N45][KSUN-legacy] extended SELinux Hide over context/access App-Zygote probes")
