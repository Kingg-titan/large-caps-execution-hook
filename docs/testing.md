# Testing

## Test Classes

- Unit and edge tests: `test/OrderBookVault.t.sol`
- Branch-complete unit tests: `test/OrderBookVault.branch.t.sol`
- Hook unit tests: `test/LargeCapExecutionHook.unit.t.sol`
- Executor unit tests: `test/Executor.unit.t.sol`
- Settlement library tests: `test/PoolManagerSettlement.t.sol`
- Counter hook unit tests: `test/Counter.unit.t.sol`
- Integration lifecycle: `test/LargeCapExecutionHook.integration.t.sol`
- Stateless fuzz: `test/fuzz/OrderBookVaultFuzz.t.sol`
- Stateful invariants: `test/invariant/OrderBookVaultInvariant.t.sol`

## Commands

```bash
forge test -vv
forge coverage --report summary --exclude-tests --no-match-coverage "script/|test/"
```

## Covered Edge Cases

- Not-started schedule.
- Expiry during lifecycle.
- Cancel + input refund.
- Unauthorized reserve attempts.
- Slice reservation + settlement accounting.
- Allowed executor enforcement.

## Covered Invariants

- Executed amount never exceeds total.
- Remaining amount bounded by total.
- Slice index tracks successful execution count.
- Completed status does not revert to active.
