#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

current="$(make -s kernelversion)"
case "$current" in
  4.14.357-openela)
    echo "[N45][eLTS] OpenELA 4.14.357 already present"
    exit 0
    ;;
  4.14.356-openela) ;;
  *)
    echo "[N45][eLTS] refusing unexpected starting kernel: $current" >&2
    exit 2
    ;;
esac

# The 4.14.357 eLTS release is six commits ahead of the exact 4.14.356
# OpenELA point N45 already carries. Do not fake this by only changing
# SUBLEVEL: apply the five fixes and then the official version bump.
ELTS_REPO="FlopKernel-Series/flop_trinket-mi_kernel"
ELTS_SERIES=(
  81cba5e1051d71a71d8d94f502c36b6cd05e5a95
  70649db1605f0502f5b73bd74ba57c90bed354b4
  b418fc71a9bde404862c4c58ca65c42eb1b3662e
  30c9d277838dcc00bc561d36ac88215123cc71f4
  a7cd6312e4773b26231480ac0a8c24f8a7b24f58
  1e6347375d088ecc896aabb067131d0f9e3c0575
)

PATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$PATCH_DIR"' EXIT

apply_elts_patch() {
  local sha="$1"
  local patch_file="$PATCH_DIR/$sha.patch"
  local url="https://github.com/$ELTS_REPO/commit/$sha.patch"

  echo "[N45][eLTS] $sha"
  curl -fsSL --retry 4 --retry-delay 2 "$url" -o "$patch_file"
  grep -Fqi "$sha" "$patch_file" || {
    echo "[N45][eLTS] downloaded patch does not identify $sha" >&2
    exit 3
  }

  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[N45][eLTS] already present: $sha"
    return 0
  fi

  if git apply --check "$patch_file" >/dev/null 2>&1; then
    git apply "$patch_file"
    return 0
  fi

  # Qualcomm adds vendor fields/context around otherwise identical upstream
  # structures (for example ll_node immediately before skb->sk).  Permit
  # shifted context only after a complete dry-run proves every hunk applies.
  # Never allow partial application or .rej files.
  echo "[N45][eLTS] exact context differs; trying checked Qualcomm-context apply"
  if ! patch --dry-run --batch --forward --fuzz=3 -p1 < "$patch_file" >"$PATCH_DIR/$sha.log" 2>&1; then
    cat "$PATCH_DIR/$sha.log" >&2 || true
    echo "[N45][eLTS] semantic adaptation required at $sha" >&2
    exit 4
  fi
  patch --batch --forward --fuzz=3 -p1 < "$patch_file"
  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "[N45][eLTS] rejected hunk detected after $sha" >&2
    find . -name '*.rej' -print >&2
    exit 5
  fi
}

for sha in "${ELTS_SERIES[@]}"; do
  apply_elts_patch "$sha"
done

[[ "$(make -s kernelversion)" == "4.14.357-openela" ]] || {
  echo "[N45][eLTS] version did not advance to 4.14.357-openela" >&2
  exit 6
}

echo "[N45][eLTS] real OpenELA 4.14.357 delta applied"
