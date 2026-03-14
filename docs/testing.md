# Testing

## Test Classes

- Unit and edge tests: `test/OrderBookVault.t.sol`
- Integration lifecycle: `test/LargeCapExecutionHook.integration.t.sol`
- Stateless fuzz: `test/fuzz/OrderBookVaultFuzz.t.sol`
- Stateful invariants: `test/invariant/OrderBookVaultInvariant.t.sol`

## Commands

```bash
forge test -vv
forge coverage --report summary
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
