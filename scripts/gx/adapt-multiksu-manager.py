#!/usr/bin/env python3
from pathlib import Path

KERNEL = Path("KernelSU/kernel")
KSUN_CERT_SIZE = "0x3e6"
KSUN_CERT_HASH = "79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7"


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one anchor, found {count}: {old[:80]!r}")
    path.write_text(text.replace(old, new, 1))


def require(path: Path, needle: str) -> None:
    if needle not in path.read_text():
        raise SystemExit(f"{path}: required marker missing: {needle}")


# Runtime manager personality. The kernel keeps one active manager appid, just
# like upstream KernelSU, but remembers which verified signer owns that appid.
# Both current managers speak UAPI4, but they remain separate verified
# personalities because KernelSU-Next also probes its 98/99 informational
# ioctls and has a distinct release signer.
identity = KERNEL / "manager/manager_identity.h"
replace_once(
    identity,
    "extern uid_t ksu_manager_appid; // DO NOT DIRECT USE\n",
    """extern uid_t ksu_manager_appid; // DO NOT DIRECT USE

enum gxt_ksu_manager_kind {
	GXT_KSU_MANAGER_NONE = 0,
	GXT_KSU_MANAGER_XXKSU = 1,
	GXT_KSU_MANAGER_KSUN = 2,
};

#define GXT_KSU_UAPI_KSUN 4
#define GXT_KSU_UAPI_XXKSU 4

extern enum gxt_ksu_manager_kind gxt_ksu_manager_kind;

static inline enum gxt_ksu_manager_kind gxt_ksu_get_manager_kind(void)
{
	return gxt_ksu_manager_kind;
}

static inline void gxt_ksu_set_manager_kind(enum gxt_ksu_manager_kind kind)
{
	gxt_ksu_manager_kind = kind;
}

static inline unsigned int gxt_ksu_manager_uapi_version(void)
{
	return gxt_ksu_manager_kind == GXT_KSU_MANAGER_KSUN ?
		GXT_KSU_UAPI_KSUN : GXT_KSU_UAPI_XXKSU;
}

"""
)
replace_once(
    identity,
    """static inline void ksu_set_manager_appid(uid_t appid)
{
	ksu_manager_appid = appid;
}
""",
    """static inline void ksu_set_manager_appid(uid_t appid)
{
	ksu_manager_appid = appid;
}

static inline void gxt_ksu_set_manager_identity(uid_t appid,
						enum gxt_ksu_manager_kind kind)
{
	ksu_manager_appid = appid;
	gxt_ksu_manager_kind = kind;
}
"""
)
replace_once(
    identity,
    """static inline void ksu_invalidate_manager_uid()
{
	ksu_manager_appid = KSU_INVALID_APPID;
}
""",
    """static inline void ksu_invalidate_manager_uid()
{
	ksu_manager_appid = KSU_INVALID_APPID;
	gxt_ksu_manager_kind = GXT_KSU_MANAGER_NONE;
}
"""
)

sign_h = KERNEL / "manager/apk_sign.h"
replace_once(
    sign_h,
    """#ifndef __KSU_H_APK_V2_SIGN
#define __KSU_H_APK_V2_SIGN

bool is_manager_apk(char *path);
""",
    """#ifndef __KSU_H_APK_V2_SIGN
#define __KSU_H_APK_V2_SIGN

#include "manager_identity.h"

enum gxt_ksu_manager_kind gxt_ksu_detect_manager_apk(char *path);
bool is_manager_apk(char *path);
"""
)

sign_c = KERNEL / "manager/apk_sign.c"
text = sign_c.read_text()
start = text.find("bool is_manager_apk(char *path)\n{")
if start < 0:
    raise SystemExit("apk_sign.c: is_manager_apk anchor missing")
