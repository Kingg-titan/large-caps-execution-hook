// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {OrderState, OrderStatus, ExecutionMode, ReasonCode} from "src/types/LargeCapTypes.sol";
import {LargeCapReactiveCallback, ILargeCapExecutor} from "src/reactive/LargeCapReactiveCallback.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract MockVaultReactive {
    mapping(bytes32 => OrderState) internal s_orders;

    function setOrder(bytes32 orderId, OrderState calldata order) external {
        s_orders[orderId] = order;
    }

    function getOrder(bytes32 orderId) external view returns (OrderState memory order) {
        order = s_orders[orderId];
    }
}

contract MockExecutorReactive is ILargeCapExecutor {
    using PoolIdLibrary for PoolKey;

    bool public shouldRevert;

    bool public configuredExecuted;
    ReasonCode public configuredReason;
    uint128 public configuredAmountOut;

    bytes32 public lastOrderId;
    bytes32 public lastPoolId;
    uint24 public lastObservedImpactBps;
    uint160 public lastSqrtPriceLimitX96;
    uint40 public lastDeadline;

    function configureResult(bool executed, ReasonCode reasonCode, uint128 amountOut) external {
        configuredExecuted = executed;
        configuredReason = reasonCode;
        configuredAmountOut = amountOut;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function executeNextSlice(ExecuteParams calldata params)
        external
        returns (bool executed, ReasonCode reasonCode, uint128 amountOut)
    {
        if (shouldRevert) {
            revert("MOCK_EXECUTOR_REVERT");
        }

        lastOrderId = params.orderId;
        lastPoolId = PoolId.unwrap(params.poolKey.toId());
        lastObservedImpactBps = params.observedImpactBps;
        lastSqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        lastDeadline = params.deadline;

        return (configuredExecuted, configuredReason, configuredAmountOut);
    }
}

contract LargeCapReactiveCallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant CALLBACK_PROXY = address(0x9999999999999999999999999999999999999999);
    address internal constant OWNER = address(0xABCDEF);
    address internal constant REACTIVE_SENDER = address(0x123456);

    MockVaultReactive internal mockVault;
    MockExecutorReactive internal mockExecutor;
    LargeCapReactiveCallback internal callback;

    PoolKey internal defaultPoolKey;
    bytes32 internal defaultPoolId;

    function setUp() external {
        mockVault = new MockVaultReactive();
        mockExecutor = new MockExecutorReactive();

        callback = new LargeCapReactiveCallback(
            CALLBACK_PROXY, IOrderBookVault(address(mockVault)), ILargeCapExecutor(address(mockExecutor)), OWNER
        );

        defaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1001)),
            currency1: Currency.wrap(address(0x1002)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x1003))
        });
        defaultPoolId = PoolId.unwrap(defaultPoolKey.toId());

        vm.prank(OWNER);
        callback.registerPoolKey(defaultPoolKey);

        mockExecutor.configureResult(true, ReasonCode.NONE, 777);
    }

    function testConstructorValidation() external {
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidAddress.selector);
        new LargeCapReactiveCallback(
            address(0), IOrderBookVault(address(mockVault)), ILargeCapExecutor(address(mockExecutor)), OWNER
        );

        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidAddress.selector);
        new LargeCapReactiveCallback(
            CALLBACK_PROXY, IOrderBookVault(address(0)), ILargeCapExecutor(address(mockExecutor)), OWNER
        );

        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidAddress.selector);
        new LargeCapReactiveCallback(CALLBACK_PROXY, IOrderBookVault(address(mockVault)), ILargeCapExecutor(address(0)), OWNER);

        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidAddress.selector);
        new LargeCapReactiveCallback(
            CALLBACK_PROXY, IOrderBookVault(address(mockVault)), ILargeCapExecutor(address(mockExecutor)), address(0)
        );
    }

    function testOwnerControls() external {
        assertEq(callback.owner(), OWNER);

        vm.prank(OWNER);
        callback.setOwner(address(0xBEEF));
        assertEq(callback.owner(), address(0xBEEF));

        vm.prank(address(0xBEEF));
        callback.setExpectedReactiveSender(REACTIVE_SENDER);
        assertEq(callback.expectedReactiveSender(), REACTIVE_SENDER);

        vm.prank(address(0xBEEF));
        callback.setDefaultExecutionConfig(100, 1200);
        assertEq(callback.defaultObservedImpactBps(), 100);
        assertEq(callback.deadlineBufferSeconds(), 1200);
    }

    function testOwnerControlValidationAndAccess() external {
        vm.prank(address(0xDEAD));
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__Unauthorized.selector);
        callback.setOwner(address(0xBEEF));

        vm.prank(OWNER);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidAddress.selector);
        callback.setOwner(address(0));

        vm.prank(address(0xDEAD));
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__Unauthorized.selector);
        callback.setDefaultExecutionConfig(100, 1000);

        vm.prank(OWNER);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidImpactBps.selector);
        callback.setDefaultExecutionConfig(0, 1000);

        vm.prank(OWNER);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidImpactBps.selector);
        callback.setDefaultExecutionConfig(10_001, 1000);

        vm.prank(OWNER);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidDeadlineBuffer.selector);
        callback.setDefaultExecutionConfig(100, 0);

        vm.prank(address(0xDEAD));
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__Unauthorized.selector);
        callback.registerPoolKey(defaultPoolKey);

        vm.prank(OWNER);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__InvalidImpactBps.selector);
        callback.setOrderExecutionOverride(bytes32(uint256(1)), 0, 0, true);
    }

    function testGetters() external view {
        (PoolKey memory key, bool registered) = callback.getPoolKey(defaultPoolId);
        assertTrue(registered);
        assertEq(PoolId.unwrap(key.toId()), defaultPoolId);

        LargeCapReactiveCallback.ExecutionOverride memory overrideConfig =
            callback.getOrderExecutionOverride(bytes32(uint256(999)));
        assertFalse(overrideConfig.enabled);
    }

    function testCallbackRevertsWhenCallerIsNotProxy() external {
        bytes32 orderId = keccak256("order-unauthorized");
        vm.expectRevert("Authorized sender only");
        callback.callback(REACTIVE_SENDER, orderId);
    }

    function testCallbackRevertsOnUnexpectedReactiveSender() external {
        bytes32 orderId = keccak256("order-reactive-sender");

        vm.prank(OWNER);
        callback.setExpectedReactiveSender(REACTIVE_SENDER);

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(LargeCapReactiveCallback.LargeCapReactiveCallback__Unauthorized.selector);
        callback.callback(address(0x4567), orderId);
    }

    function testCallbackSkipsMissingAndInactiveOrders() external {
        bytes32 missingOrderId = keccak256("missing-order");

        vm.prank(CALLBACK_PROXY);
        (bool executedMissing, ReasonCode reasonMissing, uint128 outMissing) = callback.callback(REACTIVE_SENDER, missingOrderId);
        assertFalse(executedMissing);
        assertEq(uint8(reasonMissing), uint8(ReasonCode.INVALID_CALLER));
        assertEq(outMissing, 0);

        bytes32 inactiveOrderId = keccak256("inactive-order");
        _setOrder(inactiveOrderId, defaultPoolId, false, OrderStatus.COMPLETED, 0);

        vm.prank(CALLBACK_PROXY);
        (bool executedInactive, ReasonCode reasonInactive, uint128 outInactive) =
            callback.callback(REACTIVE_SENDER, inactiveOrderId);
        assertFalse(executedInactive);
        assertEq(uint8(reasonInactive), uint8(ReasonCode.ALREADY_COMPLETED));
        assertEq(outInactive, 0);
    }

    function testCallbackSkipsWhenPoolKeyMissing() external {
        bytes32 orderId = keccak256("missing-pool-key");
        bytes32 unknownPoolId = keccak256("unknown-pool");

        _setOrder(orderId, unknownPoolId, true, OrderStatus.ACTIVE, 1e18);

        vm.prank(CALLBACK_PROXY);
        (bool executed, ReasonCode reasonCode, uint128 amountOut) = callback.callback(REACTIVE_SENDER, orderId);

        assertFalse(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.INVALID_CALLER));
        assertEq(amountOut, 0);
    }

    function testCallbackExecutesWithDefaultPriceLimitBothDirections() external {
        bytes32 orderIdZeroForOne = keccak256("order-zfo");
        _setOrder(orderIdZeroForOne, defaultPoolId, true, OrderStatus.ACTIVE, 1e18);

        vm.prank(CALLBACK_PROXY);
        (bool executedOne, ReasonCode reasonOne, uint128 outOne) = callback.callback(REACTIVE_SENDER, orderIdZeroForOne);
        assertTrue(executedOne);
        assertEq(uint8(reasonOne), uint8(ReasonCode.NONE));
        assertEq(outOne, 777);
        assertEq(mockExecutor.lastOrderId(), orderIdZeroForOne);
        assertEq(mockExecutor.lastPoolId(), defaultPoolId);
        assertEq(mockExecutor.lastObservedImpactBps(), callback.defaultObservedImpactBps());
        assertEq(mockExecutor.lastSqrtPriceLimitX96(), TickMath.MIN_SQRT_PRICE + 1);
        assertGt(mockExecutor.lastDeadline(), uint40(block.timestamp));

        bytes32 orderIdOneForZero = keccak256("order-ofz");
        _setOrder(orderIdOneForZero, defaultPoolId, false, OrderStatus.ACTIVE, 1e18);

        vm.prank(CALLBACK_PROXY);
        callback.callback(REACTIVE_SENDER, orderIdOneForZero);
        assertEq(mockExecutor.lastSqrtPriceLimitX96(), TickMath.MAX_SQRT_PRICE - 1);
    }

    function testCallbackExecutesWithOverrideAndCatchPath() external {
        bytes32 orderId = keccak256("order-override");
        _setOrder(orderId, defaultPoolId, true, OrderStatus.ACTIVE, 1e18);

        vm.prank(OWNER);
        callback.setOrderExecutionOverride(orderId, 250, 12345, true);

        vm.prank(CALLBACK_PROXY);
        callback.callback(REACTIVE_SENDER, orderId);

        assertEq(mockExecutor.lastObservedImpactBps(), 250);
        assertEq(mockExecutor.lastSqrtPriceLimitX96(), 12345);

        mockExecutor.setShouldRevert(true);

        vm.prank(CALLBACK_PROXY);
        (bool executed, ReasonCode reasonCode, uint128 amountOut) = callback.callback(REACTIVE_SENDER, orderId);

        assertFalse(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.SLIPPAGE_TOO_HIGH));
        assertEq(amountOut, 0);
    }

    function _setOrder(bytes32 orderId, bytes32 poolId, bool zeroForOne, OrderStatus status, uint128 amountInRemaining)
        internal
    {
        OrderState memory order;
        order.orderId = orderId;
        order.owner = address(0xCAFE);
        order.poolId = poolId;
        order.tokenIn = address(0x1001);
        order.tokenOut = address(0x1002);
        order.zeroForOne = zeroForOne;
        order.amountInTotal = 5e18;
        order.amountInRemaining = amountInRemaining;
        order.mode = ExecutionMode.BBE;
        order.startTime = uint40(block.timestamp - 1);
        order.endTime = uint40(block.timestamp + 1 days);
        order.minIntervalSeconds = 0;
        order.blocksPerSlice = 1;
        order.maxSliceAmount = 1e18;
        order.minSliceAmount = 1e18;
        order.maxImpactBps = 500;
        order.minAmountOutPerSlice = 1;
        order.status = status;

        mockVault.setOrder(orderId, order);
    }
}
