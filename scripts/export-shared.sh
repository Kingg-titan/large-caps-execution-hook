#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p shared/abis

cp out/OrderBookVault.sol/OrderBookVault.json shared/abis/OrderBookVault.json
cp out/LargeCapExecutionHook.sol/LargeCapExecutionHook.json shared/abis/LargeCapExecutionHook.json
cp out/Executor.sol/Executor.json shared/abis/Executor.json

cat > shared/contracts.json <<JSON
{
  "OrderBookVault": "shared/abis/OrderBookVault.json",
  "LargeCapExecutionHook": "shared/abis/LargeCapExecutionHook.json",
  "Executor": "shared/abis/Executor.json"
}
JSON

echo "[export-shared] ABIs written to shared/abis"
