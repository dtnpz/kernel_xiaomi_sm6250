#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source gx-sources.lock

root_kind="${1:?usage: setup-susfs.sh <xxksu|ksun>}"
case "$root_kind" in
  ksun) KSU_DIR="$ROOT_DIR/KernelSU-Next" ;;
  xxksu) KSU_DIR="$ROOT_DIR/KernelSU" ;;
  *) echo "Unsupported SUSFS root kind: $root_kind" >&2; exit 2 ;;
esac

[[ -d "$KSU_DIR" ]] || { echo "KernelSU source directory missing: $KSU_DIR" >&2; exit 2; }

# The Xiaomi 4.14.357 xxKSU reference carries a small SUSFS adapter for the
# root core. Transplant only that adapter onto our newer pinned 32602 core;
# never replace/downgrade the backslashxx tree.
if [[ "$root_kind" == "xxksu" ]]; then
  bash scripts/gx/apply-xxksu-susfs-v2-core.sh
fi

echo "[N45] applying non-GKI Linux 4.14 SUSFS v2.2.0 backport for $root_kind"

PATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$PATCH_DIR"' EXIT

# Modern SUSFS mount-id code needs the newer IDA API. This five-commit chain
# already applies cleanly to N45. Keep it strict; these are API prerequisites.
IDA_REPO="sidex15/android_kernel_lge_sm8150"
IDA_SERIES=(
  4ba6dccf73a620e565803e5995d5748ecfbb56a2
  ed8fd10d97a50ec424ae38a40351b5de060f9838
  e784224542fab4b3888d9103a1f678015221a7d1
  9ba899398576d329288b023566d3a731470ad13a
  d406904bb175cb9791b5aed4404df3268859d91b
)

# Xiaomi/Qualcomm trinket 4.14.357-openela is the compatibility reference for
# the actual SUSFS layer. Apply the SUSFS evolution through v2.2.0.
SUSFS_REPO="FlopKernel-Series/flop_trinket-mi_kernel"
SUSFS_SERIES=(
  90c3411026a2a55f96d2dc7046567b20b8b0d18f
  867a1638a7832bf9a1e0d63a62932a24139ba8ae
  9c648d040a6264e0a337d50b2e244c39047c76c6
  eb238aae838743f2da4f675c5164c7e97e198d82
  1b4f90acba4033f8cdf6b40b2df9a4c5f15d4388
  c389e1279b263872a4096824dbb92b667bc41f6a
  74a09f63dba838c872d457822ca6f38ab645c5e5
  5ad0535b268f74e3db73a9323022e4315b8a2c14
  883341d66d383753b4e7c0166e1033c21272e780
  c70572615132919caa23f9b00a72d1b943021787
  7c6e9ce0c136ee125d78486faeebd31ee162fd45
  6aeceddf784dbddd0538dc0506c75eb7522a4d43
  1a7e1a4e7d3847e12da7abe58bc63622e659e315
  85a5fbc10c053204d76123e9fbda064ea7d912eb
  f22598112e90c0b72ad08f59df7bf89dbd47ca6f
  8835c0d45106d400df092eeb9354840c6665741c
  67f2045956de4e050145f0d3f1ad3ea1d0ba47d0
  625df5ab4efa301caa14fe82c89b7df0c695f3f3
  74ed015e7a276169a43ab7e51c64f0f0eaaf292d
  2e5a748cf3f3fe1c385db26e8fe475267463ff6f
  bbb6a17411063bf08cf61775c7fce605c87003bd
  0f0d42d53f300ea7d620d46d175393e5b2cc085a
  ebdaf2e3db9525b06d8c11bb1946d7313066ba20
  1bf2ef2b94dbba9d6f3a1632bea7ccc1b928abd3
  016a0cd1f2fc8fdc420f943a5e27c57af22d7edc
  8f0dc40daad64df238acf648fe696263e8a76981
  5605d61a88136a35928147ab8dabcf0bb925fc22
  e9d86a305719542588cadae735d7166cd4aeeb55
  11427eb954c36ea8eedb092fa411f82a6f51c7b5
  7c15be48d89d1dc324aa17909b8357b081e97c24
  b3d2d7c84abbc657c5b7db448f1110b989969d68
)