# is_manager_apk is the last function in the pinned xxKSU source.
prefix = text[:start]
replacement = f"""enum gxt_ksu_manager_kind gxt_ksu_detect_manager_apk(char *path)
{{
#ifdef KSU_MANAGER_PACKAGE
	char pkg[KSU_MAX_PACKAGE_NAME];
	if (get_pkg_from_apk_path(pkg, path) < 0) {{
		pr_err("Failed to get package name from apk path: %s\\n", path);
		return GXT_KSU_MANAGER_NONE;
	}}
#endif

	/*
	 * Preserve every manager identity already accepted by xxKSU and map it to
	 * the UAPI4 personality.  KernelSU-Next v3.4.0 is deliberately a separate
	 * signer and is also UAPI4, with its own 98/99 compatibility personality.
	 */
	char buf[KSU_MAX_PACKAGE_NAME];
	constexpr char official_pkg[] = "me.weishu.kernelsu";
	if (check_v2_signature(path, 0x363,
			"4359c171f32543394cbc23ef908c4bb94cad7c8087002ba164c8230948c21549") &&
		!get_pkg_from_apk_path(buf, path) &&
		!__builtin_memcmp(buf, official_pkg, sizeof(official_pkg)))
		return GXT_KSU_MANAGER_XXKSU;

	if (check_v2_signature(path, EXPECTED_SIZE, EXPECTED_HASH))
		return GXT_KSU_MANAGER_XXKSU;

	if (check_v2_signature(path, 0x375,
			"484fcba6e6c43b1fb09700633bf2fb4758f13cb0b2f4457b80d075084b26c588"))
		return GXT_KSU_MANAGER_XXKSU;

	/* rifsxd/KernelSU-Next v3.4.0 release signer: UAPI4 manager personality. */
	if (check_v2_signature(path, {KSUN_CERT_SIZE},
			"{KSUN_CERT_HASH}"))
		return GXT_KSU_MANAGER_KSUN;

	return GXT_KSU_MANAGER_NONE;
}}

bool is_manager_apk(char *path)
{{
	return gxt_ksu_detect_manager_apk(path) != GXT_KSU_MANAGER_NONE;
}}
"""
sign_c.write_text(prefix + replacement)

throne = KERNEL / "manager/throne_tracker.c"
replace_once(
    throne,
    "uid_t ksu_manager_appid = KSU_INVALID_APPID;\n",
    """uid_t ksu_manager_appid = KSU_INVALID_APPID;
enum gxt_ksu_manager_kind gxt_ksu_manager_kind = GXT_KSU_MANAGER_NONE;
"""
)
replace_once(
    throne,
    "static __always_inline void crown_manager(const char *apk, struct list_head *uid_data)\n",
    """static __always_inline void crown_manager(const char *apk,
							 struct list_head *uid_data,
							 enum gxt_ksu_manager_kind kind)
"""
)
replace_once(
    throne,
    """			pr_info("Crowning manager: %s(uid=%d)\\n", pkg, np->uid);
			ksu_set_manager_appid(np->uid);
""",
    """			pr_info("Crowning manager: %s(uid=%d, kind=%d, uapi=%u)\\n",
				pkg, np->uid, kind,
				kind == GXT_KSU_MANAGER_KSUN ?
				GXT_KSU_UAPI_KSUN : GXT_KSU_UAPI_XXKSU);
			gxt_ksu_set_manager_identity(np->uid, kind);
"""
)
replace_once(
    throne,
    """			bool is_manager = is_manager_apk(candidate_path);
			pr_info("Found new base.apk at path: %s, is_manager: %d\\n", candidate_path, is_manager);

			if (likely(!is_manager))
				goto skip_iterate;

			crown_manager(candidate_path, uid_data);
""",
    """			enum gxt_ksu_manager_kind kind =
				gxt_ksu_detect_manager_apk(candidate_path);
			pr_info("Found new base.apk at path: %s, manager_kind: %d\\n",
				candidate_path, kind);

			if (likely(kind == GXT_KSU_MANAGER_NONE))
				goto skip_iterate;

			crown_manager(candidate_path, uid_data, kind);
"""
)

