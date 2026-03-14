// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {ExecutionMode, HookOrderData, ReasonCode} from "src/types/LargeCapTypes.sol";

/**
 * @title LargeCapExecutionHook
 * @notice Swap-policy hook for segmented large-cap order execution.
 * @custom:security-contact security@largecap-hook.example
 */
contract LargeCapExecutionHook is BaseHook, ILargeCapExecutionHookEvents {
    using PoolIdLibrary for PoolKey;

    error LargeCapExecutionHook__NotVault();
    error LargeCapExecutionHook__InvalidReporter();
    error LargeCapExecutionHook__InvalidHookData();
    error LargeCapExecutionHook__SliceBlocked(ReasonCode reasonCode);

    event SliceExecuted(
        bytes32 indexed orderId, uint64 sliceIndex, uint128 amountIn, uint128 amountOut, uint256 blockNumber
    );
    event SliceBlocked(bytes32 indexed orderId, uint64 sliceIndex, ReasonCode reasonCode);
    event OrderCreated(bytes32 indexed orderId, address indexed owner, bytes32 indexed poolId, ExecutionMode mode);
    event OrderCancelled(bytes32 indexed orderId, address indexed owner);
    event OrderCompleted(bytes32 indexed orderId, uint128 totalIn, uint128 totalOut, uint160 avgPriceX96);

    IOrderBookVault public immutable vault;

    constructor(IPoolManager poolManager_, IOrderBookVault vault_) BaseHook(poolManager_) {
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != address(vault)) {
            revert LargeCapExecutionHook__NotVault();
        }
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                      ILargeCapExecutionHookEvents
    //////////////////////////////////////////////////////////////*/

    function notifyOrderCreated(bytes32 orderId, address owner, bytes32 poolId, ExecutionMode mode) external onlyVault {
        emit OrderCreated(orderId, owner, poolId, mode);
    }

    function notifyOrderCancelled(bytes32 orderId, address owner) external onlyVault {
        emit OrderCancelled(orderId, owner);
    }

    function notifyOrderCompleted(bytes32 orderId, uint128 totalIn, uint128 totalOut, uint160 avgPriceX96)
        external
        onlyVault
    {
        emit OrderCompleted(orderId, totalIn, totalOut, avgPriceX96);
    }

    function reportSliceBlocked(bytes32 orderId, uint64 sliceIndex, ReasonCode reasonCode) external {
        if (msg.sender != address(vault) && msg.sender != vault.executor()) {
            revert LargeCapExecutionHook__InvalidReporter();
        }

        emit SliceBlocked(orderId, sliceIndex, reasonCode);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL HOOK IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookOrderData memory data = _decodeHookData(hookData);

        ReasonCode reasonCode = vault.validateHookExecution(
            data.orderId, data.sliceIndex, data.amountIn, PoolId.unwrap(key.toId()), params.zeroForOne
        );

        if (reasonCode == ReasonCode.NONE && sender != vault.executor()) {
            reasonCode = ReasonCode.INVALID_CALLER;
        }

        if (reasonCode != ReasonCode.NONE) {
            revert LargeCapExecutionHook__SliceBlocked(reasonCode);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        HookOrderData memory data = _decodeHookData(hookData);

        uint128 amountOut;
        if (params.zeroForOne) {
            int128 rawAmountOut = delta.amount1();
            if (rawAmountOut > 0) {
                amountOut = uint128(uint128(rawAmountOut));
            }
        } else {
            int128 rawAmountOut = delta.amount0();
            if (rawAmountOut > 0) {
                amountOut = uint128(uint128(rawAmountOut));
            }
        }

        vault.recordAfterSwap(data.orderId, data.sliceIndex, data.amountIn, amountOut);
        emit SliceExecuted(data.orderId, data.sliceIndex, data.amountIn, amountOut, block.number);

        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL READ HELPERS
    //////////////////////////////////////////////////////////////*/

    function _decodeHookData(bytes calldata hookData) internal pure returns (HookOrderData memory data) {
        if (hookData.length != 128) {
            revert LargeCapExecutionHook__InvalidHookData();
        }

        data = abi.decode(hookData, (HookOrderData));
    }
}
