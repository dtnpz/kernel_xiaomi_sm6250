#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

root_kind="${1:?usage: setup-susfs.sh <xxksu|ksun>}"
case "$root_kind" in
  ksun) KSU_DIR="$ROOT_DIR/KernelSU-Next" ;;
  xxksu)
    echo "[N45] SUSFS v2.2.0 xxKSU glue is intentionally handled separately; refusing to reuse KSUN glue." >&2
    exit 3
    ;;
  *) echo "Unsupported SUSFS root kind: $root_kind" >&2; exit 2 ;;
esac

[[ -d "$KSU_DIR" ]] || { echo "KernelSU source directory missing: $KSU_DIR" >&2; exit 2; }
[[ "$SUSFS_414_BACKPORT_VERSION" == "v2.2.0" ]] || { echo "Unexpected SUSFS backport version pin" >&2; exit 4; }
[[ "$SUSFS_414_BACKPORT_HEAD" == "0a5b29d63113137f481d2636af5e943631b76687" ]] || { echo "Unexpected SUSFS v2.2.0 head pin" >&2; exit 4; }

echo "[N45] applying non-GKI Linux 4.14 SUSFS ${SUSFS_414_BACKPORT_VERSION} backport"

PATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$PATCH_DIR"' EXIT

# Required compatibility backports for the 4.14 SUSFS v2 line, followed by
# only the SUSFS-specific evolution through the pinned v2.2.0 commit.
# These SHAs come from sidex15/android_kernel_lge_sm8150 (Linux 4.14.355).
SUSFS_414_PATCH_SERIES=(
  d406904bb175cb9791b5aed4404df3268859d91b
  9ba899398576d329288b023566d3a731470ad13a
  e784224542fab4b3888d9103a1f678015221a7d1
  ed8fd10d97a50ec424ae38a40351b5de060f9838
  4ba6dccf73a620e565803e5995d5748ecfbb56a2
  0a8cbf3725edbacc5f1ead33eeae7e4d78823b5a
  37ae2444584654f6785f2cc49181f05af788c9b2
  49a5115e11350ee68f6a5fbd56b3e817bf9e5aac
  6f94042bed51121f8f28a5e572cda20c21fed2e1
  bbd5aec12b32097a71dc6a0097194a18f3ee9a17
  849ca8ce954d9dbb082dcf83c98af861e98e5635
  6071a482c8e603be25895cc2cac5f0eab61c4051
  03fd2fbe9c40da8128cec5c69ef54755c0f38c6c
  95f8be4c8a86a491a1c2ac9bfe470aef9e1baa8f
  27956d255e3b012372951dd6131e07c106d2daae
  7f2847d02cdc4491b5ee6d4a0043854cbd6c7a1a
  bb2f164bc19795ef704f17c82f04885d44421418
  1f4ef7d7978c4a74812c2445ebfac02fd451e068
  65fb7abff9ce217729b0c4cddf76e76522b636b6
  b052cc180226f02767c53f9e56493c69ceaeb9b5
  823b35a5e182ffab87515ed289aad264df29c3f6
  b58b69522b102679e94656e506ce927f3490e07d
  054fb29e19dcf9c2c1308781e25b94de8a89f248
  b69c8cff50ae4306153ab318bf84f9eb3d6d3f88
  95e2704328adb98c35bc280481eec62b60aeeea2
  b34d30c5b6c4fe2fbc7316301ecad787c27d2481
  3ebef172ec55f37d15bb3b8e86af9c3b5e91e9cc
  f23710644821ef01f6c4d88675d2820b6ee53f74
  817d1c4d534e64a2e5d4f9981924c9ebcf5cd5de
  9051376aa276eae8c8845f5960d15438dce7c9c5
  98d744aaa843226800b924282b1ffdb3fae41f0f
  8cb32a1c13ce6c12b05008126f47114f35925a14
  e23498ee3cbcbd71ccac95c7aa724deaff17d957
  30dd021c189d55a8d043048bad330633b8fdc5a9
  e58820631a8fca7bd29ee647987aeb92c0bc2ea8
  7b01d7070d8a24eb981819b69817afdee1893385
  3b3b47ad7071dea88ea95b444981e38ab0160b90
  a7d543c780618f411845d9da6e4c9ede4effa8ae
  51e6f383585a3ceedd3c3e3c00c81361831d4d24
  790b90dce92d036d11d44d9d8ae642ffd4a99f0b
  4a1631c91a67b6400586fd5f1f97cea339c2c1ad
  0223817cca2c2f32bb5b68966c5a7103aaea6e4b
  c07594f674038b1135f62c84c0a7ff7cf7c9efff
  b445ec817c8123d8f037ceab3d92b795d2f5c1b8
  b287bdaa530d53fc23b2f539c4f112a314c64d26
  263d2d2b7bc2726354f43a5368ed59a18ace01b9
  0a5b29d63113137f481d2636af5e943631b76687
)

