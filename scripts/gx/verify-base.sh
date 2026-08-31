#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEFCONFIG="arch/arm64/configs/vendor/miatoll-perf_defconfig"
fail=0

ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }
info() { printf 'INFO %s\n' "$*"; }

version="$(awk -F' *= *' '/^VERSION =/{v=$2}/^PATCHLEVEL =/{p=$2}/^SUBLEVEL =/{s=$2} END{print v"."p"."s}' Makefile)"
extra="$(awk -F' *= *' '/^EXTRAVERSION =/{print $2; exit}' Makefile)"

info "kernel=${version}${extra}"

[[ "$version" == "4.14.356" ]] && ok "OpenELA target is 4.14.356" || bad "expected 4.14.356, got $version"
[[ "$extra" == "-openela" ]] && ok "OpenELA EXTRAVERSION retained" || bad "expected EXTRAVERSION=-openela, got $extra"

grep -qx 'CONFIG_LRU_GEN=y' "$DEFCONFIG" && ok "MGLRU enabled" || bad "CONFIG_LRU_GEN=y missing"
grep -qx 'CONFIG_LRU_GEN_ENABLED=y' "$DEFCONFIG" && ok "MGLRU enabled by default" || bad "CONFIG_LRU_GEN_ENABLED=y missing"

if grep -Eq '^int vm_swappiness = 60;' mm/vmscan.c; then
  ok "Nexus-v4.5 swappiness target is 60"
else
  current="$(grep -E '^int vm_swappiness = ' mm/vmscan.c | head -n1 || true)"
  bad "swappiness target not applied (${current:-not found})"
fi

if grep -Eq '^CONFIG_KSU(=|_)' "$DEFCONFIG"; then
  bad "common base must not enable KernelSU"
else
  ok "common base has no KernelSU config"
fi

if [[ -e drivers/kernelsu ]]; then
  info "drivers/kernelsu exists in tree; ensure it is not enabled in common base"
else
  ok "no built-in KernelSU directory in common base"
fi

# The N45 base intentionally keeps stock frequency behavior.  Frequency-table
# normalization is verified separately against the stock Miatoll reference
# before a release is tagged; do not guess values here.

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Base verification is not complete yet."
  exit 1
fi

echo
echo "Base verification passed."
