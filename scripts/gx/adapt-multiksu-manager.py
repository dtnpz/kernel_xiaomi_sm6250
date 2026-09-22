#!/usr/bin/env python3
from pathlib import Path

KERNEL = Path("KernelSU/kernel")
KSUN_CERT_SIZE = "0x3e6"
KSUN_CERT_HASH = "79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7"
KOWSU_CERT_SIZE = "0x375"
KOWSU_CERT_HASH = "484fcba6e6c43b1fb09700633bf2fb4758f13cb0b2f4457b80d075084b26c588"
MAMBOSU_CERT_SIZE = "0x384"
MAMBOSU_CERT_HASH = "a9462b8b98ea1ca7901b0cbdcebfaa35f0aa95e51b01d66e6b6d2c81b97746d8"
RESUKISU_CERT_SIZE = "0x377"
RESUKISU_CERT_HASH = "d3469712b6214462764a1d8d3e5cbe1d6819a0b629791b9f4101867821f1df64"


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
	GXT_KSU_MANAGER_KSU = 1,
	GXT_KSU_MANAGER_XXKSU = 2,
	GXT_KSU_MANAGER_KSUN = 3,
	GXT_KSU_MANAGER_KOWSU = 4,
	GXT_KSU_MANAGER_MAMBOSU = 5,
	GXT_KSU_MANAGER_RESUKISU = 6,
};

#define GXT_KSU_UAPI_KSU 4
#define GXT_KSU_UAPI_XXKSU 4
#define GXT_KSU_UAPI_KSUN 4
#define GXT_KSU_UAPI_KOWSU 4
#define GXT_KSU_UAPI_MAMBOSU 4
#define GXT_KSU_UAPI_RESUKISU 4

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
	switch (gxt_ksu_manager_kind) {
	case GXT_KSU_MANAGER_KSU:
		return GXT_KSU_UAPI_KSU;
	case GXT_KSU_MANAGER_KSUN:
		return GXT_KSU_UAPI_KSUN;
	case GXT_KSU_MANAGER_KOWSU:
		return GXT_KSU_UAPI_KOWSU;
	case GXT_KSU_MANAGER_MAMBOSU:
		return GXT_KSU_UAPI_MAMBOSU;
	case GXT_KSU_MANAGER_RESUKISU:
		return GXT_KSU_UAPI_RESUKISU;
	case GXT_KSU_MANAGER_XXKSU:
	case GXT_KSU_MANAGER_NONE:
	default:
		return GXT_KSU_UAPI_XXKSU;
	}
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
	 * Mirror the signer set used by the miatoll Indo Multi-manager integration,
	 * but retain the verified signer identity instead of collapsing every APK
	 * into one boolean. All currently supported managers speak common UAPI4;
	 * identity is kept for downstream/fork-specific compatibility ioctls.
	 */
	char buf[KSU_MAX_PACKAGE_NAME];
	constexpr char official_pkg[] = "me.weishu.kernelsu";
	if (check_v2_signature(path, 0x363,
			"4359c171f32543394cbc23ef908c4bb94cad7c8087002ba164c8230948c21549") &&
		!get_pkg_from_apk_path(buf, path) &&
		!__builtin_memcmp(buf, official_pkg, sizeof(official_pkg)))
		return GXT_KSU_MANAGER_KSU;

	if (check_v2_signature(path, EXPECTED_SIZE, EXPECTED_HASH))
		return GXT_KSU_MANAGER_XXKSU;

	/* KOWX712/KernelSU (KowSU). */
	if (check_v2_signature(path, {KOWSU_CERT_SIZE},
			"{KOWSU_CERT_HASH}"))
		return GXT_KSU_MANAGER_KOWSU;

	/* rifsxd/KernelSU-Next v3.4.0. */
	if (check_v2_signature(path, {KSUN_CERT_SIZE},
			"{KSUN_CERT_HASH}"))
		return GXT_KSU_MANAGER_KSUN;

	/* RapliVx/KernelSU (MamboSU). */
	if (check_v2_signature(path, {MAMBOSU_CERT_SIZE},
			"{MAMBOSU_CERT_HASH}"))
		return GXT_KSU_MANAGER_MAMBOSU;

	/* ReSukiSU/ReSukiSU. */
	if (check_v2_signature(path, {RESUKISU_CERT_SIZE},
			"{RESUKISU_CERT_HASH}"))
		return GXT_KSU_MANAGER_RESUKISU;

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
				gxt_ksu_manager_uapi_version());
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
	 * One UAPI4 backend, multiple verified manager personalities. The installed
	 * manager signer selects downstream compatibility behavior; unknown or
	 * not-yet-crowned callers report the native xxKSU UAPI4 backend.
	 */
	cmd.uapi_version = gxt_ksu_manager_uapi_version();
"""
)

# Downstream managers share common UAPI4 but probe fork-specific informational
# ioctls. Provide the non-mutating compatibility surface used by KSUN/MamboSU
# (98/99) and ReSukiSU (100/101) without changing the native xxKSU backend.
compat_defs = """/* GXT MultiKSU: downstream informational compatibility ioctls. */
struct gxt_ksu_get_hook_mode_cmd {
	char mode[16];
};

