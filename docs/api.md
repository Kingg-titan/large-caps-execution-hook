# API

## OrderBookVault

Primary methods:

- `createOrder(CreateOrderParams)`
- `cancelOrder(bytes32 orderId)`
- `previewNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)`
- `reserveNextSlice(...)`
- `recordAfterSwap(...)`
- `claimOutput(bytes32 orderId, uint128 amount, address recipient)`
- `withdrawRemainingInput(bytes32 orderId, address recipient)`

## LargeCapExecutionHook

Core hooks:

- `beforeSwap(...)`
- `afterSwap(...)`

Telemetry helpers:

- `notifyOrderCreated(...)`
- `notifyOrderCancelled(...)`
- `notifyOrderCompleted(...)`
- `reportSliceBlocked(...)`

## Executor

- `executeNextSlice(ExecuteParams)`
- `unlockCallback(bytes)`

## Events

- `OrderCreated`
- `OrderCancelled`
- `SliceSkipped`
- `SliceExecuted`
- `SliceBlocked`
- `OrderCompleted`
