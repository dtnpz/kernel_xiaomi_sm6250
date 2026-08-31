#!/usr/bin/env bash
set -euo pipefail

# OpenELA 4.14.355 modernizes usbnet MAC address handling:
# - removes the global random node_id
# - uses eth_hw_addr_set()/eth_hw_addr_random()
# - removes eth_random_addr(node_id) from usbnet_init()
#
# Velvet/Xiaomi adds IPC logging initialization to usbnet_init(). Git merges
# the rest of OpenELA's usbnet changes automatically; only this init hunk
# conflicts. Preserve the Xiaomi IPC logging loop while removing the obsolete
# node_id initialization. Refuse any unexpected conflict set/context.

expected='drivers/net/usb/usbnet.c'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.355 resolution: unexpected conflict set." >&2
  echo "Expected: $expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

python3 <<'PY'
from pathlib import Path
import re

p = Path('drivers/net/usb/usbnet.c')
s = p.read_text()
lines = s.splitlines(keepends=True)

starts = [i for i, line in enumerate(lines) if line.startswith('<<<<<<< ')]
seps = [i for i, line in enumerate(lines) if line.startswith('=======')]
ends = [i for i, line in enumerate(lines) if line.startswith('>>>>>>> ')]
if len(starts) != 1 or len(seps) != 1 or len(ends) != 1:
    raise SystemExit('unexpected number of conflict markers in usbnet.c')

start, sep, end = starts[0], seps[0], ends[0]
if not (start < sep < end):
    raise SystemExit('malformed usbnet conflict marker ordering')

# In zdiff3 there is a ||||||| base marker inside the ours/theirs block.
# Only the text before that marker is the actual Velvet side.
base_markers = [i for i in range(start + 1, sep) if lines[i].startswith('||||||| ')]
if len(base_markers) > 1:
    raise SystemExit('unexpected multiple zdiff3 base markers')
ours_end = base_markers[0] if base_markers else sep
ours = ''.join(lines[start + 1:ours_end])

required = [
    'eth_random_addr(node_id);',
    'for (i = 0; i < NUM_USBNET_IDS; i++) {',
    'ipc_log_context_create(IPC_LOG_NUM_PAGES,',
]
for needle in required:
    if needle not in ours:
        raise SystemExit(f'reviewed usbnet ours context missing: {needle}')

resolved = ours.replace('\teth_random_addr(node_id);\n', '', 1)
if 'eth_random_addr(node_id);' in resolved:
    raise SystemExit('failed to remove obsolete node_id initialization')

lines[start:end + 1] = [resolved]
s = ''.join(lines)
p.write_text(s)

# Guard the OpenELA semantics that must already have auto-merged.
checks = [
    'eth_hw_addr_set(dev->net, addr);',
    'eth_hw_addr_random(net);',
    'strscpy(net->name, "usb%d", sizeof(net->name));',
]
for needle in checks:
    if needle not in s:
        raise SystemExit(f'OpenELA usbnet semantic change missing after resolution: {needle}')

# Xiaomi IPC logging must remain.
for needle in [
    '#include <linux/ipc_logging.h>',
    'usbnet_ipc_log_ctxt[i] =',
    'ipc_log_context_create(IPC_LOG_NUM_PAGES,',
]:
    if needle not in s:
        raise SystemExit(f'Xiaomi IPC logging change missing after resolution: {needle}')

# The old global node_id must be gone after OpenELA's modernization.
if re.search(r'^static u8\s+node_id\s*\[ETH_ALEN\]', s, re.M):
    raise SystemExit('obsolete global usbnet node_id still present')
PY

git add drivers/net/usb/usbnet.c
git diff --check --cached

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.355 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.355 usbnet conflict successfully."
