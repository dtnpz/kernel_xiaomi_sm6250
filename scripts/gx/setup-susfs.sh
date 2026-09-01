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

KSU_PATCH="$SUS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
KERNEL_PATCH_SOURCE="$SUS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch"
KERNEL_PATCH_TMP="$(mktemp)"
cp -f "$KERNEL_PATCH_SOURCE" "$KERNEL_PATCH_TMP"
KERNEL_PATCH="$KERNEL_PATCH_TMP"
KSU_PATCH_TMP=""

if [[ "$root_kind" == "ksun" ]]; then
  KSUN_SUSFS_PATCH_COMMIT="77c78b0ef6f8701274ed71f2e0ae3d06f2397064"
  KSUN_SUSFS_PATCH_SHA256="34cb19098d38886e983700a5806ef677b79bdad5381f03db463652fb397e4b25"
  KSU_PATCH_TMP="$(mktemp)"
  curl -fsSL --retry 3 --retry-delay 2 \
    "https://raw.githubusercontent.com/xfwdrev/android_kernel_samsung_ex2100/${KSUN_SUSFS_PATCH_COMMIT}/patches/enable-susfs.patch" \
    -o "$KSU_PATCH_TMP"

  actual_patch_sha="$(sha256sum "$KSU_PATCH_TMP" | awk '{print $1}')"
  if [[ "$actual_patch_sha" != "$KSUN_SUSFS_PATCH_SHA256" ]]; then
    echo "KSUN SUSFS adapter checksum mismatch: expected $KSUN_SUSFS_PATCH_SHA256 got $actual_patch_sha" >&2
    exit 5
  fi
  grep -Fq 'Subject: [PATCH] Patch KSU Next enable SuSFS 2.2.0 with de-inlined hooks' "$KSU_PATCH_TMP"
  grep -Fq 'index 5d1ad6e4..' "$KSU_PATCH_TMP"
  grep -Fq 'kernel/feature/kernel_umount.c' "$KSU_PATCH_TMP"
  grep -Fq 'kernel/hook/setuid_hook.c' "$KSU_PATCH_TMP"
  grep -Fq 'kernel/supercall/dispatch.c' "$KSU_PATCH_TMP"

  python3 - "$KSU_PATCH_TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
marker = "diff --git a/kernel/Kbuild b/kernel/Kbuild"
try:
    start = next(i for i, line in enumerate(lines) if line.rstrip("\r\n") == marker)
except StopIteration:
    raise SystemExit("KSUN SUSFS adapter missing expected Kbuild metadata diff")
end = None
for i in range(start + 1, len(lines)):
    if lines[i].startswith("diff --git "):
        end = i
        break
if end is None:
    raise SystemExit("KSUN SUSFS adapter malformed after Kbuild diff")
removed = "".join(lines[start:end])
if "KSU_GIT_TAG := v3.3.0-legacy-unofficial" not in removed:
    raise SystemExit("refusing to strip unexpected KSUN Kbuild diff")
del lines[start:end]
text = "".join(lines)
if not text.endswith("\n"):
    text += "\n"
p.write_text(text)
PY

  python3 scripts/gx/adapt-ksun-susfs-v155.py "$KSU_DIR" "$KSU_PATCH_TMP"
  echo "[N45] KSUN SUSFS adapter sha256 verified: $actual_patch_sha"
  echo "[N45] preserved pinned KSUN Kbuild logic and adapted 2.2-only APIs to v1.5.5"
  KSU_PATCH="$KSU_PATCH_TMP"
fi
trap '[[ -z "${KSU_PATCH_TMP:-}" ]] || rm -f "$KSU_PATCH_TMP"; [[ -z "${KERNEL_PATCH_TMP:-}" ]] || rm -f "$KERNEL_PATCH_TMP"' EXIT

if ! (cd "$KSU_DIR" && patch --batch --dry-run --forward -p1 < "$KSU_PATCH"); then
  echo "[N45] SUSFS KernelSU patch does not apply cleanly to $root_kind; adaptation required." >&2
  exit 5
fi

python3 scripts/gx/run-adapt-susfs-414.py "$KERNEL_PATCH"
python3 scripts/gx/adapt-susfs-414-readdir-compat.py "$KERNEL_PATCH"

if ! patch --batch --dry-run --forward -p1 < "$KERNEL_PATCH"; then
  echo "[N45] adapted SUSFS 4.14 kernel patch still does not apply cleanly; further adaptation required." >&2
  exit 6
fi

(cd "$KSU_DIR" && patch --batch --forward -p1 < "$KSU_PATCH")
patch --batch --forward -p1 < "$KERNEL_PATCH"

# The pinned v1.5.5 core has no SUS_MAP implementation. Remove the 2.2-only
# menu entry after the verified adapter applies so effective .config cannot
# advertise a feature that is not present.
if [[ "$root_kind" == "ksun" ]]; then
  python3 - "$KSU_DIR/kernel/Kconfig" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
start = s.find('config KSU_SUSFS_SUS_MAP\n')
if start != -1:
    end = s.find('\nendmenu\n', start)
    if end == -1:
        raise SystemExit('KSUN Kconfig SUS_MAP block has no menu terminator')
    block = s[start:end]
    if 'hide some mmapped real file' not in block or 'depends on KSU_SUSFS' not in block:
        raise SystemExit('refusing unexpected KSUN SUS_MAP block removal')
    s = s[:start] + s[end:]
    p.write_text(s)
PY
fi

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
grep -Fq 'config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig"
! grep -Fq 'config KSU_SUSFS_SUS_MAP' "$KSU_DIR/kernel/Kconfig"

echo "[N45] SUSFS 4.14 layer applied cleanly"
