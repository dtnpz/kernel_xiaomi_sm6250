#!/usr/bin/env python3
"""Restore the KSUN legacy/manual lifecycle hooks required on N45/4.14.

The common legacy-callback scrub runs before the KSUN adapter so modern root
lanes do not inherit stale ProjectVelvet callbacks.  KernelSU-Next's official
legacy/manual tree, however, still requires three lifecycle surfaces that are
not part of the sucompat-only adapter:

* vfs_read() so init.rc can be proxied and KERNEL_SU_RC appended;
* fstat/newfstat return hooks so init sees the appended init.rc size;
* input_handle_event() for KernelSU safe-mode detection.

Without the first two, second-stage/zygote detection can still happen while the
injected init.rc actions (ksud post-fs-data/services/boot-completed) never
exist.  That leaves service-stage modules such as Zygisk Next only partially
started or not started at boot.
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
            f"[N45][KSUN-lifecycle] expected one anchor for {label}, got {count}"
        )
    return text.replace(old, new, 1)


# fs/read_write.c -- init.rc read proxy used by the legacy/manual KSUN path.
path = "fs/read_write.c"
s = read(path)
if "CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_vfs_read" not in s:
    s = replace_once(
        s,
        "EXPORT_SYMBOL(kernel_read);\n\nssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n{\n\tssize_t ret;\n",
        """EXPORT_SYMBOL(kernel_read);

#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif

ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
\tssize_t ret;
#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
""",
        "vfs_read init.rc proxy hook",
    )
write(path, s)


# fs/stat.c -- keep init.rc stat size consistent with the bytes appended by the
# vfs_read proxy.  The placement mirrors established KSUN manual integrations.
path = "fs/stat.c"
s = read(path)
if "ksu_handle_newfstat_ret" not in s:
    anchor = "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\n"
    decl = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern void ksu_handle_newfstat_ret(unsigned int *fd,
                                    struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd,
                                   struct stat64 __user **statbuf_ptr);
#endif
#endif

"""
    s = replace_once(s, anchor, decl + anchor, "fstat lifecycle declarations")

    marker = "SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)\n"
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("[N45][KSUN-lifecycle] newfstat syscall not found")
    end = s.find("\n}\n", pos)
    if end < 0:
        raise SystemExit("[N45][KSUN-lifecycle] newfstat end not found")
    end += 3
    func = s[pos:end]
    func = replace_once(
        func,
        "\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n",
        """\tif (!error)
\t\terror = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
\tif (!error)
\t\tksu_handle_newfstat_ret(&fd, &statbuf);
#endif
\treturn error;
""",
        "newfstat return hook",
    )
    s = s[:pos] + func + s[end:]

    marker = "SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)\n"
    pos = s.find(marker)
    if pos >= 0:
        end = s.find("\n}\n", pos)
        if end < 0:
            raise SystemExit("[N45][KSUN-lifecycle] fstat64 end not found")
        end += 3
        func = s[pos:end]
        func = replace_once(
            func,
            "\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n",
            """\tif (!error)
\t\terror = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
\tif (!error)
\t\tksu_handle_fstat64_ret(&fd, &statbuf);
#endif
\treturn error;
""",
            "fstat64 return hook",
        )
        s = s[:pos] + func + s[end:]
write(path, s)


# drivers/input/input.c -- restore the legacy/manual safe-mode callback that the
# common stale-hook scrub intentionally removed before this KSUN-specific pass.
path = "drivers/input/input.c"
s = read(path)
if "CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_input_handle_event" not in s:
    s = replace_once(
        s,
        "static void input_handle_event(struct input_dev *dev,\n",
        """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_input_handle_event(unsigned int *type,
                                         unsigned int *code, int *value);
#endif

static void input_handle_event(struct input_dev *dev,
""",
        "input safe-mode declaration",
    )
    s = replace_once(
        s,
        "\tint disposition = input_get_disposition(dev, type, code, &value);\n",
        """\tint disposition = input_get_disposition(dev, type, code, &value);
#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_input_handle_event(&type, &code, &value);
#endif
""",
        "input safe-mode callback",
    )
write(path, s)


checks = {
    "fs/read_write.c": [
        "CONFIG_KSU_MANUAL_HOOK",
        "ksu_handle_vfs_read(&file, &buf, &count, &pos);",
    ],
    "fs/stat.c": [
        "ksu_handle_newfstat_ret(&fd, &statbuf);",
        "ksu_handle_fstat64_ret(&fd, &statbuf);",
    ],
    "drivers/input/input.c": [
        "ksu_handle_input_handle_event(&type, &code, &value);",
    ],
}
for filename, needles in checks.items():
    text = read(filename)
    for needle in needles:
        if needle not in text:
            raise SystemExit(
                f"[N45][KSUN-lifecycle] verification failed: {filename}: {needle}"
            )

print("[N45][KSUN-lifecycle] init.rc/stat/input manual lifecycle hooks restored")
