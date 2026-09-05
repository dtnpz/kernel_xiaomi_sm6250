#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

INTERNAL_RELEASE="4.14.357-Gxter-XXKSU330-NOSUSFS-NBP-FuckMiatollCommu/2642d318"

if [[ ! -f .gx-variant ]]; then
  echo "Missing .gx-variant metadata." >&2
  exit 2
fi

python3 - "$INTERNAL_RELEASE" <<'PY'
from pathlib import Path
import re, sys
release = sys.argv[1]

m = Path('Makefile')
s = m.read_text()
checks = {
    'VERSION': '4',
    'PATCHLEVEL': '14',
    'SUBLEVEL': '357',
}
for key, expected in checks.items():
    match = re.search(rf'^{key}\s*=\s*(\S+)\s*$', s, re.M)
    if not match or match.group(1) != expected:
        raise SystemExit(f'Unexpected {key}; expected {expected}')

s, n = re.subn(r'^EXTRAVERSION\s*=.*$', 'EXTRAVERSION =', s, count=1, flags=re.M)
if n != 1:
    raise SystemExit('EXTRAVERSION anchor not found')

pat = re.compile(r'define filechk_kernel\.release\n.*?\nendef', re.S)
replacement = f'define filechk_kernel.release\n\techo "{release}"\nendef'
s, n = pat.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit('filechk_kernel.release anchor not found')
m.write_text(s)

p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()
local = 'CONFIG_LOCALVERSION=""'
local_pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
if local_pat.search(s):
    s = local_pat.sub(local, s, count=1)
else:
    s = local + '\n' + s
p.write_text(s)

print(f'[gxter] preserved #187 internal kernel release: {release}')
PY