# These files have N45/Qualcomm hot-path implementations and obsolete Velvet
# callbacks around the same functions. Replaying historical versions causes
# conflicts and can regress performance. Exclude them from every historical
# patch and adapt them once to final v2.2 state after the series.
N45_FINAL_ADAPTER_FILES=(
  fs/exec.c
  fs/open.c
  fs/proc/task_mmu.c
  fs/stat.c
  kernel/reboot.c
)

download_patch() {
  local repo="$1" sha="$2" out="$3"
  local url="https://github.com/$repo/commit/$sha.patch"
  curl -fsSL --retry 4 --retry-delay 2 "$url" -o "$out"
  grep -Fqi "$sha" "$out" || {
    echo "Downloaded patch does not identify expected commit $sha" >&2
    exit 6
  }
}

filter_n45_final_adapter_files() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "${N45_FINAL_ADAPTER_FILES[@]}" <<'PY'
from pathlib import Path
import re, sys
src, dst, *skip = sys.argv[1:]
skip = set(skip)
lines = Path(src).read_text().splitlines(keepends=True)
out = []
keep = True
seen_diff = False
for line in lines:
    m = re.match(r'^diff --git a/(.+?) b/(.+?)\s*$', line)
    if m:
        seen_diff = True
        keep = m.group(1) not in skip and m.group(2) not in skip
    if not seen_diff or keep:
        out.append(line)
Path(dst).write_text(''.join(out))
PY
}

apply_strict_patch() {
  local repo="$1" sha="$2" patch_file="$PATCH_DIR/$sha.patch"
  echo "[N45][SUSFS-v2][$repo] $sha"
  download_patch "$repo" "$sha" "$patch_file"
  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[N45][SUSFS-v2] already present: $sha"
    return 0
  fi
  if ! git apply --check "$patch_file"; then
    echo "[N45][SUSFS-v2] strict prerequisite conflict at $sha" >&2
    exit 7
  fi
  git apply "$patch_file"
}

apply_vendor_patch() {
  local repo="$1" sha="$2"
  local raw_patch="$PATCH_DIR/$sha.patch"
  local patch_file="$PATCH_DIR/$sha.filtered.patch"
  echo "[N45][SUSFS-v2][$repo] $sha"
  download_patch "$repo" "$sha" "$raw_patch"
  filter_n45_final_adapter_files "$raw_patch" "$patch_file"

  # A commit may only touch one of the excluded files.
  if ! grep -q '^diff --git ' "$patch_file"; then
    echo "[N45][SUSFS-v2] all hunks handled by final N45 adapter: $sha"
    return 0
  fi

  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[N45][SUSFS-v2] filtered patch already present: $sha"
    return 0
  fi

  if git apply --check "$patch_file" >/dev/null 2>&1; then
    git apply "$patch_file"
    return 0
  fi

  # Remaining files are close Xiaomi/Qualcomm layouts. Permit shifted context
  # only after a complete dry-run proves every hunk applies. Never allow
  # partial application or rejected hunks.
  echo "[N45][SUSFS-v2] exact context differs; trying checked vendor-offset apply"
  if ! patch --dry-run --batch --forward --fuzz=3 -p1 < "$patch_file" >"$PATCH_DIR/$sha.log" 2>&1; then
    cat "$PATCH_DIR/$sha.log" >&2 || true
    echo "[N45][SUSFS-v2] vendor adaptation still required at $sha" >&2
    exit 8
  fi
  patch --batch --forward --fuzz=3 -p1 < "$patch_file"
  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "[N45][SUSFS-v2] rejected hunk detected after $sha" >&2
    find . -name '*.rej' -print >&2
    exit 9
  fi
}

