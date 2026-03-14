// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

enum ExecutionMode {
    BBE,
    SOF
}

enum OrderStatus {
    ACTIVE,
    CANCELLED,
    COMPLETED,
    EXPIRED
}

enum ReasonCode {
    NONE,
    NOT_STARTED,
    EXPIRED,
    COOLDOWN,
    IMPACT_TOO_HIGH,
    SLIPPAGE_TOO_HIGH,
    NO_LIQUIDITY,
    INVALID_CALLER,
    ALREADY_COMPLETED
}

struct CreateOrderParams {
    bytes32 poolId;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint128 amountInTotal;
    ExecutionMode mode;
    uint40 startTime;
    uint40 endTime;
    uint32 minIntervalSeconds;
    uint32 blocksPerSlice;
    uint128 maxSliceAmount;
    uint128 minSliceAmount;
    uint24 maxImpactBps;
    uint128 minAmountOutPerSlice;
    address allowedExecutor;
}

struct OrderState {
    bytes32 orderId;
    address owner;
    bytes32 poolId;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint128 amountInTotal;
    uint128 amountInRemaining;
    uint128 amountOutTotal;
    uint128 amountOutClaimed;
    ExecutionMode mode;
    uint40 startTime;
    uint40 endTime;
    uint32 minIntervalSeconds;
    uint32 blocksPerSlice;
    uint128 maxSliceAmount;
    uint128 minSliceAmount;
    uint24 maxImpactBps;
    uint128 minAmountOutPerSlice;
    OrderStatus status;
    uint64 nonce;
    uint64 epoch;
    uint64 nextSliceIndex;
    uint64 lastExecutionBlock;
    uint40 lastExecutionTime;
    address allowedExecutor;
}

struct PendingSlice {
    uint128 amountIn;
    uint128 minAmountOut;
    uint64 sliceIndex;
    uint24 observedImpactBps;
    bool exists;
}

struct SlicePreview {
    ReasonCode reasonCode;
    uint128 amountIn;
    uint128 minAmountOut;
    uint64 sliceIndex;
}

struct HookOrderData {
    bytes32 orderId;
    uint64 sliceIndex;
    uint128 amountIn;
    uint128 minAmountOut;
}
