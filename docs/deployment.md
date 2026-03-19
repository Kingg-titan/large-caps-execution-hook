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
make demo-testnet
```

`make demo-testnet` executes `scripts/demo_workflow.sh`.

The workflow script:

- `OrderBookVault`
- `LargeCapExecutionHook`
- `Executor`
- `LargeCapReactiveCallback` (Unichain destination chain)
- `LargeCapReactiveScheduler` (Reactive chain)

It also:

- writes deployed addresses/tx hashes into `.env` if deployment is required,
- selects a healthy Unichain RPC endpoint from configured + default fallbacks,
- runs the Unichain compare demo script,
- prints explorer URLs for every transaction emitted by the demo run.

## Reactive Sender Validation

Reactive callback infra rewrites the first `address` callback argument to the ReactVM ID (the deployer address for the reactive contract VM).

Because of this, sender validation for `LargeCapReactiveCallback` should use the ReactVM ID, not the scheduler contract address.

The workflow script auto-sets:

- `LARGE_CAP_REACTIVE_EXPECTED_SENDER=<reactive deployer EOA>`

You can override it manually if your deployment model differs.
