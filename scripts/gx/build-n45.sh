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
TOOLCHAIN_DIR="${GX_TOOLCHAIN_DIR:-$HOME/tools/neutron-clang}"
OUT_DIR="$ROOT_DIR/out"
ARTIFACT_DIR="$ROOT_DIR/artifacts"
AK3_WORK="$ROOT_DIR/.gx-anykernel"

export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-gxter-Kernel-CI}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-zared}"

if [[ ! -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
  echo "[N45] Fetching public Neutron Clang toolchain..."
  rm -rf "$TOOLCHAIN_DIR"
  mkdir -p "$TOOLCHAIN_DIR"
  curl -fsSL https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman \
    -o "$TOOLCHAIN_DIR/antman"
  chmod +x "$TOOLCHAIN_DIR/antman"
  (
    cd "$TOOLCHAIN_DIR"
    ./antman -S
    ./antman --patch=glibc || true
  )
fi

if [[ ! -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
  echo "[N45] clang missing after toolchain setup: $TOOLCHAIN_DIR/bin/clang" >&2
  exit 2
fi

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export KBUILD_COMPILER_STRING="$(clang --version | head -n1 | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//')"

mkdir -p "$OUT_DIR" "$ARTIFACT_DIR"
rm -rf "$AK3_WORK"

# Every N45 variant is built from the same real OpenELA 4.14.357 eLTS delta.
# This runs before BP/KSU/SUSFS mutation so those layers stay comparable with
# the smooth NONKSU baseline.
bash scripts/gx/apply-openela-4.14.357.sh

printf '[N45] variant: %s\n' "$GX_VARIANT"
printf '[N45] defconfig: %s\n' "$DEFCONFIG"
printf '[N45] compiler: %s\n' "$KBUILD_COMPILER_STRING"
printf '[N45] kernel: %s\n' "$(make -s kernelversion)"

bash scripts/gx/prepare-variant.sh
bash scripts/gx/set-gxter-release.sh
bash scripts/gx/apply-bpf-mmapable-array-v2.sh
bash scripts/gx/apply-bpf-failure-trace.sh

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
  HOSTCC=clang \
  HOSTCXX=clang++ \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  LLVM=1 \
  LLVM_IAS=1 \
  KCFLAGS="-Wno-unknown-warning-option"

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

ZIP_PATH="$ARTIFACT_DIR/$GX_ZIP"
if [[ "$GX_ZIP" != *"4.14.357"* ]]; then
  echo "[N45] refusing stale/non-357 release filename: $GX_ZIP" >&2
  exit 4
fi

# A successful compile is not enough: prove that the delivered archive is
# readable and contains the complete AnyKernel flash payload with non-empty
# kernel/DTB/DTBO and recovery installer entries.
unzip -tqq "$ZIP_PATH"
ZIP_LIST="$(zipinfo -1 "$ZIP_PATH")"
required_entries=(
  anykernel.sh
  tools/ak3-core.sh
  Image.gz
  dtbo.img
  dtb
  META-INF/com/google/android/update-binary
  META-INF/com/google/android/updater-script
)
for entry in "${required_entries[@]}"; do
  if ! grep -Fxq "$entry" <<<"$ZIP_LIST"; then
    echo "[N45] flash ZIP missing required entry: $entry" >&2
    exit 5
  fi
  bytes="$(unzip -p "$ZIP_PATH" "$entry" | wc -c)"
  if [[ "$bytes" -le 0 ]]; then
    echo "[N45] flash ZIP contains empty required entry: $entry" >&2
    exit 6
  fi
done

echo "[N45] flash ZIP validation passed: $GX_ZIP"
sha256sum "$ZIP_PATH" > "$ZIP_PATH.sha256"
md5sum "$ZIP_PATH" > "$ZIP_PATH.md5"

printf '[N45] built %s\n' "$ZIP_PATH"
cat "$ZIP_PATH.sha256"