dispatch = KERNEL / "supercall/dispatch.c"
replace_once(
    dispatch,
    "	cmd.uapi_version = KERNEL_SU_UAPI_VERSION;\n",
    """	/*
	 * One kernel, two verified manager personalities:
	 *   KernelSU-Next v3.4.0 -> UAPI4 + KSUN informational ioctls
	 *   xxKSU v3.3.0-30      -> UAPI4 native backend
	 * Unknown/not-yet-crowned defaults to the native xxKSU UAPI4 backend.
	 */
	cmd.uapi_version = gxt_ksu_manager_uapi_version();
"""
)

# KernelSU-Next v3.4.0 uses two informational ioctls not present in the pinned
# xxKSU UAPI4 header. Add those commands locally without changing the common
# UAPI4 command table.
compat_defs = """/* GXT MultiKSU: KernelSU-Next v3.4.0 compatibility ioctls. */
struct gxt_ksu_get_hook_mode_cmd {
	char mode[16];
};

struct gxt_ksu_get_version_tag_cmd {
	char tag[32];
};

#define GXT_KSU_IOCTL_GET_HOOK_MODE _IOC(_IOC_READ, 'K', 98, 0)
#define GXT_KSU_IOCTL_GET_VERSION_TAG _IOC(_IOC_READ, 'K', 99, 0)

"""
marker = "static int do_grant_root(void __user *arg)\n"
replace_once(dispatch, marker, compat_defs + marker)

compat_handlers = """static int gxt_do_get_hook_mode(void __user *arg)
{
	struct gxt_ksu_get_hook_mode_cmd cmd = {0};

	if (gxt_ksu_get_manager_kind() != GXT_KSU_MANAGER_KSUN &&
	    current_uid().val != 0)
		return -ENOTTY;

	strscpy(cmd.mode, "Manual", sizeof(cmd.mode));
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

static int gxt_do_get_version_tag(void __user *arg)
{
	struct gxt_ksu_get_version_tag_cmd cmd = {0};

	if (gxt_ksu_get_manager_kind() != GXT_KSU_MANAGER_KSUN &&
	    current_uid().val != 0)
		return -ENOTTY;

	strscpy(cmd.tag, "v3.4.0-gxt-multiksu", sizeof(cmd.tag));
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

"""
marker2 = "static int do_nuke_ext4_sysfs(void __user *arg)\n"
replace_once(dispatch, marker2, compat_handlers + marker2)

# Insert KSUN-only informational commands immediately before the sentinel.
sentinel = "	{ .cmd = 0, .name = NULL, .handler = NULL, .perm_check = NULL } // Sentinel\n"
entries = """	{ .cmd = GXT_KSU_IOCTL_GET_HOOK_MODE, .name = "GXT_GET_HOOK_MODE", .handler = gxt_do_get_hook_mode, .perm_check = manager_or_root },
	{ .cmd = GXT_KSU_IOCTL_GET_VERSION_TAG, .name = "GXT_GET_VERSION_TAG", .handler = gxt_do_get_version_tag, .perm_check = manager_or_root },
"""
replace_once(dispatch, sentinel, entries + sentinel)

# Build-time proof. These assertions intentionally fail if the pinned upstream
# shape changes instead of silently producing a fake multi-manager build.
for path, needle in [
    (identity, "GXT_KSU_UAPI_KSUN 4"),
    (identity, "GXT_KSU_UAPI_XXKSU 4"),
    (sign_c, KSUN_CERT_HASH),
    (throne, "gxt_ksu_set_manager_identity"),
    (dispatch, "cmd.uapi_version = gxt_ksu_manager_uapi_version();"),
    (dispatch, "GXT_KSU_IOCTL_GET_HOOK_MODE"),
    (dispatch, "GXT_KSU_IOCTL_GET_VERSION_TAG"),
]:
    require(path, needle)

print("[GXT] MultiKSU manager routing ready: KSUN v3.4.0=UAPI4, xxKSU v3.3.0-30=UAPI4")
