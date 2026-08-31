#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# Selected real BPF backport for the BP family. The NBP tree already contains
# many Android/Kinesis BPF compatibility backports, but it lacks program-side
# write-only map permissions. This upstream change adds BPF_F_WRONLY_PROG along
# with the verifier/map access enforcement; it is therefore a material kernel
# capability difference rather than a filename-only BP variant.
BPF_BP_COMMIT="591fe9888d7809d9ee5c828020b6c6ae27c37229"
PATCH_FILE="$(mktemp)"
trap 'rm -f "$PATCH_FILE"' EXIT

curl -fsSL --retry 3 --retry-delay 2 \
  "https://github.com/torvalds/linux/commit/${BPF_BP_COMMIT}.patch" \
  -o "$PATCH_FILE"

grep -Fq 'Subject: [PATCH] bpf: add program side {rd, wr}only support for maps' "$PATCH_FILE" || {
  echo "Unexpected BP patch payload; refusing to apply." >&2
  exit 4
}

if grep -Rqs 'BPF_F_WRONLY_PROG' include/uapi/linux/bpf.h include/linux/bpf.h kernel/bpf; then
  echo "BPF_F_WRONLY_PROG already present; refusing a BP build that would equal NBP." >&2
  exit 5
fi

if ! git apply --check "$PATCH_FILE"; then
  echo "Pinned BPF BP does not apply cleanly to this tree; adaptation required." >&2
  exit 6
fi

git apply "$PATCH_FILE"

# Enforce that both UAPI and in-kernel policy pieces landed.
grep -Fq '#define BPF_F_WRONLY_PROG' include/uapi/linux/bpf.h
grep -Fq 'BPF_MAP_CAN_WRITE' include/linux/bpf.h
grep -Fq 'bpf_map_flags_access_ok' include/linux/bpf.h
grep -Rqs 'BPF_F_WRONLY_PROG' kernel/bpf

echo "[N45] applied BPF program-side access backport ${BPF_BP_COMMIT}"
