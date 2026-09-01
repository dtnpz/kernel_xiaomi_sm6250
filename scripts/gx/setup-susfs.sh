#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

root_kind="${1:?usage: setup-susfs.sh <xxksu|ksun>}"
case "$root_kind" in
  xxksu) KSU_DIR="$ROOT_DIR/KernelSU" ;;
  ksun)  KSU_DIR="$ROOT_DIR/KernelSU-Next" ;;
  *) echo "Unsupported SUSFS root kind: $root_kind" >&2; exit 2 ;;
esac

if [[ ! -d "$KSU_DIR" ]]; then
  echo "KernelSU source directory missing before SUSFS setup: $KSU_DIR" >&2
  exit 2
fi

SUS_DIR="$ROOT_DIR/.gx-susfs-src"
rm -rf "$SUS_DIR"
git clone -q "$SUSFS_REPO" "$SUS_DIR"
git -C "$SUS_DIR" checkout -q "$SUSFS_COMMIT"
actual="$(git -C "$SUS_DIR" rev-parse HEAD)"
if [[ "$actual" != "$SUSFS_COMMIT" ]]; then
  echo "SUSFS pin mismatch: expected $SUSFS_COMMIT got $actual" >&2
  exit 4
fi

echo "[N45] applying SUSFS ${SUSFS_COMMIT} to $root_kind"
cp -f "$SUS_DIR"/kernel_patches/fs/* fs/
cp -f "$SUS_DIR"/kernel_patches/include/linux/* include/linux/

KERNEL_PATCH_SOURCE="$SUS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch"
KERNEL_PATCH_TMP="$(mktemp)"
cp -f "$KERNEL_PATCH_SOURCE" "$KERNEL_PATCH_TMP"
KERNEL_PATCH="$KERNEL_PATCH_TMP"
KSU_PATCH="$SUS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
KSU_PATCH_TMP=""

# The stock SUSFS KSU patch targets the legacy upstream KernelSU layout.
# backslashxx v3.3.0-2 has a newer setuid/syscall/downstream layout. Pin the
# Aug-22 adapter whose source indexes match this generation and require a full
# dry-run before applying it. Only one source-context mismatch is adapted below:
# the first kernel_umount.c hunk expects a now-removed setuid block above the
# variable it changes. We perform that exact transformation ourselves, remove
# only that one hunk from the temporary patch, then dry-run every remaining hunk.
if [[ "$root_kind" == "xxksu" ]]; then
  XX_SUSFS_PATCH_COMMIT="f93ab9260f5bcf5c780c69763029722f44c98928"
  XX_SUSFS_PATCH_SHA256="8d037c8397ae7326936f976049c69579c10b5bf89ce8d50dea06bf7f566b4d47"
  KSU_PATCH_TMP="$(mktemp)"
  curl -fsSL --retry 3 --retry-delay 2 \
    "https://raw.githubusercontent.com/yapixel/popsicle_ksu_workflow/${XX_SUSFS_PATCH_COMMIT}/.github/patches/xxksu/11_enable_susfs_for_ksu.patch" \
    -o "$KSU_PATCH_TMP"

  actual_patch_sha="$(sha256sum "$KSU_PATCH_TMP" | awk '{print $1}')"
  if [[ "$actual_patch_sha" != "$XX_SUSFS_PATCH_SHA256" ]]; then
    echo "xxKSU SUSFS adapter checksum mismatch: expected $XX_SUSFS_PATCH_SHA256 got $actual_patch_sha" >&2
    exit 5
  fi
  grep -Fq 'Date: Sat, 22 Aug 2026' "$KSU_PATCH_TMP"
  grep -Fq 'Subject: [PATCH] susfs' "$KSU_PATCH_TMP"
  grep -Fq 'kernel/hook/setuid_hook.c' "$KSU_PATCH_TMP"
  grep -Fq 'kernel/downstream/ksu_hostsredirect.h' "$KSU_PATCH_TMP"

  python3 - "$KSU_DIR/kernel/feature/kernel_umount.c" "$KSU_PATCH_TMP" <<'PY'
from pathlib import Path
import sys

umount_path = Path(sys.argv[1])
patch_path = Path(sys.argv[2])

s = umount_path.read_text()
old = "static bool ksu_kernel_umount_enabled __read_mostly = true;"
new = """#ifndef CONFIG_KSU_SUSFS
static bool ksu_kernel_umount_enabled __read_mostly = true;
#else
bool ksu_kernel_umount_enabled __read_mostly = true;
#endif // #ifndef CONFIG_KSU_SUSFS"""
if s.count(old) != 1:
    raise SystemExit(f"expected exactly one xxKSU kernel_umount marker, found {s.count(old)}")
s = s.replace(old, new, 1)
umount_path.write_text(s)

lines = patch_path.read_text().splitlines(keepends=True)
diff_marker = "diff --git a/kernel/feature/kernel_umount.c b/kernel/feature/kernel_umount.c"
try:
    d = next(i for i, line in enumerate(lines) if line.rstrip("\r\n") == diff_marker)
except StopIteration:
    raise SystemExit("xxKSU SUSFS patch missing kernel_umount diff")

h1 = None
for i in range(d + 1, len(lines)):
    if lines[i].startswith("diff --git "):
        break
    if lines[i].startswith("@@ "):
        h1 = i
        break
if h1 is None:
    raise SystemExit("xxKSU SUSFS patch missing first kernel_umount hunk")

h2 = None
for i in range(h1 + 1, len(lines)):
    if lines[i].startswith("@@ ") or lines[i].startswith("diff --git "):
        h2 = i
        break
if h2 is None or not lines[h2].startswith("@@ "):
    raise SystemExit("xxKSU SUSFS kernel_umount patch did not contain the expected second hunk")

removed = "".join(lines[h1:h2])
if "ksu_kernel_umount_enabled" not in removed:
    raise SystemExit("refusing to remove unexpected kernel_umount hunk")
del lines[h1:h2]
text = "".join(lines)
if not text.endswith("\n"):
    text += "\n"
patch_path.write_text(text)
PY

  echo "[N45] xxKSU SUSFS adapter sha256 verified: $actual_patch_sha"
  echo "[N45] adapted only kernel_umount first hunk for pinned xxKSU v3.3.0-2"
  KSU_PATCH="$KSU_PATCH_TMP"
fi
trap '[[ -z "${KSU_PATCH_TMP:-}" ]] || rm -f "$KSU_PATCH_TMP"; [[ -z "${KERNEL_PATCH_TMP:-}" ]] || rm -f "$KERNEL_PATCH_TMP"' EXIT

if ! (cd "$KSU_DIR" && patch --batch --dry-run --forward -p1 < "$KSU_PATCH"); then
  echo "[N45] SUSFS KernelSU patch does not apply cleanly to $root_kind; adaptation required." >&2
  exit 5
fi

# Keep the proven adapter intact; the wrapper changes only the brittle
# newuname() boundary parser to an exact unique-body transform.
python3 scripts/gx/run-adapt-susfs-414.py "$KERNEL_PATCH"
python3 scripts/gx/adapt-susfs-414-readdir-compat.py "$KERNEL_PATCH"

if ! patch --batch --dry-run --forward -p1 < "$KERNEL_PATCH"; then
  echo "[N45] adapted SUSFS 4.14 kernel patch still does not apply cleanly; further adaptation required." >&2
  exit 6
fi

(cd "$KSU_DIR" && patch --batch --forward -p1 < "$KSU_PATCH")
patch --batch --forward -p1 < "$KERNEL_PATCH"

python3 <<'PY'
from pathlib import Path
import re
p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()
key = 'KSU_SUSFS'
pat = re.compile(rf'^(?:CONFIG_{key}=.*|# CONFIG_{key} is not set)$', re.M)
line = 'CONFIG_KSU_SUSFS=y'
if pat.search(s):
    s = pat.sub(line, s)
else:
    if not s.endswith('\n'):
        s += '\n'
    s += line + '\n'
p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU_SUSFS=y' arch/arm64/configs/vendor/miatoll-perf_defconfig
[[ -s fs/susfs.c ]]
[[ -s include/linux/susfs.h ]]
grep -Fq 'config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig" 2>/dev/null || \
  grep -Fq 'config KSU_SUSFS' "$KSU_DIR/Kconfig"

echo "[N45] SUSFS 4.14 layer applied cleanly"
