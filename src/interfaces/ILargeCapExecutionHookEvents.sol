// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ExecutionMode, ReasonCode} from "src/types/LargeCapTypes.sol";

interface ILargeCapExecutionHookEvents {
    function notifyOrderCreated(bytes32 orderId, address owner, bytes32 poolId, ExecutionMode mode) external;

    function notifyOrderCancelled(bytes32 orderId, address owner) external;

    function notifyOrderCompleted(bytes32 orderId, uint128 totalIn, uint128 totalOut, uint160 avgPriceX96) external;

    function reportSliceBlocked(bytes32 orderId, uint64 sliceIndex, ReasonCode reasonCode) external;
}
