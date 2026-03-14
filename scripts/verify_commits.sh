#!/usr/bin/env bash
set -euo pipefail

EXPECTED_COMMITS="${1:-${EXPECTED_COMMITS:-58}}"
EXPECTED_AUTHOR_NAME="${EXPECTED_AUTHOR_NAME:-Kingg-titan}"
EXPECTED_AUTHOR_EMAIL="${EXPECTED_AUTHOR_EMAIL:-ebukaegbunike@gmail.com}"

ACTUAL_COMMITS="$(git rev-list --count HEAD)"
if [[ "$ACTUAL_COMMITS" != "$EXPECTED_COMMITS" ]]; then
  echo "[verify-commits] commit count mismatch"
  echo "  expected: $EXPECTED_COMMITS"
  echo "  actual:   $ACTUAL_COMMITS"
  exit 1
fi

UNIQUE_AUTHORS="$(git log --format='%an <%ae>' | sort -u)"
EXPECTED_AUTHOR="$EXPECTED_AUTHOR_NAME <$EXPECTED_AUTHOR_EMAIL>"
if [[ "$UNIQUE_AUTHORS" != "$EXPECTED_AUTHOR" ]]; then
  echo "[verify-commits] author mismatch"
  echo "  expected: $EXPECTED_AUTHOR"
  echo "  actual:"
  echo "$UNIQUE_AUTHORS"
  exit 1
fi

echo "[verify-commits] all checks passed"