struct gxt_ksu_get_version_tag_cmd {
	char tag[32];
};

struct gxt_ksu_get_full_version_cmd {
	char version_full[255];
};

struct gxt_ksu_hook_type_cmd {
	char hook_type[32];
};

#define GXT_KSU_IOCTL_GET_HOOK_MODE _IOC(_IOC_READ, 'K', 98, 0)
#define GXT_KSU_IOCTL_GET_VERSION_TAG _IOC(_IOC_READ, 'K', 99, 0)
#define GXT_KSU_IOCTL_GET_FULL_VERSION _IOC(_IOC_READ, 'K', 100, 0)
#define GXT_KSU_IOCTL_HOOK_TYPE _IOC(_IOC_READ, 'K', 101, 0)

"""
marker = "static int do_grant_root(void __user *arg)\n"
replace_once(dispatch, marker, compat_defs + marker)

compat_handlers = """static const char *gxt_ksu_hook_mode(void)
{
#ifdef CONFIG_KSU_KPROBES_KSUD
	return "Kprobes";
#elif defined(CONFIG_KSU_TAMPER_SYSCALL_TABLE)
	return "Manipulated";
#else
	return "Manual";
#endif
}

static int gxt_do_get_hook_mode(void __user *arg)
{
	struct gxt_ksu_get_hook_mode_cmd cmd = {0};

	strscpy(cmd.mode, gxt_ksu_hook_mode(), sizeof(cmd.mode));
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

static int gxt_do_get_version_tag(void __user *arg)
{
	struct gxt_ksu_get_version_tag_cmd cmd = {0};

	strscpy(cmd.tag, KERNEL_SU_VERSION_TAG, sizeof(cmd.tag));
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

static int gxt_do_get_full_version(void __user *arg)
{
	struct gxt_ksu_get_full_version_cmd cmd = {0};

	snprintf(cmd.version_full, sizeof(cmd.version_full),
		 "%s-gxt-multiksu-uapi%u", KERNEL_SU_VERSION_TAG,
		 gxt_ksu_manager_uapi_version());
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

static int gxt_do_get_hook_type(void __user *arg)
{
	struct gxt_ksu_hook_type_cmd cmd = {0};

	strscpy(cmd.hook_type, gxt_ksu_hook_mode(), sizeof(cmd.hook_type));
	if (copy_to_user(arg, &cmd, sizeof(cmd)))
		return -EFAULT;
	return 0;
}

marker2 = "static int do_nuke_ext4_sysfs(void __user *arg)\n"
replace_once(dispatch, marker2, compat_handlers + marker2)

# Insert downstream informational compatibility commands immediately before the sentinel.
sentinel = "	{ .cmd = 0, .name = NULL, .handler = NULL, .perm_check = NULL } // Sentinel\n"
entries = """	{ .cmd = GXT_KSU_IOCTL_GET_HOOK_MODE, .name = "GXT_GET_HOOK_MODE", .handler = gxt_do_get_hook_mode, .perm_check = manager_or_root },
	{ .cmd = GXT_KSU_IOCTL_GET_VERSION_TAG, .name = "GXT_GET_VERSION_TAG", .handler = gxt_do_get_version_tag, .perm_check = manager_or_root },
	{ .cmd = GXT_KSU_IOCTL_GET_FULL_VERSION, .name = "GXT_GET_FULL_VERSION", .handler = gxt_do_get_full_version, .perm_check = always_allow },
	{ .cmd = GXT_KSU_IOCTL_HOOK_TYPE, .name = "GXT_HOOK_TYPE", .handler = gxt_do_get_hook_type, .perm_check = manager_or_root },
"""
replace_once(dispatch, sentinel, entries + sentinel)

# Build-time proof. These assertions intentionally fail if the pinned upstream
# shape changes instead of silently producing a fake multi-manager build.
for path, needle in [
    (identity, "GXT_KSU_UAPI_KSU 4"),
    (identity, "GXT_KSU_UAPI_XXKSU 4"),
    (identity, "GXT_KSU_UAPI_KSUN 4"),
    (identity, "GXT_KSU_UAPI_KOWSU 4"),
    (identity, "GXT_KSU_UAPI_MAMBOSU 4"),
    (identity, "GXT_KSU_UAPI_RESUKISU 4"),
    (sign_c, KSUN_CERT_HASH),
    (sign_c, KOWSU_CERT_HASH),
    (sign_c, MAMBOSU_CERT_HASH),
    (sign_c, RESUKISU_CERT_HASH),
    (throne, "gxt_ksu_set_manager_identity"),
    (dispatch, "cmd.uapi_version = gxt_ksu_manager_uapi_version();"),
    (dispatch, "GXT_KSU_IOCTL_GET_HOOK_MODE"),
    (dispatch, "GXT_KSU_IOCTL_GET_VERSION_TAG"),
    (dispatch, "GXT_KSU_IOCTL_GET_FULL_VERSION"),
    (dispatch, "GXT_KSU_IOCTL_HOOK_TYPE"),
]:
    require(path, needle)

print("[GXT] MultiKSU routing ready: KSU/xxKSU/KSUN/KowSU/MamboSU/ReSukiSU all UAPI4")
