# Demo

## One-Command Judge Flow (Unichain Sepolia)

Run:

```bash
make demo-testnet
```

This calls `scripts/demo_workflow.sh`, which executes the full workflow in phases:

1. Preflight
- validates `.env` values (`SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`, `OWNER_ADDRESS`)
- prints operator wallet and balance
- auto-selects a healthy Unichain Sepolia RPC from configured/default fallbacks

2. Core deployment verification
- checks `LARGE_CAP_VAULT_ADDRESS`, `LARGE_CAP_HOOK_ADDRESS`, `LARGE_CAP_EXECUTOR_ADDRESS`
- deploys them if missing
- writes deployed addresses + deploy tx hashes back into `.env`

3. Reactive integration verification (if enabled)
- checks/deploys `LARGE_CAP_REACTIVE_CALLBACK_ADDRESS` on Unichain Sepolia
- checks/deploys `LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS` on Reactive
- configures callback sender guard using `LARGE_CAP_REACTIVE_EXPECTED_SENDER` (defaults to Reactive deployer wallet / ReactVM ID)

4. On-chain compare run
- executes `script/11_DemoCompareUnichain.s.sol`
- deploys mock pair, initializes baseline/hook pools, seeds liquidity
- runs baseline single-shot swap
- creates segmented order and executes slices via `Executor`
- prints summary metrics

Execution tuning envs (optional):
- `DEMO_TOTAL_IN` (default `50e18`)
- `DEMO_SLICE_SIZE` (default `10e18`)
- `DEMO_MODE` (`0=BBE`, `1=SOF`; default `0`)
- `DEMO_BLOCKS_PER_SLICE` (BBE cadence, default `1`)
- `DEMO_MIN_INTERVAL_SECONDS` (SOF cadence, default `5`)
- `DEMO_MAX_EXECUTION_ATTEMPTS` (default `40`)
- `DEMO_WAIT_BETWEEN_ATTEMPTS_MS` (default `3500`)
- `DEMO_ENABLE_REACTIVE` (`1` default, `0` disables reactive phases)
- `DEMO_REACTIVE_REQUIRED` (`0` default, `1` fails run if reactive setup fails)
- `LARGE_CAP_REACTIVE_EXPECTED_SENDER` (ReactVM ID used by callback sender guard)
- `DEMO_COMPARE_RETRY_MAX_ATTEMPTS` (default `1` to avoid nonce collisions on large broadcast scripts)

5. Judge-ready artifacts
- prints explorer URLs for every tx in the run
- prints contract URLs (vault/hook/executor)
- prints user-perspective walkthrough steps

### Fast replay mode (no rebroadcast)

If RPC throttling happens and you only want to replay the judge links/output from the latest complete run artifact:

```bash
DEMO_SKIP_BROADCAST=1 ./scripts/demo_workflow.sh
```

The script auto-selects the latest complete broadcast file (non-empty tx hashes), not just `run-latest.json`.

## User Perspective (What to Say During Demo)

1. User submits a large order (`createOrder`) to `OrderBookVault`.
2. Executor performs policy-constrained slices instead of one monolithic swap.
3. Hook validates each slice at swap-time (`beforeSwap`/`afterSwap`).
4. Vault tracks partial fill progress and final accounting.
5. Reactive scheduler (if enabled) listens to hook telemetry and emits cross-chain callbacks.
6. Callback contract executes next eligible slices under sender + policy constraints.
7. User compares segmented realized execution vs naive baseline.

## Local Deterministic Compare

Run:

```bash
make demo-local
```

Use this when you want a deterministic local comparison loop on Anvil.

## Where Tx Hashes Come From

- deployment txs:
  - `broadcast/00_DeployLargeCapSystem.s.sol/1301/run-latest.json`
- compare demo txs:
  - `broadcast/11_DemoCompareUnichain.s.sol/1301/run-latest.json` or latest complete `run-*.json`

The workflow script converts each tx hash into explorer URLs using `UNICHAIN_EXPLORER_BASE`.
