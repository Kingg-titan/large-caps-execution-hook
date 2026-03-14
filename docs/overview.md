# Overview

Large-Cap Execution Hook is a Uniswap v4 execution primitive for large orders.

It targets two execution modes:

- `BBE` (Block-Based Execution): one slice every `blocksPerSlice` blocks.
- `SOF` (Segmented Order Flow): time-windowed slices with `minIntervalSeconds` cadence.

Core outcomes:

- Lower per-slice price impact versus single-shot swaps.
- Reduced MEV surface through deterministic cadence and capped slice size.
- Onchain accounting of partial fills, completion, and claimable output.

## Components

- `OrderBookVault`: order storage, policy checks, slice reservation, accounting.
- `LargeCapExecutionHook`: Uniswap v4 `beforeSwap` / `afterSwap` policy enforcement.
- `Executor`: unlock-callback swap execution and PoolManager settlement.
- `frontend/`: execution console for order creation, progress tracking, baseline comparison.