apply_ref_patch() {
  local sha="$1"
  local patch_file="$PATCH_DIR/$sha.patch"
  local url="https://github.com/sidex15/android_kernel_lge_sm8150/commit/$sha.patch"

  echo "[N45][SUSFS-v2] $sha"
  curl -fsSL --retry 4 --retry-delay 2 "$url" -o "$patch_file"
  grep -Fqi "$sha" "$patch_file" || {
    echo "Downloaded patch does not identify expected commit $sha" >&2
    exit 6
  }

  # OpenELA or an earlier integration may already contain a prerequisite.
  if patch --batch --dry-run --reverse -p1 < "$patch_file" >/dev/null 2>&1; then
    echo "[N45][SUSFS-v2] already present: $sha"
    return 0
  fi

  if ! patch --batch --dry-run --forward -p1 < "$patch_file"; then
    echo "[N45][SUSFS-v2] patch $sha does not apply to the N45 tree; adapt this exact commit next." >&2
    exit 7
  fi
  patch --batch --forward -p1 < "$patch_file"
}

for sha in "${SUSFS_414_PATCH_SERIES[@]}"; do
  apply_ref_patch "$sha"
done

python3 - arch/arm64/configs/vendor/miatoll-perf_defconfig <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
settings = {
    'KSU': 'y',
    'KSU_MANUAL_HOOK': 'y',
    'KSU_KPROBES_HOOK': 'n',
    'KSU_SUSFS': 'y',
    'KSU_SUSFS_SUS_PATH': 'y',
    'KSU_SUSFS_SUS_MOUNT': 'y',
    'KSU_SUSFS_SUS_KSTAT': 'y',
    'KSU_SUSFS_TRY_UMOUNT': 'y',
    'KSU_SUSFS_SPOOF_UNAME': 'y',
    'KSU_SUSFS_ENABLE_LOG': 'n',
    'KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS': 'y',
    'KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG': 'y',
    'KSU_SUSFS_OPEN_REDIRECT': 'y',
    'KSU_SUSFS_SUS_MAP': 'y',
    # SUS_MEMFD landed after the v2.2.0 baseline and is explicitly experimental.
    'KSU_SUSFS_SUS_MEMFD': 'n',
}
for key, value in settings.items():
    pat = re.compile(rf'^(?:CONFIG_{re.escape(key)}=.*|# CONFIG_{re.escape(key)} is not set)$', re.M)
    line = f'CONFIG_{key}={value}' if value != 'n' else f'# CONFIG_{key} is not set'
    if pat.search(s):
        s = pat.sub(line, s, count=1)
    else:
        if not s.endswith('\n'):
            s += '\n'
        s += line + '\n'
p.write_text(s)
PY

DEFCONFIG=arch/arm64/configs/vendor/miatoll-perf_defconfig
grep -Fxq 'CONFIG_KSU_SUSFS=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_SUSFS_SUS_MAP=y' "$DEFCONFIG"
grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
[[ -s fs/susfs.c ]]
[[ -s include/linux/susfs.h ]]
grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h
grep -Fq 'config KSU_SUSFS_SUS_MAP' "$KSU_DIR/kernel/Kconfig"

echo "[N45] SUSFS v2.2.0 Linux 4.14 layer applied; SUS_MAP retained"
