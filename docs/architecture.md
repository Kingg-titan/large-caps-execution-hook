# Architecture

## Design Intent

The hook remains minimal. Heavy logic is moved to vault/executor to reduce hook complexity and attack surface.

## Contracts

### `LargeCapExecutionHook`

- Inherits OpenZeppelin `BaseHook`.
- Implements `beforeSwap` and `afterSwap`.
- Enforces that hook permissions are encoded in the deployed hook address bits.
- Validates order context through `OrderBookVault.validateHookExecution`.
- Finalizes slice accounting through `OrderBookVault.recordAfterSwap`.
- Restricts entrypoints to `PoolManager` via `BaseHook.onlyPoolManager`.

### `OrderBookVault`

- Custodies input tokens for active orders.
- Validates schedule, cadence, impact cap, and executor policy.
- Stores per-order state and pending slice state.
- Provides read-only getters for frontend and offchain indexers.
- Tracks output claimability and input refunds on cancel/expiry.

### `Executor`

- Implements `IUnlockCallback` and directly swaps through `PoolManager`.
- Reserves the next eligible slice from vault.
- Executes exact-input slice swaps with deterministic parameters.
- Settles negative deltas and takes positive deltas to the vault.
- Emits execution attempt/result telemetry.

## Invariants

- `amountInRemaining` never underflows.
- Executed input never exceeds `amountInTotal`.
- `nextSliceIndex` advances exactly once per successful slice.
- A completed order cannot become active again.
