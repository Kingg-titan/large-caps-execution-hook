# Security

## Trust Model

- `OrderBookVault` owner configures hook and executor addresses.
- Execution can be permissionless (`allowedExecutor = 0`) or keeper-restricted per order.
- Hook entrypoints are callable only by Uniswap v4 `PoolManager`.

## Attack Surfaces and Mitigations

### Griefing via failed slices

- Failed execution paths clear pending slice state.
- Reserved input is returned to vault on failed execution in `Executor` catch path.

### State desynchronization

- Pending slice tuple (`orderId`, `sliceIndex`, `amountIn`) is verified in hook and vault.
- Accounting finalizes only via hook `afterSwap` callback.

### Price-impact manipulation

- `maxImpactBps` enforced before reservation and re-validated during hook checks.
- Slice size caps reduce exposure per execution.

### Executor frontrunning / arbitrary caller execution

- Vault enforces `allowedExecutor` at reservation stage.
- Hook enforces expected swap caller (`vault.executor()`).

### Admin risk

- Owner can rotate hook/executor addresses.
- Production deployment should transfer ownership to multisig.

## Remaining Risks

- Impact input is an observed value; robust impact oracles should be added for production.
- Keeper censorship remains possible under restricted-executor policy.
- Hooks remain experimental and should be independently audited before mainnet deployment.
