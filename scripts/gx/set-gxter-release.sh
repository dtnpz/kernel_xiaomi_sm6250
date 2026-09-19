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

python3 - <<'PY'
from pathlib import Path
import re

m = Path('Makefile')
s = m.read_text()
checks = {
    'VERSION': '4',
    'PATCHLEVEL': '14',
    'SUBLEVEL': '356',
}
for key, expected in checks.items():
    match = re.search(rf'^{key}\s*=\s*(\S+)\s*$', s, re.M)
    if not match or match.group(1) != expected:
        raise SystemExit(f'Unexpected {key}; expected {expected}')
s, n = re.subn(r'^EXTRAVERSION\s*=.*$', 'EXTRAVERSION =', s, count=1, flags=re.M)
if n != 1:
    raise SystemExit('EXTRAVERSION anchor not found')
m.write_text(s)

p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()

local_line = 'CONFIG_LOCALVERSION="-gxt"'
local_pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
s = local_pat.sub(local_line, s, count=1) if local_pat.search(s) else local_line + '\n' + s

auto_line = '# CONFIG_LOCALVERSION_AUTO is not set'
auto_pat = re.compile(r'^(?:CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set)$', re.M)
s = auto_pat.sub(auto_line, s, count=1) if auto_pat.search(s) else auto_line + '\n' + s

p.write_text(s)
print('[gxter] kernel release: 4.14.356-gxt')
PY
