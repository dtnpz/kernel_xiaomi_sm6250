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
    require_y KSU_MANUAL_HOOK
    forbid_y KSU_KPROBES_HOOK
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

# Generic Linux kprobe capability/state belongs to the vendor baseline.  It is
# not a KSU hook-mode selector here; log it for audit but do not globally force
# it on or off.
grep -E '^(CONFIG_KPROBES=|# CONFIG_KPROBES is not set|CONFIG_HAVE_KPROBES=)' "$CONFIG" || true

echo "[N45] generated config verified: variant/root/SUSFS match; KSU kprobe hook paths disabled"
