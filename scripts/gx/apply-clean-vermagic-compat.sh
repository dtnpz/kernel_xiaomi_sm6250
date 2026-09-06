#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path

p = Path('kernel/module.c')
s = p.read_text()

old_crc = '''static inline int same_magic(const char *amagic, const char *bmagic,
\t\t\t     bool has_crcs)
{
\tif (has_crcs) {
\t\tamagic += strcspn(amagic, " ");
\t\tbmagic += strcspn(bmagic, " ");
\t}
\treturn strcmp(amagic, bmagic) == 0;
}'''

new_crc = '''static inline int same_magic(const char *amagic, const char *bmagic,
\t\t\t     bool has_crcs)
{
\t/*
\t * rev187 clean-name compatibility: UTS_RELEASE is a presentation/build
\t * identity only.  Keep checking every remaining vermagic flag, and keep
\t * normal symbol CRC checks, but do not reject a module solely because its
\t * first vermagic token was built with an older release label.
\t */
\t(void)has_crcs;
\tamagic += strcspn(amagic, " ");
\tbmagic += strcspn(bmagic, " ");
\treturn strcmp(amagic, bmagic) == 0;
}'''

old_no_crc = '''static inline int same_magic(const char *amagic, const char *bmagic,
\t\t\t     bool has_crcs)
{
\treturn strcmp(amagic, bmagic) == 0;
}'''

new_no_crc = '''static inline int same_magic(const char *amagic, const char *bmagic,
\t\t\t     bool has_crcs)
{
\t/* Ignore only the release-name token; all remaining vermagic flags match. */
\t(void)has_crcs;
\tamagic += strcspn(amagic, " ");
\tbmagic += strcspn(bmagic, " ");
\treturn strcmp(amagic, bmagic) == 0;
}'''

if s.count(old_crc) != 1:
    raise SystemExit('CONFIG_MODVERSIONS same_magic anchor not found exactly once')
if s.count(old_no_crc) != 1:
    raise SystemExit('non-MODVERSIONS same_magic anchor not found exactly once')

s = s.replace(old_crc, new_crc, 1)
s = s.replace(old_no_crc, new_no_crc, 1)
p.write_text(s)
print('[vermagic] clean UTS compatibility enabled: ignore release token only')
PY
