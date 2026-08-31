#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

if [[ ! -f .gx-variant ]]; then
  echo "Missing .gx-variant metadata." >&2
  exit 2
fi

# shellcheck disable=SC1091
source .gx-variant

: "${GX_VARIANT:?GX_VARIANT missing}"
: "${GX_ROOT:=none}"
: "${GX_SUSFS:=0}"
: "${GX_BP:=0}"

case "$GX_ROOT" in
  none|xxksu|ksun) ;;
  *) echo "Unknown GX_ROOT=$GX_ROOT" >&2; exit 2 ;;
esac

case "$GX_SUSFS" in 0|1) ;; *) echo "GX_SUSFS must be 0/1" >&2; exit 2 ;; esac
case "$GX_BP" in 0|1) ;; *) echo "GX_BP must be 0/1" >&2; exit 2 ;; esac

if [[ "$GX_ROOT" == none && "$GX_SUSFS" == 1 ]]; then
  echo "SUSFS is forbidden on NONKSU variants." >&2
  exit 2
fi

# Layer order is deliberately fixed so every family differs minimally:
# common N45 base -> optional selected BPF backports -> one root -> SUSFS.
if [[ "$GX_BP" == 1 ]]; then
  if [[ ! -x scripts/gx/apply-bp510.sh ]]; then
    echo "BP requested but scripts/gx/apply-bp510.sh is not ready." >&2
    exit 3
  fi
  bash scripts/gx/apply-bp510.sh
fi

case "$GX_ROOT" in
  none)
    ;;
  xxksu)
    if [[ ! -x scripts/gx/setup-xxksu.sh ]]; then
      echo "xxKSU requested but setup script is not ready." >&2
      exit 3
    fi
    bash scripts/gx/setup-xxksu.sh
    ;;
  ksun)
    if [[ ! -x scripts/gx/setup-ksun.sh ]]; then
      echo "KSUN requested but setup script is not ready." >&2
      exit 3
    fi
    bash scripts/gx/setup-ksun.sh
    ;;
esac

if [[ "$GX_SUSFS" == 1 ]]; then
  if [[ ! -x scripts/gx/setup-susfs.sh ]]; then
    echo "SUSFS requested but setup script is not ready." >&2
    exit 3
  fi
  bash scripts/gx/setup-susfs.sh "$GX_ROOT"
fi

echo "[N45] variant preparation complete: $GX_VARIANT"
