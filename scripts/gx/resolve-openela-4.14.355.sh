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

# There must be one and only one merge conflict in this reviewed file.
if s.count('<<<<<<<') != 1 or s.count('=======') != 1 or s.count('>>>>>>>') != 1:
    raise SystemExit('unexpected number of conflict markers in usbnet.c')

m = re.search(r'<<<<<<<[^\n]*\n(.*?)\n\|\|\|\|\|\|\|[^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>>[^\n]*', s, re.S)
if not m:
    # Some git configurations omit the diff3 base block; accept only the
    # equivalent two-way conflict shape.
    m = re.search(r'<<<<<<<[^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>>[^\n]*', s, re.S)
    if not m:
        raise SystemExit('reviewed usbnet conflict block not found')
    ours = m.group(1)
else:
    ours = m.group(1)

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

s = s[:m.start()] + resolved + s[m.end():]
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
