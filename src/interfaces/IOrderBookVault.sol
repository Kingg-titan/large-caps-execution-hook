// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    CreateOrderParams,
    OrderState,
    PendingSlice,
    SlicePreview,
    ReasonCode,
    ExecutionMode,
    HookOrderData
} from "src/types/LargeCapTypes.sol";

interface IOrderBookVault {
    event OrderCreated(bytes32 indexed orderId, address indexed owner, bytes32 indexed poolId, ExecutionMode mode);
    event OrderCancelled(bytes32 indexed orderId, address indexed owner);
    event SliceSkipped(bytes32 indexed orderId, uint64 sliceIndex, ReasonCode reasonCode);
    event OrderCompleted(bytes32 indexed orderId, uint128 totalIn, uint128 totalOut, uint160 avgPriceX96);
    event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event HookUpdated(address indexed oldHook, address indexed newHook);

    function createOrder(CreateOrderParams calldata params) external returns (bytes32 orderId);

    function cancelOrder(bytes32 orderId) external;

    function claimOutput(bytes32 orderId, uint128 amount, address recipient) external returns (uint128 claimed);

    function withdrawRemainingInput(bytes32 orderId, address recipient) external returns (uint128 amount);

    function previewNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)
        external
        view
        returns (SlicePreview memory preview);

    function reserveNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)
        external
        returns (SlicePreview memory preview);

    function clearPendingSlice(bytes32 orderId, uint64 sliceIndex) external;

    function validateHookExecution(
        bytes32 orderId,
        uint64 sliceIndex,
        uint128 amountIn,
        bytes32 poolId,
        bool zeroForOne
    ) external view returns (ReasonCode reasonCode);

    function recordAfterSwap(bytes32 orderId, uint64 sliceIndex, uint128 amountIn, uint128 amountOut)
        external
        returns (bool completed, uint160 avgPriceX96);

    function getOrder(bytes32 orderId) external view returns (OrderState memory order);

    function getPendingSlice(bytes32 orderId) external view returns (PendingSlice memory pending);

    function currentNonce(address owner) external view returns (uint64 nonce);

    function hook() external view returns (address);

    function executor() external view returns (address);
}
