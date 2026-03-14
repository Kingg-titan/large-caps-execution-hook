#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_V4_PERIPHERY_COMMIT="3779387e5d296f39df543d23524b050f89a62917"

printf "[bootstrap] initializing git submodules...\n"
git submodule update --init --recursive

V4_PERIPHERY_DIR="lib/uniswap-hooks/lib/v4-periphery"
V4_CORE_DIR="lib/uniswap-hooks/lib/v4-core"
V4_CORE_FROM_PERIPHERY_DIR="lib/uniswap-hooks/lib/v4-periphery/lib/v4-core"

printf "[bootstrap] pinning v4-periphery to %s\n" "$EXPECTED_V4_PERIPHERY_COMMIT"
git -C "$V4_PERIPHERY_DIR" fetch --all --tags --quiet
git -C "$V4_PERIPHERY_DIR" checkout "$EXPECTED_V4_PERIPHERY_COMMIT" --quiet

EXPECTED_V4_CORE_COMMIT="$(git -C "$V4_PERIPHERY_DIR" ls-tree "$EXPECTED_V4_PERIPHERY_COMMIT" lib/v4-core | awk '{print $3}')"
if [[ -z "$EXPECTED_V4_CORE_COMMIT" ]]; then
  echo "[bootstrap] failed to resolve expected v4-core commit from v4-periphery pin"
  exit 1
fi

printf "[bootstrap] pinning v4-core to %s\n" "$EXPECTED_V4_CORE_COMMIT"
git -C "$V4_CORE_DIR" fetch --all --tags --quiet
git -C "$V4_CORE_DIR" checkout "$EXPECTED_V4_CORE_COMMIT" --quiet
git -C "$V4_CORE_FROM_PERIPHERY_DIR" fetch --all --tags --quiet
git -C "$V4_CORE_FROM_PERIPHERY_DIR" checkout "$EXPECTED_V4_CORE_COMMIT" --quiet

ACTUAL_V4_PERIPHERY_COMMIT="$(git -C "$V4_PERIPHERY_DIR" rev-parse HEAD)"
ACTUAL_V4_CORE_COMMIT="$(git -C "$V4_CORE_DIR" rev-parse HEAD)"
ACTUAL_V4_CORE_FROM_PERIPHERY_COMMIT="$(git -C "$V4_CORE_FROM_PERIPHERY_DIR" rev-parse HEAD)"

if [[ "$ACTUAL_V4_PERIPHERY_COMMIT" != "$EXPECTED_V4_PERIPHERY_COMMIT" ]]; then
  echo "[bootstrap] v4-periphery commit mismatch"
  echo "  expected: $EXPECTED_V4_PERIPHERY_COMMIT"
  echo "  actual:   $ACTUAL_V4_PERIPHERY_COMMIT"
  exit 1
fi

if [[ "$ACTUAL_V4_CORE_COMMIT" != "$EXPECTED_V4_CORE_COMMIT" ]]; then
  echo "[bootstrap] v4-core commit mismatch"
  echo "  expected: $EXPECTED_V4_CORE_COMMIT"
  echo "  actual:   $ACTUAL_V4_CORE_COMMIT"
  exit 1
fi

if [[ "$ACTUAL_V4_CORE_FROM_PERIPHERY_COMMIT" != "$EXPECTED_V4_CORE_COMMIT" ]]; then
  echo "[bootstrap] nested v4-core commit mismatch"
  echo "  expected: $EXPECTED_V4_CORE_COMMIT"
  echo "  actual:   $ACTUAL_V4_CORE_FROM_PERIPHERY_COMMIT"
  exit 1
fi

printf "[bootstrap] dependency pin verification passed.\n"
