# Execution Modes

## BBE (Block-Based Execution)

Parameters:

- `blocksPerSlice`
- `maxSliceAmount`
- `minSliceAmount`
- `maxImpactBps`

Behavior:

- At most one eligible slice per configured block cadence.
- Useful for deterministic anti-burst execution.

## SOF (Segmented Order Flow)

Parameters:

- `startTime`, `endTime`
- `minIntervalSeconds`
- `maxSliceAmount`, `minSliceAmount`
- `maxImpactBps`

Behavior:

- Time-windowed slicing with minimum inter-slice interval.
- Better for scheduled treasury execution windows.

## Shared Slice Checks

For both modes, slice execution checks:

- Order active and not expired.
- Cadence cooldown satisfied.
- `observedImpactBps <= maxImpactBps`.
- `amountOut >= minAmountOutPerSlice`.
- Pending slice context matches hook data exactly.
