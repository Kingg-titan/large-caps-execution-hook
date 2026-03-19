// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {OrderState, OrderStatus, ReasonCode} from "src/types/LargeCapTypes.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface ILargeCapExecutor {
    struct ExecuteParams {
        bytes32 orderId;
        PoolKey poolKey;
        uint24 observedImpactBps;
        uint160 sqrtPriceLimitX96;
        uint40 deadline;
    }

    function executeNextSlice(ExecuteParams calldata params)
        external
        returns (bool executed, ReasonCode reasonCode, uint128 amountOut);
}

/**
 * @title LargeCapReactiveCallback
 * @notice Callback destination contract invoked by Reactive callback proxy to execute next slice.
 * @custom:security-contact security@largecap-hook.example
 */
contract LargeCapReactiveCallback is AbstractCallback {
    using PoolIdLibrary for PoolKey;

    error LargeCapReactiveCallback__Unauthorized();
    error LargeCapReactiveCallback__InvalidAddress();
    error LargeCapReactiveCallback__InvalidImpactBps();
    error LargeCapReactiveCallback__InvalidDeadlineBuffer();

    struct ExecutionOverride {
        uint24 observedImpactBps;
        uint160 sqrtPriceLimitX96;
        bool enabled;
    }

    IOrderBookVault public immutable vault;
    ILargeCapExecutor public immutable executor;

    address public owner;
    address public expectedReactiveSender;

    uint24 public defaultObservedImpactBps;
    uint40 public deadlineBufferSeconds;

    mapping(bytes32 poolId => PoolKey key) private s_poolKeys;
    mapping(bytes32 poolId => bool isRegistered) private s_poolKeyRegistered;
    mapping(bytes32 orderId => ExecutionOverride overrideConfig) private s_orderOverrides;

    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event ExpectedReactiveSenderUpdated(address indexed oldSender, address indexed newSender);
    event DefaultExecutionConfigUpdated(uint24 observedImpactBps, uint40 deadlineBufferSeconds);
    event PoolKeyRegistered(bytes32 indexed poolId, address currency0, address currency1, uint24 fee, int24 tickSpacing);
    event OrderExecutionOverrideSet(
        bytes32 indexed orderId, uint24 observedImpactBps, uint160 sqrtPriceLimitX96, bool enabled
    );
    event ReactiveOrderSkipped(bytes32 indexed orderId, ReasonCode reasonCode);
    event ReactiveSliceExecutionAttempt(
        bytes32 indexed orderId, address indexed reactiveSender, bool executed, ReasonCode reasonCode, uint128 amountOut
    );
    event ReactiveSliceExecutionFailure(bytes32 indexed orderId, bytes revertData);

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert LargeCapReactiveCallback__Unauthorized();
        }
        _;
    }

    constructor(address callbackSender, IOrderBookVault vault_, ILargeCapExecutor executor_, address owner_)
        AbstractCallback(callbackSender)
        payable
    {
        if (callbackSender == address(0) || address(vault_) == address(0) || address(executor_) == address(0) || owner_ == address(0)) {
            revert LargeCapReactiveCallback__InvalidAddress();
        }

        vault = vault_;
        executor = executor_;
        owner = owner_;

        defaultObservedImpactBps = 50;
        deadlineBufferSeconds = 10 minutes;
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert LargeCapReactiveCallback__InvalidAddress();
        }

        address oldOwner = owner;
        owner = newOwner;

        emit OwnerUpdated(oldOwner, newOwner);
    }

    function setExpectedReactiveSender(address newSender) external onlyOwner {
        address oldSender = expectedReactiveSender;
        expectedReactiveSender = newSender;

        emit ExpectedReactiveSenderUpdated(oldSender, newSender);
    }

    function setDefaultExecutionConfig(uint24 observedImpactBps, uint40 deadlineBufferSeconds_) external onlyOwner {
        if (observedImpactBps == 0 || observedImpactBps > 10_000) {
            revert LargeCapReactiveCallback__InvalidImpactBps();
        }
        if (deadlineBufferSeconds_ == 0) {
            revert LargeCapReactiveCallback__InvalidDeadlineBuffer();
        }

        defaultObservedImpactBps = observedImpactBps;
        deadlineBufferSeconds = deadlineBufferSeconds_;

        emit DefaultExecutionConfigUpdated(observedImpactBps, deadlineBufferSeconds_);
    }

    function registerPoolKey(PoolKey calldata poolKey) external onlyOwner returns (bytes32 poolId) {
        poolId = PoolId.unwrap(poolKey.toId());

        s_poolKeys[poolId] = poolKey;
        s_poolKeyRegistered[poolId] = true;

        emit PoolKeyRegistered(
            poolId,
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            poolKey.fee,
            poolKey.tickSpacing
        );
    }

    function setOrderExecutionOverride(bytes32 orderId, uint24 observedImpactBps, uint160 sqrtPriceLimitX96, bool enabled)
        external
        onlyOwner
    {
        if (observedImpactBps == 0 || observedImpactBps > 10_000) {
            revert LargeCapReactiveCallback__InvalidImpactBps();
        }

        s_orderOverrides[orderId] = ExecutionOverride({
            observedImpactBps: observedImpactBps,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            enabled: enabled
        });

        emit OrderExecutionOverrideSet(orderId, observedImpactBps, sqrtPriceLimitX96, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                         USER-FACING READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPoolKey(bytes32 poolId) external view returns (PoolKey memory key, bool registered) {
        key = s_poolKeys[poolId];
        registered = s_poolKeyRegistered[poolId];
    }

    function getOrderExecutionOverride(bytes32 orderId) external view returns (ExecutionOverride memory overrideConfig) {
        overrideConfig = s_orderOverrides[orderId];
    }

    /*//////////////////////////////////////////////////////////////
                       REACTIVE CALLBACK ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    function callback(address reactiveSender, bytes32 orderId)
        external
        authorizedSenderOnly
        returns (bool executed, ReasonCode reasonCode, uint128 amountOut)
    {
        if (expectedReactiveSender != address(0) && reactiveSender != expectedReactiveSender) {
            revert LargeCapReactiveCallback__Unauthorized();
        }

        OrderState memory order = vault.getOrder(orderId);

        if (order.orderId == bytes32(0)) {
            reasonCode = ReasonCode.INVALID_CALLER;
            emit ReactiveOrderSkipped(orderId, reasonCode);
            return (false, reasonCode, 0);
        }

        if (order.status != OrderStatus.ACTIVE || order.amountInRemaining == 0) {
            reasonCode = ReasonCode.ALREADY_COMPLETED;
            emit ReactiveOrderSkipped(orderId, reasonCode);
            return (false, reasonCode, 0);
        }

        PoolKey memory poolKey = s_poolKeys[order.poolId];
        if (!s_poolKeyRegistered[order.poolId] || PoolId.unwrap(poolKey.toId()) != order.poolId) {
            reasonCode = ReasonCode.INVALID_CALLER;
            emit ReactiveOrderSkipped(orderId, reasonCode);
            return (false, reasonCode, 0);
        }

        ExecutionOverride memory overrideConfig = s_orderOverrides[orderId];

        uint24 observedImpactBps = overrideConfig.enabled ? overrideConfig.observedImpactBps : defaultObservedImpactBps;

        uint160 sqrtPriceLimitX96 =
            _resolveSqrtPriceLimit(order.zeroForOne, overrideConfig.enabled, overrideConfig.sqrtPriceLimitX96);

        try executor.executeNextSlice(
            ILargeCapExecutor.ExecuteParams({
                orderId: orderId,
                poolKey: poolKey,
                observedImpactBps: observedImpactBps,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                deadline: uint40(block.timestamp + deadlineBufferSeconds)
            })
        ) returns (bool _executed, ReasonCode _reasonCode, uint128 _amountOut) {
            executed = _executed;
            reasonCode = _reasonCode;
            amountOut = _amountOut;

            emit ReactiveSliceExecutionAttempt(orderId, reactiveSender, executed, reasonCode, amountOut);
            return (executed, reasonCode, amountOut);
        } catch (bytes memory revertData) {
            reasonCode = ReasonCode.SLIPPAGE_TOO_HIGH;

            emit ReactiveSliceExecutionFailure(orderId, revertData);
            emit ReactiveSliceExecutionAttempt(orderId, reactiveSender, false, reasonCode, 0);

            return (false, reasonCode, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL READ HELPERS
    //////////////////////////////////////////////////////////////*/

    function _resolveSqrtPriceLimit(bool zeroForOne, bool hasOverride, uint160 overrideLimit)
        internal
        pure
        returns (uint160 sqrtPriceLimitX96)
    {
        if (hasOverride && overrideLimit != 0) {
            return overrideLimit;
        }

        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
