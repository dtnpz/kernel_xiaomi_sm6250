#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

INTERNAL_RELEASE="4.14.357-Gxterkernl-joyeuse-rev187"
LOCAL_SUFFIX="-Gxterkernl-joyeuse-rev187"

if [[ ! -f .gx-variant ]]; then
  echo "Missing .gx-variant metadata." >&2
  exit 2
fi

python3 - "$INTERNAL_RELEASE" "$LOCAL_SUFFIX" <<'PY'
from pathlib import Path
import re, sys
expected_release, local_suffix = sys.argv[1:3]

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
m.write_text(s)

p = Path('arch/arm64/configs/vendor/miatoll-perf_defconfig')
s = p.read_text()

local_line = f'CONFIG_LOCALVERSION="{local_suffix}"'
local_pat = re.compile(r'^CONFIG_LOCALVERSION=.*$', re.M)
s = local_pat.sub(local_line, s, count=1) if local_pat.search(s) else local_line + '\n' + s

auto_pat = re.compile(r'^(?:CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set)$', re.M)
auto_line = '# CONFIG_LOCALVERSION_AUTO is not set'
s = auto_pat.sub(auto_line, s, count=1) if auto_pat.search(s) else auto_line + '\n' + s
p.write_text(s)

print(f'[gxter] clean internal kernel release: {expected_release}')
PY

# Apply after OpenELA + variant preparation so no later source setup can
# restore release-token-sensitive module loading before compilation.
bash scripts/gx/apply-clean-vermagic-compat.sh
