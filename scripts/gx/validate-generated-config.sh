#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source .gx-variant

CONFIG="${1:-out/.config}"
[[ -s "$CONFIG" ]] || { echo "[N45] generated config missing: $CONFIG" >&2; exit 2; }

enabled() { grep -Fxq "CONFIG_$1=y" "$CONFIG"; }
require_y() {
  if ! enabled "$1"; then
    echo "[N45] required CONFIG_$1=y missing for $GX_VARIANT" >&2
    grep -E "^(CONFIG_$1=|# CONFIG_$1 is not set)" "$CONFIG" >&2 || true
    exit 4
  fi
}
forbid_y() {
  if enabled "$1"; then
    echo "[N45] forbidden CONFIG_$1=y enabled for $GX_VARIANT" >&2
    exit 4
  fi
}

case "${GX_ROOT:-none}" in
  none)
    forbid_y KSU
    ;;
  xxksu)
    require_y KSU
    require_y KSU_TAMPER_SYSCALL_TABLE
    forbid_y KSU_KPROBES_KSUD
    forbid_y KSU_KPROBES_HOOK
    ;;
  ksun)
    require_y KSU
    if [[ "${GX_SUSFS:-0}" == "1" ]]; then
      # The pinned SUSFS compatibility tree is the legacy/manual-hook KSUN
      # integration and retains its own hook-mode Kconfig symbols.
      require_y KSU_MANUAL_HOOK
      forbid_y KSU_KPROBES_HOOK
    else
      # Official KernelSU-Next v3.3.0 has no legacy MANUAL_HOOK selector.
      # Its native syscall/event bridge is gated by KSU -> KPROBES && EXT4_FS,
      # and this 4.14 tree in turn gates KPROBES behind MODULES.
      require_y EXT4_FS
      require_y MODULES
      require_y KPROBES
      forbid_y KSU_MANUAL_HOOK
      forbid_y KSU_KPROBES_HOOK
    fi
    ;;
  *)
    echo "[N45] unknown GX_ROOT=${GX_ROOT:-}" >&2
    exit 4
    ;;
esac

if [[ "${GX_SUSFS:-0}" == "1" ]]; then
  require_y KSU_SUSFS
else
  forbid_y KSU_SUSFS
fi

# Keep the resolved generic kprobe state visible in CI so official KSUN's
# native-hook dependency can be audited without conflating it with the old
# KSU-specific KSU_KPROBES_HOOK selector.
grep -E '^(CONFIG_MODULES=|# CONFIG_MODULES is not set|CONFIG_KPROBES=|# CONFIG_KPROBES is not set|CONFIG_HAVE_KPROBES=|CONFIG_EXT4_FS=)' "$CONFIG" || true

if [[ "${GX_ROOT:-none}" == "ksun" && "${GX_SUSFS:-0}" == "0" ]]; then
  echo "[N45] generated config verified: official KSUN native hook prerequisites enabled; SUSFS disabled"
else
  echo "[N45] generated config verified: variant/root/SUSFS match"
fi
