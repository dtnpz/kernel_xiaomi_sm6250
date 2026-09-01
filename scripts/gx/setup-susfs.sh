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
  grep -Fq 'kernel/supercall/supercall.c' "$KSU_PATCH_TMP"

  python3 scripts/gx/adapt-xxksu-susfs-v155.py "$KSU_DIR" "$KSU_PATCH_TMP"
  echo "[N45] xxKSU SUSFS adapter sha256 verified: $actual_patch_sha"
  echo "[N45] adapted modern xxKSU glue to pinned SUSFS v1.5.5"
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

# The modern xxKSU adapter advertises SUS_MAP, but pinned SUSFS v1.5.5 has no
# such implementation. Remove only that exact menu block after the verified
# adapter applies so the effective config remains truthful.
if [[ "$root_kind" == "xxksu" ]]; then
  python3 - "$KSU_DIR/kernel/Kconfig" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
start = s.find('config KSU_SUSFS_SUS_MAP\n')
if start != -1:
    end = s.find('\nendmenu\n', start)
    if end == -1:
        raise SystemExit('xxKSU Kconfig SUS_MAP block has no menu terminator')
    block = s[start:end]
    if 'hide some mmapped real file' not in block or 'depends on KSU_SUSFS' not in block:
        raise SystemExit('refusing unexpected xxKSU SUS_MAP block removal')
    p.write_text(s[:start] + s[end:])
PY
fi

python3 <<'PY'
from pathlib import Path
import re
p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text(); key = 'KSU_SUSFS'
pat = re.compile(rf'^(?:CONFIG_{key}=.*|# CONFIG_{key} is not set)$', re.M)
line = 'CONFIG_KSU_SUSFS=y'
if pat.search(s): s = pat.sub(line, s)
else:
    if not s.endswith('\n'): s += '\n'
    s += line + '\n'
p.write_text(s)
PY

grep -Fxq 'CONFIG_KSU_SUSFS=y' arch/arm64/configs/vendor/miatoll-perf_defconfig
[[ -s fs/susfs.c ]]
[[ -s include/linux/susfs.h ]]
grep -Fq 'config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig" 2>/dev/null || grep -Fq 'config KSU_SUSFS' "$KSU_DIR/Kconfig"
! grep -Fq 'config KSU_SUSFS_SUS_MAP' "$KSU_DIR/kernel/Kconfig"

echo "[N45] SUSFS 4.14 layer applied cleanly"
