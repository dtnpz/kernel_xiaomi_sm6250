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
# OpenELA point N45 already carries.  Do not fake this by only changing
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

for sha in "${ELTS_SERIES[@]}"; do
  patch_file="$PATCH_DIR/$sha.patch"
  url="https://github.com/$ELTS_REPO/commit/$sha.patch"
  echo "[N45][eLTS] $sha"
  curl -fsSL --retry 4 --retry-delay 2 "$url" -o "$patch_file"
  grep -Fqi "$sha" "$patch_file" || {
    echo "[N45][eLTS] downloaded patch does not identify $sha" >&2
    exit 3
  }

  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[N45][eLTS] already present: $sha"
    continue
  fi

  if ! git apply --check "$patch_file"; then
    echo "[N45][eLTS] 4.14.357 delta conflict at $sha" >&2
    exit 4
  fi
  git apply "$patch_file"
done

[[ "$(make -s kernelversion)" == "4.14.357-openela" ]] || {
  echo "[N45][eLTS] version did not advance to 4.14.357-openela" >&2
  exit 5
}

echo "[N45][eLTS] real OpenELA 4.14.357 delta applied"
