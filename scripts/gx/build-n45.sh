#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

if [[ ! -f .gx-variant ]]; then
  echo "Missing .gx-variant metadata; refusing ambiguous variant build." >&2
  exit 2
fi

# shellcheck disable=SC1091
source .gx-variant

: "${GX_VARIANT:?GX_VARIANT missing from .gx-variant}"
: "${GX_ZIP:?GX_ZIP missing from .gx-variant}"

DEFCONFIG="${GX_DEFCONFIG:-vendor/miatoll-perf_defconfig}"
TOOLCHAIN_DIR="${GX_TOOLCHAIN_DIR:-$HOME/tools/yuki-clang}"
OUT_DIR="$ROOT_DIR/out"
ARTIFACT_DIR="$ROOT_DIR/artifacts"
AK3_WORK="$ROOT_DIR/.gx-anykernel"

export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Github-CI}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-gx-n45}"

if [[ ! -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
  echo "[N45] Cloning the tree's known-working Yuki clang toolchain..."
  mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
  git clone -q --depth=1 --single-branch \
    https://bitbucket.org/thexperienceproject/yuki-clang.git \
    "$TOOLCHAIN_DIR"
fi

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export KBUILD_COMPILER_STRING="$(clang --version | head -n1 | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//')"

mkdir -p "$OUT_DIR" "$ARTIFACT_DIR"
rm -rf "$AK3_WORK"

printf '[N45] variant: %s\n' "$GX_VARIANT"
printf '[N45] defconfig: %s\n' "$DEFCONFIG"
printf '[N45] compiler: %s\n' "$KBUILD_COMPILER_STRING"
printf '[N45] kernel: %s\n' "$(make -s kernelversion)"

# Keep variant preparation explicit and reproducible. This is a no-op for
# NONKSU-NBP and adds only the layers described by .gx-variant for others.
bash scripts/gx/prepare-variant.sh

# Clean out-of-tree build. Do not mutate source defconfigs during CI.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
make O="$OUT_DIR" "$DEFCONFIG"

make -j"$(nproc --all)" O="$OUT_DIR" \
  ARCH=arm64 \
  CC=clang \
  LD=ld.lld \
  AR=llvm-ar \
  NM=llvm-nm \
  OBJCOPY=llvm-objcopy \
  OBJDUMP=llvm-objdump \
  STRIP=llvm-strip \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  LLVM=1 \
  LLVM_IAS=1

IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
DTBO="$OUT_DIR/arch/arm64/boot/dtbo.img"
DTB="$OUT_DIR/arch/arm64/boot/dts/qcom/cust-atoll-ab.dtb"
CONFIG="$OUT_DIR/.config"

for f in "$IMAGE" "$DTBO" "$DTB" "$CONFIG"; do
  if [[ ! -s "$f" ]]; then
    echo "[N45] required build output missing/empty: $f" >&2
    exit 3
  fi
done

# Record the exact effective configuration and source identity before packing.
cp "$CONFIG" "$ARTIFACT_DIR/${GX_VARIANT}.config"
{
  echo "variant=$GX_VARIANT"
  echo "zip=$GX_ZIP"
  echo "source_commit=$(git rev-parse HEAD)"
  echo "kernelversion=$(make -s kernelversion)"
  echo "compiler=$KBUILD_COMPILER_STRING"
  echo "defconfig=$DEFCONFIG"
  echo "root=${GX_ROOT:-none}"
  echo "susfs=${GX_SUSFS:-0}"
  echo "bp=${GX_BP:-0}"
} > "$ARTIFACT_DIR/${GX_VARIANT}.build-info.txt"

cp -a AnyKernel3 "$AK3_WORK"
rm -rf "$AK3_WORK/.git" "$AK3_WORK/.github"
rm -f "$AK3_WORK/Image" "$AK3_WORK/Image.gz" "$AK3_WORK/Image.gz-dtb" \
      "$AK3_WORK/dtb" "$AK3_WORK/dtbo.img"
cp "$IMAGE" "$AK3_WORK/Image.gz"
cp "$DTBO" "$AK3_WORK/dtbo.img"
cp "$DTB" "$AK3_WORK/dtb"

(
  cd "$AK3_WORK"
  zip -qr9 "$ARTIFACT_DIR/$GX_ZIP" . \
    -x 'README*' 'LICENSE*' '*.git*' '*placeholder*'
)

sha256sum "$ARTIFACT_DIR/$GX_ZIP" > "$ARTIFACT_DIR/$GX_ZIP.sha256"
md5sum "$ARTIFACT_DIR/$GX_ZIP" > "$ARTIFACT_DIR/$GX_ZIP.md5"

printf '[N45] built %s\n' "$ARTIFACT_DIR/$GX_ZIP"
cat "$ARTIFACT_DIR/$GX_ZIP.sha256"
