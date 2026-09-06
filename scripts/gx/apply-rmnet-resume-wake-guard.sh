#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path('drivers/platform/msm/ipa/ipa_v3/rmnet_ipa.c')
s = p.read_text()
old = '''\tif (netdev) {
\t\tnetif_device_attach(netdev);
\t\tnetif_trans_update(netdev);
\t}'''
new = '''\tif (netdev) {
\t\tnetif_device_attach(netdev);
\t\t/*
\t\t * A successful detach/attach cycle wakes TX queues in the
\t\t * networking core.  If the device remained PRESENT across a
\t\t * suspend edge, however, netif_device_attach() is intentionally
\t\t * a no-op and a queue stopped by the AP-suspend xmit race can
\t\t * remain stopped.  Qualcomm rmnet IPA implementations explicitly
\t\t * wake the TX queue on resume; keep that as a narrow guard here.
\t\t */
\t\tif (netif_queue_stopped(netdev)) {
\t\t\tIPAWANINFO("resume guard: waking stopped rmnet TX queue\\n");
\t\t\tnetif_wake_queue(netdev);
\t\t}
\t\tnetif_trans_update(netdev);
\t}'''
if old not in s:
    if 'resume guard: waking stopped rmnet TX queue' in s:
        print('[rmnet-resume] wake guard already applied')
        raise SystemExit(0)
    raise SystemExit('rmnet resume anchor not found')
p.write_text(s.replace(old, new, 1))
print('[rmnet-resume] installed stopped-TX-queue wake guard')
PY
