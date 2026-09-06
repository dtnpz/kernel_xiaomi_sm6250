#!/usr/bin/env python3
"""Restore the KSUN legacy/manual lifecycle hooks required on N45/4.14.

The common legacy-callback scrub runs before the KSUN adapter so modern root
lanes do not inherit stale ProjectVelvet callbacks. KernelSU-Next's official
legacy/manual tree, however, still requires three lifecycle surfaces that are
not part of the sucompat-only adapter:

* vfs_read() so init.rc can be proxied and KERNEL_SU_RC appended;
* fstat/newfstat return hooks so init sees the appended init.rc size;
* input_event()/input_inject_event() for KernelSU safe-mode detection.

Keep the safe-mode callback on the exported/stable input entrypoints rather
than the private input_handle_event() hot path. Upstream KernelSU made the same
move when it replaced input_handle_event hooking with input_event plus
input_inject_event. Besides being a more stable ABI, this keeps KSU out of the
internal input-core dispatch path used by device/HAL input handling.

Without the first two lifecycle hooks, second-stage/zygote detection can still
happen while the injected init.rc actions (ksud post-fs-data/services/
boot-completed) never exist. That leaves service-stage modules such as Zygisk
Next only partially started or not started at boot.
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
# The stale-hook scrub removes whole CONFIG_KSU blocks but intentionally leaves
# surrounding blank lines, so anchor on the vfs_read function itself rather than
# an exact number of newlines around EXPORT_SYMBOL(kernel_read).
path = "fs/read_write.c"
s = read(path)
if "ksu_handle_vfs_read(&file, &buf, &count, &pos);" not in s:
    marker = "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)\n"
    if s.count(marker) != 1:
        raise SystemExit(
            f"[N45][KSUN-lifecycle] expected one vfs_read function, got {s.count(marker)}"
        )
    decl = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif

"""
    s = s.replace(marker, decl + marker, 1)
    pos = s.index(marker)
    body = "{\n\tssize_t ret;\n"
    body_pos = s.find(body, pos)
    if body_pos < 0:
        raise SystemExit("[N45][KSUN-lifecycle] vfs_read body anchor not found")
    replacement = """{
\tssize_t ret;
#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
"""
    s = s[:body_pos] + s[body_pos:].replace(body, replacement, 1)
write(path, s)


# fs/stat.c -- keep init.rc stat size consistent with the bytes appended by the
# vfs_read proxy. The placement mirrors established KSUN manual integrations.
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


# drivers/input/input.c -- preserve safe-mode detection, but keep the callback
# out of private input_handle_event(). Upstream moved the hook to the exported
# input_event()/input_inject_event() entrypoints for the same stable-symbol
# reason. This is also less invasive to vendor fingerprint/input internals.
path = "drivers/input/input.c"
s = read(path)
call = "ksu_handle_input_handle_event(&type, &code, &value);"
if call not in s:
    marker = "void input_event(struct input_dev *dev,\n"
    if s.count(marker) != 1:
        raise SystemExit(
            f"[N45][KSUN-lifecycle] expected one input_event entrypoint, got {s.count(marker)}"
        )
    decl = """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_input_handle_event(unsigned int *type,
                                         unsigned int *code, int *value);
#endif

"""
    s = s.replace(marker, decl + marker, 1)

    input_event_old = """{
\tunsigned long flags;

\tif (is_event_supported(type, dev->evbit, EV_MAX)) {
"""
    input_event_new = """{
\tunsigned long flags;

#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_input_handle_event(&type, &code, &value);
#endif
\tif (is_event_supported(type, dev->evbit, EV_MAX)) {
"""
    s = replace_once(
        s, input_event_old, input_event_new,
        "stable input_event safe-mode callback",
    )

    inject_marker = "void input_inject_event(struct input_handle *handle,\n"
    pos = s.find(inject_marker)
    if pos < 0:
        raise SystemExit("[N45][KSUN-lifecycle] input_inject_event entrypoint not found")
    inject_old = """{
\tstruct input_dev *dev = handle->dev;
\tstruct input_handle *grab;
\tunsigned long flags;

\tif (is_event_supported(type, dev->evbit, EV_MAX)) {
"""
    inject_new = """{
\tstruct input_dev *dev = handle->dev;
\tstruct input_handle *grab;
\tunsigned long flags;

#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_input_handle_event(&type, &code, &value);
#endif
\tif (is_event_supported(type, dev->evbit, EV_MAX)) {
"""
    tail = s[pos:]
    if tail.count(inject_old) != 1:
        raise SystemExit(
            f"[N45][KSUN-lifecycle] expected one input_inject_event body anchor, got {tail.count(inject_old)}"
        )
    s = s[:pos] + tail.replace(inject_old, inject_new, 1)
write(path, s)


checks = {
    "fs/read_write.c": [
        "#ifdef CONFIG_KSU_MANUAL_HOOK",
        "ksu_handle_vfs_read(&file, &buf, &count, &pos);",
    ],
    "fs/stat.c": [
        "ksu_handle_newfstat_ret(&fd, &statbuf);",
        "ksu_handle_fstat64_ret(&fd, &statbuf);",
    ],
}
for filename, needles in checks.items():
    text = read(filename)
    for needle in needles:
        if needle not in text:
            raise SystemExit(
                f"[N45][KSUN-lifecycle] verification failed: {filename}: {needle}"
            )

# Input hook invariants: exactly two stable-entrypoint calls and zero calls in
# the private input_handle_event() body.
s = read("drivers/input/input.c")
if s.count(call) != 2:
    raise SystemExit(
        f"[N45][KSUN-lifecycle] expected two stable input hook calls, got {s.count(call)}"
    )
private_start = s.index("static void input_handle_event(struct input_dev *dev,")
public_start = s.index("void input_event(struct input_dev *dev,", private_start)
if call in s[private_start:public_start]:
    raise SystemExit(
        "[N45][KSUN-lifecycle] private input_handle_event hook unexpectedly present"
    )
inject_start = s.index("void input_inject_event(struct input_handle *handle,", public_start)
if call not in s[public_start:inject_start]:
    raise SystemExit("[N45][KSUN-lifecycle] input_event safe-mode hook missing")
if call not in s[inject_start:]:
    raise SystemExit("[N45][KSUN-lifecycle] input_inject_event safe-mode hook missing")

print("[N45][KSUN-lifecycle] init.rc/stat lifecycle + stable input safe-mode hooks restored")
