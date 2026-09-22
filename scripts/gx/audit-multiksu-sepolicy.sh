#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source .gx-variant

CONFIG="${1:-out/.config}"
[[ "${GX_MULTI_KSU:-0}" == "1" ]] || exit 0
[[ -s "$CONFIG" ]] || { echo "[MultiKSU audit] missing generated config: $CONFIG" >&2; exit 2; }

grep -Fxq 'CONFIG_KSU=y' "$CONFIG"
grep -Fxq 'CONFIG_SECURITY_SELINUX=y' "$CONFIG"
grep -Fxq 'CONFIG_KSU_TAMPER_SYSCALL_TABLE=y' "$CONFIG"
! grep -Fxq 'CONFIG_KSU_SUSFS=y' "$CONFIG"
! grep -Fxq 'CONFIG_KSU_KPROBES_KSUD=y' "$CONFIG"
! grep -Fxq 'CONFIG_KSU_KPROBES_HOOK=y' "$CONFIG"

[[ -L drivers/kernelsu ]] || { echo '[MultiKSU audit] drivers/kernelsu is not the single KernelSU symlink' >&2; exit 3; }
resolved="$(readlink -f drivers/kernelsu)"
expected="$(readlink -f KernelSU/kernel)"
[[ "$resolved" == "$expected" ]] || {
  echo "[MultiKSU audit] KSU driver mismatch: $resolved != $expected" >&2
  exit 3
}

rules=KernelSU/kernel/selinux/rules.c
dispatch=KernelSU/kernel/supercall/dispatch.c
identity=KernelSU/kernel/manager/manager_identity.h
sign=KernelSU/kernel/manager/apk_sign.c
for f in "$rules" "$dispatch" "$identity" "$sign"; do
  [[ -s "$f" ]] || { echo "[MultiKSU audit] missing $f" >&2; exit 3; }
done

# Linux 4.14 mutates the live policydb. Require both safe paths: policy_rwlock
# when discoverable and stop_machine fallback when it is not. Also require AVC
# invalidation and restoration of the task's original CPU-affinity mask.
grep -Fq 'rwlock_t *lock = ksu_get_policy_rwlock();' "$rules"
grep -Fq 'write_lock(lock);' "$rules"
grep -Fq 'stop_machine(apply_kernelsu_rules_fn' "$rules"
grep -Fq 'stop_machine(handle_sepolicy_fn' "$rules"
grep -Fq 'reset_avc_cache();' "$rules"
grep -Fq 'cpumask_copy(&old_mask, ksu_get_current_cpumask_t());' "$rules"
grep -Fq 'set_cpus_allowed_ptr(current, &old_mask);' "$rules"

# No fork replaces the SELinux engine at runtime: manager identity changes only
# UAPI/reporting compatibility on top of the single xxKSU backend.
grep -Fq 'cmd.uapi_version = gxt_ksu_manager_uapi_version();' "$dispatch"
for macro in KSU XXKSU KSUN KOWSU MAMBOSU RESUKISU; do
  grep -Fq "GXT_KSU_UAPI_${macro} 4" "$identity"
done

echo '[MultiKSU audit] PASS: UAPI4 signer routing + 4.14 SELinux lock/fallback/AVC/affinity invariants'
