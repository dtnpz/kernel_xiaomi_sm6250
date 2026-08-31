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
KERNEL_PATCH="$SUS_DIR/kernel_patches/50_add_susfs_in_kernel-4.14.patch"

# First do dry-runs so a partial patch is never mistaken for a valid layer.
if ! (cd "$KSU_DIR" && patch --dry-run --forward -p1 < "$KSU_PATCH"); then
  echo "[N45] SUSFS KernelSU patch does not apply cleanly to $root_kind; adaptation required." >&2
  exit 5
fi
if ! patch --dry-run --forward -p1 < "$KERNEL_PATCH"; then
  echo "[N45] SUSFS 4.14 kernel patch does not apply cleanly to this vendor tree; adaptation required." >&2
  exit 6
fi

(cd "$KSU_DIR" && patch --forward -p1 < "$KSU_PATCH")
patch --forward -p1 < "$KERNEL_PATCH"

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

echo "[N45] SUSFS 4.14 layer applied cleanly"
