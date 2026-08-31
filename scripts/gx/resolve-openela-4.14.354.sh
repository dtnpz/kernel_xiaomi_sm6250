#!/usr/bin/env bash
set -euo pipefail

# OpenELA 4.14.354 fixes the CONFIG_HIGHMEM failure path in mmc_test:
# if alloc_pages() fails, return -ENOMEM and skip __free_pages().
# The conflict is isolated to this generic MMC self-test file and there are
# no Xiaomi/Qualcomm device-specific changes to preserve in the conflicted
# hunk. Refuse any unexpected conflict set.

expected='drivers/mmc/core/mmc_test.c'
actual="$(git diff --name-only --diff-filter=U | LC_ALL=C sort)"

if [[ "$actual" != "$expected" ]]; then
  echo "Refusing automatic 4.14.354 resolution: unexpected conflict set." >&2
  echo "Expected: $expected" >&2
  echo "Actual:" >&2
  printf '%s\n' "$actual" >&2
  exit 2
fi

# Keep the reviewed OpenELA allocation/error path.
git checkout --theirs -- drivers/mmc/core/mmc_test.c

git add drivers/mmc/core/mmc_test.c
git diff --check --cached

# Guard the exact semantic fix we reviewed.
grep -Fq 'count = -ENOMEM;' drivers/mmc/core/mmc_test.c
grep -Fq 'goto free_test_buffer;' drivers/mmc/core/mmc_test.c
grep -Fq 'free_test_buffer:' drivers/mmc/core/mmc_test.c

if git diff --name-only --diff-filter=U | grep -q .; then
  echo "Unmerged files remain after 4.14.354 resolver:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 3
fi

git commit --no-edit

echo "Resolved reviewed OpenELA 4.14.354 MMC test conflict successfully."
