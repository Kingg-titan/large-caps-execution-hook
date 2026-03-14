// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {PoolManagerSettlement} from "src/libraries/PoolManagerSettlement.sol";
import {HookOrderData, OrderState, SlicePreview, ReasonCode} from "src/types/LargeCapTypes.sol";

/**
 * @title Executor
 * @notice Executes next eligible slices by swapping against PoolManager and settling to the vault.
 * @custom:security-contact security@largecap-hook.example
 */
contract Executor is IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using PoolManagerSettlement for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error Executor__InvalidDeadline();
    error Executor__NotPoolManager();
    error Executor__UnexpectedUnlockResponse();

    event SliceExecutionAttempt(bytes32 indexed orderId, uint64 indexed sliceIndex, uint128 amountIn);
    event SliceExecutionResult(
        bytes32 indexed orderId, uint64 indexed sliceIndex, bool executed, ReasonCode reasonCode, uint128 amountOut
    );

    struct ExecuteParams {
        bytes32 orderId;
        PoolKey poolKey;
        uint24 observedImpactBps;
        uint160 sqrtPriceLimitX96;
        uint40 deadline;
    }

    struct UnlockPayload {
        PoolKey poolKey;
        SwapParams swapParams;
        bytes hookData;
    }

    IOrderBookVault public immutable vault;
    IPoolManager public immutable poolManager;
    ILargeCapExecutionHookEvents public immutable hook;

    constructor(
        address initialOwner,
        IOrderBookVault vault_,
        IPoolManager poolManager_,
        ILargeCapExecutionHookEvents hook_
    ) Ownable(initialOwner) {
        vault = vault_;
        poolManager = poolManager_;
        hook = hook_;
    }

    /*//////////////////////////////////////////////////////////////
                      USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function executeNextSlice(ExecuteParams calldata params)
        external
        nonReentrant
        returns (bool executed, ReasonCode reasonCode, uint128 amountOut)
    {
        if (params.deadline < block.timestamp) {
            revert Executor__InvalidDeadline();
        }

        SlicePreview memory preview = vault.reserveNextSlice(
            params.orderId, PoolId.unwrap(params.poolKey.toId()), params.observedImpactBps, msg.sender
        );

        if (preview.reasonCode != ReasonCode.NONE) {
            hook.reportSliceBlocked(params.orderId, preview.sliceIndex, preview.reasonCode);
            emit SliceExecutionResult(params.orderId, preview.sliceIndex, false, preview.reasonCode, 0);
            return (false, preview.reasonCode, 0);
        }

        OrderState memory order = vault.getOrder(params.orderId);

        HookOrderData memory hookData = HookOrderData({
            orderId: params.orderId,
            sliceIndex: preview.sliceIndex,
            amountIn: preview.amountIn,
            minAmountOut: preview.minAmountOut
        });

        SwapParams memory swapParams = SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: -int256(uint256(preview.amountIn)),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });

        bytes memory unlockData = abi.encode(
            UnlockPayload({poolKey: params.poolKey, swapParams: swapParams, hookData: abi.encode(hookData)})
        );

        emit SliceExecutionAttempt(params.orderId, preview.sliceIndex, preview.amountIn);

        try poolManager.unlock(unlockData) returns (bytes memory callbackResult) {
            if (callbackResult.length != 32) {
                revert Executor__UnexpectedUnlockResponse();
            }

            BalanceDelta delta = abi.decode(callbackResult, (BalanceDelta));
            if (order.zeroForOne) {
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

            emit SliceExecutionResult(params.orderId, preview.sliceIndex, true, ReasonCode.NONE, amountOut);
            return (true, ReasonCode.NONE, amountOut);
        } catch {
            IERC20(order.tokenIn).safeTransfer(address(vault), preview.amountIn);
            vault.clearPendingSlice(params.orderId, preview.sliceIndex);

            reasonCode = ReasonCode.SLIPPAGE_TOO_HIGH;
            hook.reportSliceBlocked(params.orderId, preview.sliceIndex, reasonCode);
            emit SliceExecutionResult(params.orderId, preview.sliceIndex, false, reasonCode, 0);
            return (false, reasonCode, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        POOLMANAGER CALLBACK
    //////////////////////////////////////////////////////////////*/

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert Executor__NotPoolManager();
        }

        UnlockPayload memory payload = abi.decode(rawData, (UnlockPayload));
        BalanceDelta delta = poolManager.swap(payload.poolKey, payload.swapParams, payload.hookData);

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            payload.poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-amount0)));
        } else if (amount0 > 0) {
            payload.poolKey.currency0.take(poolManager, address(vault), uint256(uint128(amount0)));
        }

        if (amount1 < 0) {
            payload.poolKey.currency1.settle(poolManager, address(this), uint256(uint128(-amount1)));
        } else if (amount1 > 0) {
            payload.poolKey.currency1.take(poolManager, address(vault), uint256(uint128(amount1)));
        }

        return abi.encode(delta);
    }

    receive() external payable {}
}
