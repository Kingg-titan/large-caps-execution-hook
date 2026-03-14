# Large-Cap Execution Hook Specification

## 1. Objective

Provide deterministic, policy-constrained execution for large swap intents in Uniswap v4 pools by splitting a parent order into micro-executions.

## 2. Scope

Contracts:

- `src/OrderBookVault.sol`
- `src/LargeCapExecutionHook.sol`
- `src/Executor.sol`

Out of scope:

- Offchain impact oracle design.
- Intent settlement networks.

## 3. Execution Policy Engine

### 3.1 Order Fields

`OrderState` includes:

- `orderId`
- `owner`
- `poolId`
- `tokenIn` / `tokenOut`
- `zeroForOne`
- `amountInTotal`
- `amountInRemaining`
- `mode`
- `startTime` / `endTime`
- `minIntervalSeconds` / `blocksPerSlice`
- `maxSliceAmount` / `minSliceAmount`
- `maxImpactBps`
- `minAmountOutPerSlice`
- `status`
- `nonce` / `epoch`
- `nextSliceIndex`
- `lastExecutionBlock` / `lastExecutionTime`
- `allowedExecutor`

### 3.2 Reason Codes

`ReasonCode`:

- `NONE`
- `NOT_STARTED`
- `EXPIRED`
- `COOLDOWN`
- `IMPACT_TOO_HIGH`
- `SLIPPAGE_TOO_HIGH`
- `NO_LIQUIDITY`
- `INVALID_CALLER`
- `ALREADY_COMPLETED`

### 3.3 Eligibility Rules

A slice is eligible when:

1. Order status is `ACTIVE`.
2. Current time in `[startTime, endTime]`.
3. Cadence rule satisfied:
   - `BBE`: block spacing >= `blocksPerSlice`
   - `SOF`: time spacing >= `minIntervalSeconds`
4. `observedImpactBps <= maxImpactBps`
5. Pending slice lock is empty.
6. Slice amount is within configured bounds (except final residual handling).

## 4. Hook Behavior

### 4.1 `beforeSwap`

- Decodes `HookOrderData`.
- Re-validates pending slice against vault state.
- Enforces expected swap caller from vault executor.
- Reverts with reason-coded error on policy violations.

### 4.2 `afterSwap`

- Computes realized slice output from `BalanceDelta`.
- Calls `vault.recordAfterSwap(...)`.
- Emits `SliceExecuted` telemetry.

## 5. Executor Behavior

1. Calls `vault.reserveNextSlice(...)`.
2. Executes swap via `PoolManager.unlock(...)` + `unlockCallback`.
3. Settles deltas:
   - negative deltas settled to manager,
   - positive deltas transferred to vault.
4. On failure:
   - returns reserved input to vault,
   - clears pending slice,
   - emits blocked telemetry.

## 6. Event Surface

Minimum event surface includes:

- `OrderCreated`
- `OrderCancelled`
- `SliceSkipped`
- `SliceBlocked`
- `SliceExecuted`
- `OrderCompleted`

## 7. Security Properties

- Hook entrypoints restricted to `PoolManager`.
- Policy logic concentrated in vault with explicit reason codes.
- Pending slice lock prevents replay / duplicate accounting.
- Slice accounting is monotonic and completion is terminal.
- Executor failure path explicitly restores reserved input.

## 8. Deterministic Dependency Policy

`./scripts/bootstrap.sh` enforces pinned Uniswap dependency versions.

Pinned anchor:

- `v4-periphery`: `3779387e5d296f39df543d23524b050f89a62917`

## 9. Test Plan

- Unit + edge tests for vault policy behavior.
- Integration tests with real `PoolManager` swap lifecycle.
- Stateless fuzz tests for amount/accounting bounds.
- Stateful invariant suite for progression and terminal-state guarantees.

## 10. Assumptions

- Pinned commit `3779387` maps to Uniswap `v4-periphery` commit `3779387e5d296f39df543d23524b050f89a62917`.
- Frontend dependency lockfile should be regenerated in a Node-enabled environment for production CI.
