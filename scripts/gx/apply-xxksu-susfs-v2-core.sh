#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

KSU_DIR="$ROOT_DIR/KernelSU"
[[ -d "$KSU_DIR/kernel" ]] || {
  echo "[N45][xxKSU-SUSFS] KernelSU source missing" >&2
  exit 2
}

# Xiaomi 4.14.357 reference commit that de-inlines SUSFS v2.2 into xxKSU.
# Its snapshot is older than our backslashxx v3.3.0-2 / 32602 core, so only
# transplant the SUSFS glue; never replace/downgrade the whole xxKSU tree.
REF_REPO="FlopKernel-Series/flop_trinket-mi_kernel"
REF_SHA="2438eed1424e0c228612a0d55e3f85dc77d22b38"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/xxksu-susfs.patch"
PATCH="$TMP/xxksu-susfs-kernelsu.patch"

curl -fsSL --retry 4 --retry-delay 2 \
  "https://github.com/$REF_REPO/commit/$REF_SHA.patch" -o "$RAW"
grep -Fqi "$REF_SHA" "$RAW" || {
  echo "[N45][xxKSU-SUSFS] invalid reference patch" >&2
  exit 3
}

# Reference tree stores xxKSU in drivers/xxksu; our setup script integrates the
# exact pinned backslashxx core at KernelSU/. Rewrite only paths, not content.
#
# xxKSU 32602 also made try_umount() static inline after the reference adapter
# was authored. Preserve that newer declaration for the normal path, while the
# SUSFS TRY_UMOUNT branch still exports a plain global void function exactly as
# required by the v2 adapter. Match the actual hunk context instead of counting
# every textual occurrence in the mail-formatted commit patch.
python3 - "$RAW" "$PATCH" "$KSU_DIR/kernel/feature/kernel_umount.c" <<'PY'
from pathlib import Path
import sys
src, dst, umount_file = map(Path, sys.argv[1:])
s = src.read_text()
s = s.replace('a/drivers/xxksu/', 'a/KernelSU/')
s = s.replace('b/drivers/xxksu/', 'b/KernelSU/')
s = s.replace('--- drivers/xxksu/', '--- KernelSU/')
s = s.replace('+++ drivers/xxksu/', '+++ KernelSU/')

current = umount_file.read_text()
new_anchor = 'static inline void try_umount(const char *mnt, int flags)'
old_hunk = (
    '+#if !defined(CONFIG_KSU_SUSFS) || !defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n'
    ' static void try_umount(const char *mnt, int flags)\n'
)
new_hunk = (
    '+#if !defined(CONFIG_KSU_SUSFS) || !defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n'
    ' static inline void try_umount(const char *mnt, int flags)\n'
)
if new_anchor in current:
    if old_hunk not in s:
        raise SystemExit('reference try_umount hunk not found; refusing to guess')
    s = s.replace(old_hunk, new_hunk, 1)
    print('[N45][xxKSU-SUSFS] adapted try_umount declaration for xxKSU 32602')
elif 'static void try_umount(const char *mnt, int flags)' not in current:
    raise SystemExit('unexpected xxKSU try_umount declaration; refusing to guess')

dst.write_text(s)
PY

if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "[N45][xxKSU-SUSFS] adapter already present"
else
  if git apply --check "$PATCH" >/dev/null 2>&1; then
    git apply "$PATCH"
  else
    echo "[N45][xxKSU-SUSFS] 32602 context differs; trying checked offset apply"
    if ! patch --dry-run --batch --forward --fuzz=3 -p1 < "$PATCH" >"$TMP/apply.log" 2>&1; then
      cat "$TMP/apply.log" >&2 || true
      echo "[N45][xxKSU-SUSFS] 32602-specific core adaptation required" >&2
      exit 4
    fi
    patch --batch --forward --fuzz=3 -p1 < "$PATCH"
    if find KernelSU -name '*.rej' -print -quit | grep -q .; then
      echo "[N45][xxKSU-SUSFS] rejected hunk detected" >&2
      find KernelSU -name '*.rej' -print >&2
      exit 5
    fi
  fi
fi

# Verify the actual adapter semantics. The reference Makefile does not contain
# CONFIG_KSU_SUSFS; it only adds the SUSFS_VERSION probe, while the Kconfig owns
# the feature symbols.
grep -Fq 'config KSU_SUSFS' KernelSU/kernel/Kconfig || {
  echo "[N45][xxKSU-SUSFS] verify failed: KSU_SUSFS Kconfig missing" >&2
  exit 6
}
grep -Fq 'SUSFS_VERSION' KernelSU/kernel/Makefile || {
  echo "[N45][xxKSU-SUSFS] verify failed: SUSFS_VERSION Makefile probe missing" >&2
  exit 6
}
grep -Rqs 'susfs' KernelSU/kernel/supercall KernelSU/kernel/selinux KernelSU/kernel/feature || {
  echo "[N45][xxKSU-SUSFS] verify failed: SUSFS core glue missing" >&2
  exit 6
}

# Prove that TRY_UMOUNT can call the exported helper on the pinned 32602 core.
grep -Fq '#if !defined(CONFIG_KSU_SUSFS) || !defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)' \
  KernelSU/kernel/feature/kernel_umount.c || {
  echo "[N45][xxKSU-SUSFS] verify failed: TRY_UMOUNT conditional missing" >&2
  exit 6
}
grep -Fq 'void try_umount(const char *mnt, int flags)' \
  KernelSU/kernel/feature/kernel_umount.c || {
  echo "[N45][xxKSU-SUSFS] verify failed: exported try_umount missing" >&2
  exit 6
}

echo "[N45][xxKSU-SUSFS] adapter verification passed"
echo "[N45][xxKSU-SUSFS] SUSFS v2 core adapter applied on pinned xxKSU 32602"