for sha in "${IDA_SERIES[@]}"; do
  apply_strict_patch "$IDA_REPO" "$sha"
done
for sha in "${SUSFS_SERIES[@]}"; do
  apply_vendor_patch "$SUSFS_REPO" "$sha"
done

# The final adapter adds N45's SUS_MAP/KSTAT proc behavior and KSUN manual-hook
# blocks. The latter are CONFIG_KSU_MANUAL_HOOK-gated and compile completely
# out for xxKSU, which keeps its 4.14-optimized syscall-table interception.
python3 scripts/gx/apply-susfs-v2-n45-final-hooks.py

python3 - arch/arm64/configs/vendor/miatoll-perf_defconfig "$root_kind" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
root_kind = sys.argv[2]
s = p.read_text()
settings = {
    'KSU': 'y',
    'KSU_SUSFS': 'y',
    # SUS_PATH is explicitly marked NOT recommended upstream and adds pathname
    # hot-path overhead. Keep it off in the stability-first release matrix.
    'KSU_SUSFS_SUS_PATH': 'n',
    'KSU_SUSFS_SUS_MOUNT': 'y',
    'KSU_SUSFS_SUS_KSTAT': 'y',
    'KSU_SUSFS_TRY_UMOUNT': 'y',
    'KSU_SUSFS_SPOOF_UNAME': 'y',
    'KSU_SUSFS_ENABLE_LOG': 'n',
    'KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS': 'y',
    'KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG': 'y',
    # OPEN_REDIRECT is experimental; omit it from the smooth/stable baseline.
    'KSU_SUSFS_OPEN_REDIRECT': 'n',
    'KSU_SUSFS_SUS_MAP': 'y',
}
if root_kind == 'ksun':
    settings.update({
        'KSU_MANUAL_HOOK': 'y',
        'KSU_KPROBES_HOOK': 'n',
        'KSU_SUSFS_SUS_MEMFD': 'n',
    })
elif root_kind == 'xxksu':
    # backslashxx explicitly recommends the direct syscall-table path on
    # Linux 3.0-4.14. Do not force the KSUN manual-hook ABI into xxKSU.
    settings.update({
        'KSU_TAMPER_SYSCALL_TABLE': 'y',
        'KSU_HACK_ARM64_BRANCH_LINK': 'n',
        'KSU_KPROBES_KSUD': 'n',
        'KSU_LSM_SECURITY_HOOKS': 'y',
    })
    for key in ('KSU_MANUAL_HOOK', 'KSU_KPROBES_HOOK'):
        s = re.sub(rf'^(?:CONFIG_{key}=.*|# CONFIG_{key} is not set)\n?', '', s, flags=re.M)
else:
    raise SystemExit(f'unsupported root kind: {root_kind}')

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
grep -Fxq '# CONFIG_KSU_SUSFS_SUS_PATH is not set' "$DEFCONFIG"
grep -Fxq '# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set' "$DEFCONFIG"
[[ -s fs/susfs.c ]]
[[ -s include/linux/susfs.h ]]
grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h
grep -Fq 'config KSU_SUSFS_SUS_MAP' "$KSU_DIR/kernel/Kconfig"

if [[ "$root_kind" == "ksun" ]]; then
  grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
  grep -Fxq '# CONFIG_KSU_KPROBES_HOOK is not set' "$DEFCONFIG"
  grep -Fq 'ksu_handle_sys_reboot' kernel/reboot.c
else
  grep -Fxq 'CONFIG_KSU_TAMPER_SYSCALL_TABLE=y' "$DEFCONFIG"
  ! grep -Fxq 'CONFIG_KSU_MANUAL_HOOK=y' "$DEFCONFIG"
fi

echo "[N45] SUSFS v2.2.0 Xiaomi 4.14 layer applied for $root_kind; stability profile active"
