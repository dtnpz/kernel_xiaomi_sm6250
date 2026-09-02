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
python3 - "$RAW" "$PATCH" <<'PY'
from pathlib import Path
import sys
src, dst = map(Path, sys.argv[1:])
s = src.read_text()
s = s.replace('a/drivers/xxksu/', 'a/KernelSU/')
s = s.replace('b/drivers/xxksu/', 'b/KernelSU/')
s = s.replace('--- drivers/xxksu/', '--- KernelSU/')
s = s.replace('+++ drivers/xxksu/', '+++ KernelSU/')
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

grep -Fq 'config KSU_SUSFS' KernelSU/kernel/Kconfig
grep -Fq 'CONFIG_KSU_SUSFS' KernelSU/kernel/Makefile
grep -Rqs 'susfs' KernelSU/kernel/supercall KernelSU/kernel/selinux KernelSU/kernel/feature

echo "[N45][xxKSU-SUSFS] SUSFS v2 core adapter applied on pinned xxKSU 32602"
