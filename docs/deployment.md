# Deployment

## Prerequisites

- Foundry installed.
- `PRIVATE_KEY` set in environment.
- RPC endpoint for target chain.

## Deterministic Dependency Bootstrap

```bash
./scripts/bootstrap.sh
```

This script:

- Initializes submodules.
- Pins `v4-periphery` to `3779387e5d296f39df543d23524b050f89a62917`.
- Pins `v4-core` to the commit referenced by that periphery commit.
- Fails on mismatch.

## Local Deployment

```bash
make demo-local
```

## Testnet Deployment

```bash
export TESTNET_RPC_URL="..."
export PRIVATE_KEY="..."
make demo-testnet
```

The deploy script prints deployed addresses for:

- `OrderBookVault`
- `LargeCapExecutionHook`
- `Executor`
