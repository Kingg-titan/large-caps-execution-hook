// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {
    CreateOrderParams,
    ExecutionMode,
    OrderState,
    OrderStatus,
    SlicePreview,
    ReasonCode
} from "src/types/LargeCapTypes.sol";

contract HookEventsNoop is ILargeCapExecutionHookEvents {
    function notifyOrderCreated(bytes32, address, bytes32, ExecutionMode) external {}

    function notifyOrderCancelled(bytes32, address) external {}

    function notifyOrderCompleted(bytes32, uint128, uint128, uint160) external {}

    function reportSliceBlocked(bytes32, uint64, ReasonCode) external {}
}

contract HookEventsReverting is ILargeCapExecutionHookEvents {
    function notifyOrderCreated(bytes32, address, bytes32, ExecutionMode) external pure {
        revert("revert-created");
    }

    function notifyOrderCancelled(bytes32, address) external pure {
        revert("revert-cancelled");
    }

    function notifyOrderCompleted(bytes32, uint128, uint128, uint160) external pure {
        revert("revert-completed");
    }

    function reportSliceBlocked(bytes32, uint64, ReasonCode) external pure {
        revert("revert-blocked");
    }
}

contract OrderBookVaultBranchTest is Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    OrderBookVault internal vault;

    address internal user = makeAddr("user");
    address internal executor = makeAddr("executor");
    address internal hookEOA = makeAddr("hookEOA");
    address internal keeper = makeAddr("keeper");
    address internal otherKeeper = makeAddr("otherKeeper");

    bytes32 internal constant POOL_ID = keccak256("POOL-ID");

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH", 18);
        tokenOut = new MockERC20("USDC", "USDC", 6);

        vault = new OrderBookVault(address(this));
        vault.setExecutor(executor);
        vault.setHook(hookEOA);

        tokenIn.mint(user, 10_000e18);
        vm.prank(user);
        tokenIn.approve(address(vault), type(uint256).max);
    }

    function testCreateOrderValidationReverts() external {
        CreateOrderParams memory params = _defaultParams();

        params.tokenIn = address(0);
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAddress.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.tokenOut = params.tokenIn;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidTokenPair.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.amountInTotal = 0;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.maxSliceAmount = 1;
        params.minSliceAmount = 2;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.startTime = uint40(block.timestamp + 100);
        params.endTime = uint40(block.timestamp + 100);
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidSchedule.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.endTime = uint40(block.timestamp);
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidSchedule.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.maxImpactBps = 0;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.maxImpactBps = 10_001;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.blocksPerSlice = 0;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidCadence.selector);
        vm.prank(user);
        vault.createOrder(params);

        params = _defaultParams();
        params.mode = ExecutionMode.SOF;
        params.blocksPerSlice = 0;
        params.minIntervalSeconds = 0;
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidCadence.selector);
        vm.prank(user);
        vault.createOrder(params);
    }

    function testCreateOrderIncrementsNonceAndCurrentNonceView() external {
        vm.startPrank(user);
        bytes32 first = vault.createOrder(_defaultParams());
        bytes32 second = vault.createOrder(_defaultParams());
        vm.stopPrank();

        assertTrue(first != second);
        assertEq(vault.currentNonce(user), 2);
    }

    function testCancelOrderRevertsAcrossInvalidStates() external {
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(user);
        vault.cancelOrder(bytes32(uint256(1)));

        bytes32 orderId = _createDefaultOrder();

        vm.expectRevert(OrderBookVault.OrderBookVault__NotOrderOwner.selector);
        vm.prank(makeAddr("attacker"));
        vault.cancelOrder(orderId);

        vm.prank(user);
        vault.cancelOrder(orderId);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(user);
        vault.cancelOrder(orderId);
    }

    function testCancelOrderRevertsWhenPendingSliceExists() external {
        bytes32 orderId = _createDefaultOrder();

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 10, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));

        vm.expectRevert(OrderBookVault.OrderBookVault__PendingSliceExists.selector);
        vm.prank(user);
        vault.cancelOrder(orderId);
    }

    function testClaimOutputRevertsAndClaimsAllWhenAmountIsZero() external {
        bytes32 orderId = _createDefaultOrder();

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(user);
        vault.claimOutput(bytes32(uint256(9)), 1, user);

        vm.expectRevert(OrderBookVault.OrderBookVault__NotOrderOwner.selector);
        vm.prank(makeAddr("attacker"));
        vault.claimOutput(orderId, 1, user);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAddress.selector);
        vm.prank(user);
        vault.claimOutput(orderId, 1, address(0));

        vm.expectRevert(OrderBookVault.OrderBookVault__InsufficientClaimableOutput.selector);
        vm.prank(user);
        vault.claimOutput(orderId, 1, user);

        _seedOneExecutedSlice(orderId, 100e18, 100_000_000);

        vm.expectRevert(OrderBookVault.OrderBookVault__InsufficientClaimableOutput.selector);
        vm.prank(user);
        vault.claimOutput(orderId, 200_000_000, user);

        uint256 balanceBefore = tokenOut.balanceOf(user);
        vm.prank(user);
        uint128 claimed = vault.claimOutput(orderId, 0, user);
        uint256 balanceAfter = tokenOut.balanceOf(user);

        assertEq(claimed, 100_000_000);
        assertEq(balanceAfter - balanceBefore, 100_000_000);
    }

    function testWithdrawRemainingInputBranches() external {
        bytes32 orderId = _createDefaultOrder();

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(user);
        vault.withdrawRemainingInput(bytes32(uint256(7)), user);

        vm.expectRevert(OrderBookVault.OrderBookVault__NotOrderOwner.selector);
        vm.prank(makeAddr("attacker"));
        vault.withdrawRemainingInput(orderId, user);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAddress.selector);
        vm.prank(user);
        vault.withdrawRemainingInput(orderId, address(0));

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));

        vm.prank(executor);
        tokenIn.transfer(address(vault), preview.amountIn);

        vm.expectRevert(OrderBookVault.OrderBookVault__PendingSliceExists.selector);
        vm.prank(user);
        vault.withdrawRemainingInput(orderId, user);

        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(user);
        vault.withdrawRemainingInput(orderId, user);

        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        uint128 refunded = vault.withdrawRemainingInput(orderId, user);
        assertEq(refunded, 1_000e18);

        OrderState memory order = vault.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.EXPIRED));
        assertEq(order.amountInRemaining, 0);

        vm.expectRevert(OrderBookVault.OrderBookVault__InsufficientRemainingInput.selector);
        vm.prank(user);
        vault.withdrawRemainingInput(orderId, user);
    }

    function testReserveNextSliceEmitsSkipAndExpiresOrder() external {
        CreateOrderParams memory params = _defaultParams();
        params.endTime = uint40(block.timestamp + 1);

        vm.prank(user);
        bytes32 orderId = vault.createOrder(params);

        vm.warp(block.timestamp + 2);

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);

        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.EXPIRED));
        OrderState memory order = vault.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.EXPIRED));
        assertEq(order.epoch, 1);
    }

    function testReserveAndClearPendingSliceAndGetters() external {
        bytes32 orderId = _createDefaultOrder();

        SlicePreview memory previewView = vault.previewNextSlice(orderId, POOL_ID, 5, keeper);
        assertEq(uint8(previewView.reasonCode), uint8(ReasonCode.NONE));

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 5, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));

        assertEq(tokenIn.balanceOf(executor), preview.amountIn);

        vm.expectRevert(OrderBookVault.OrderBookVault__SliceMismatch.selector);
        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex + 1);

        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex);

        vm.expectRevert(OrderBookVault.OrderBookVault__PendingSliceMissing.selector);
        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex);

        vault.getPendingSlice(orderId);
    }

    function testValidateHookExecutionReasonsAndSuccess() external {
        bytes32 orderId = _createDefaultOrder();

        // wrong caller
        ReasonCode reason = vault.validateHookExecution(orderId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(bytes32(uint256(3)), 0, 1, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(orderId, 0, 100e18, bytes32(uint256(111)), true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(orderId, 0, 100e18, POOL_ID, false);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(user);
        vault.cancelOrder(orderId);

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(orderId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.ALREADY_COMPLETED));

        CreateOrderParams memory params = _defaultParams();
        params.startTime = uint40(block.timestamp + 1 days);
        params.endTime = uint40(block.timestamp + 2 days);
        vm.prank(user);
        bytes32 notStartedId = vault.createOrder(params);

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(notStartedId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.NOT_STARTED));

        params = _defaultParams();
        params.endTime = uint40(block.timestamp + 1);
        vm.prank(user);
        bytes32 expiringId = vault.createOrder(params);
        vm.warp(block.timestamp + 2);
        vm.prank(hookEOA);
        reason = vault.validateHookExecution(expiringId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.EXPIRED));

        vm.prank(executor);
        vault.reserveNextSlice(expiringId, POOL_ID, 1, keeper);
        vm.prank(hookEOA);
        reason = vault.validateHookExecution(expiringId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.EXPIRED));

        bytes32 pendingId = _createDefaultOrder();
        vm.prank(hookEOA);
        reason = vault.validateHookExecution(pendingId, 0, 100e18, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(pendingId, POOL_ID, 10, keeper);

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(pendingId, preview.sliceIndex + 1, preview.amountIn, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(pendingId, preview.sliceIndex, preview.amountIn + 1, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.INVALID_CALLER));

        vm.prank(hookEOA);
        reason = vault.validateHookExecution(pendingId, preview.sliceIndex, preview.amountIn, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.NONE));

        vm.prank(executor);
        vault.clearPendingSlice(pendingId, preview.sliceIndex);

        vm.prank(executor);
        preview = vault.reserveNextSlice(pendingId, POOL_ID, 10, keeper);
        _setPendingObservedImpact(pendingId, 9_999);
        vm.prank(hookEOA);
        reason = vault.validateHookExecution(pendingId, preview.sliceIndex, preview.amountIn, POOL_ID, true);
        assertEq(uint8(reason), uint8(ReasonCode.IMPACT_TOO_HIGH));
    }

    function testRecordAfterSwapOnlyHookAndFailureBranches() external {
        bytes32 orderId = _createDefaultOrder();

        vm.expectRevert(OrderBookVault.OrderBookVault__NotHook.selector);
        vault.recordAfterSwap(orderId, 0, 1, 1);

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);

        vm.expectRevert(OrderBookVault.OrderBookVault__SliceMismatch.selector);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex + 1, preview.amountIn, 1);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 0);

        _setOrderAmountRemaining(orderId, preview.amountIn - 1);
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAmount.selector);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 1);

        vm.expectRevert(OrderBookVault.OrderBookVault__SliceMismatch.selector);
        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex + 2);

        vm.prank(executor);
        vault.clearPendingSlice(orderId, preview.sliceIndex);

        vm.expectRevert(OrderBookVault.OrderBookVault__PendingSliceMissing.selector);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 1);

        vm.prank(user);
        vault.cancelOrder(orderId);

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidStatus.selector);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 1);
    }

    function testRecordAfterSwapCompletesOrderAndNotifies() external {
        HookEventsNoop noop = new HookEventsNoop();
        vault.setHook(address(noop));

        CreateOrderParams memory params = _defaultParams();
        params.amountInTotal = 200e18;
        params.maxSliceAmount = 200e18;
        params.minSliceAmount = 200e18;

        vm.prank(user);
        bytes32 orderId = vault.createOrder(params);

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 10, keeper);

        tokenOut.mint(address(vault), 210_000_000);

        vm.prank(address(noop));
        (bool completed, uint160 avgPriceX96) =
            vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 210_000_000);

        assertTrue(completed);
        assertGt(avgPriceX96, 0);

        OrderState memory order = vault.getOrder(orderId);
        assertEq(uint8(order.status), uint8(OrderStatus.COMPLETED));
        assertEq(order.amountInRemaining, 0);
        assertEq(order.epoch, 1);
    }

    function testSetHookSetExecutorValidationAndNotifyCatchBranches() external {
        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAddress.selector);
        vault.setHook(address(0));

        vm.expectRevert(OrderBookVault.OrderBookVault__InvalidAddress.selector);
        vault.setExecutor(address(0));

        HookEventsReverting revertingHook = new HookEventsReverting();
        vault.setHook(address(revertingHook));

        bytes32 orderId = _createDefaultOrder();

        vm.prank(user);
        vault.cancelOrder(orderId);

        // Complete-order notify catch branch
        CreateOrderParams memory params = _defaultParams();
        params.amountInTotal = 50e18;
        params.maxSliceAmount = 50e18;
        params.minSliceAmount = 50e18;
        vm.prank(user);
        bytes32 completedId = vault.createOrder(params);

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(completedId, POOL_ID, 10, keeper);
        tokenOut.mint(address(vault), 1);
        vm.prank(address(revertingHook));
        vault.recordAfterSwap(completedId, preview.sliceIndex, preview.amountIn, 1);
    }

    function testPreviewNextSliceAllReasonCodesIncludingDefensiveBranches() external {
        // invalid order
        SlicePreview memory preview = vault.previewNextSlice(bytes32(uint256(42)), POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.INVALID_CALLER));

        bytes32 orderId = _createDefaultOrder();

        // pool mismatch
        preview = vault.previewNextSlice(orderId, bytes32(uint256(9)), 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.INVALID_CALLER));

        // allowed executor mismatch
        preview = vault.previewNextSlice(orderId, POOL_ID, 1, otherKeeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.INVALID_CALLER));

        // impact too high
        preview = vault.previewNextSlice(orderId, POOL_ID, 500, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.IMPACT_TOO_HIGH));

        // BBE cooldown
        vm.prank(executor);
        preview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);
        tokenOut.mint(address(vault), 1);
        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 1);

        preview = vault.previewNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.COOLDOWN));

        vm.roll(block.number + 1);
        preview = vault.previewNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));

        // pending exists branch
        vm.prank(executor);
        SlicePreview memory pendingPreview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);
        preview = vault.previewNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.COOLDOWN));
        vm.prank(executor);
        vault.clearPendingSlice(orderId, pendingPreview.sliceIndex);

        // cancelled branch
        vm.prank(user);
        vault.cancelOrder(orderId);
        preview = vault.previewNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.INVALID_CALLER));

        // completed branch
        CreateOrderParams memory params = _defaultParams();
        params.amountInTotal = 10e18;
        params.maxSliceAmount = 10e18;
        params.minSliceAmount = 10e18;
        vm.prank(user);
        bytes32 completedId = vault.createOrder(params);
        vm.prank(executor);
        SlicePreview memory completedSlice = vault.reserveNextSlice(completedId, POOL_ID, 1, keeper);
        tokenOut.mint(address(vault), 1);
        vm.prank(hookEOA);
        vault.recordAfterSwap(completedId, completedSlice.sliceIndex, completedSlice.amountIn, 1);
        preview = vault.previewNextSlice(completedId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.ALREADY_COMPLETED));

        // expired status branch
        params = _defaultParams();
        params.endTime = uint40(block.timestamp + 1);
        vm.prank(user);
        bytes32 expiredId = vault.createOrder(params);
        vm.warp(block.timestamp + 2);
        vm.prank(executor);
        vault.reserveNextSlice(expiredId, POOL_ID, 1, keeper);
        preview = vault.previewNextSlice(expiredId, POOL_ID, 1, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.EXPIRED));

        // SOF cooldown branch
        params = _defaultParams();
        params.mode = ExecutionMode.SOF;
        params.blocksPerSlice = 0;
        params.minIntervalSeconds = 120;
        params.allowedExecutor = address(0);
        vm.prank(user);
        bytes32 sofId = vault.createOrder(params);
        vm.prank(executor);
        SlicePreview memory sofSlice = vault.reserveNextSlice(sofId, POOL_ID, 1, makeAddr("caller"));
        tokenOut.mint(address(vault), 1);
        vm.prank(hookEOA);
        vault.recordAfterSwap(sofId, sofSlice.sliceIndex, sofSlice.amountIn, 1);
        preview = vault.previewNextSlice(sofId, POOL_ID, 1, makeAddr("caller"));
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.COOLDOWN));

        // Defensive branch: force ACTIVE + zero remaining
        params = _defaultParams();
        params.allowedExecutor = address(0);
        vm.prank(user);
        bytes32 zeroRemainingId = vault.createOrder(params);
        _setOrderAmountRemaining(zeroRemainingId, 0);
        preview = vault.previewNextSlice(zeroRemainingId, POOL_ID, 1, makeAddr("openKeeper"));
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.ALREADY_COMPLETED));

        // Defensive branch: force invalid min/max for NO_LIQUIDITY path
        vm.prank(user);
        bytes32 noLiquidityId = vault.createOrder(params);
        _setOrderSliceBounds(noLiquidityId, 1, 2);
        preview = vault.previewNextSlice(noLiquidityId, POOL_ID, 1, makeAddr("openKeeper2"));
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NO_LIQUIDITY));
    }

    function _createDefaultOrder() internal returns (bytes32 orderId) {
        vm.prank(user);
        orderId = vault.createOrder(_defaultParams());
    }

    function _seedOneExecutedSlice(bytes32 orderId, uint128 expectedIn, uint128 amountOut) internal {
        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 1, keeper);
        assertEq(preview.amountIn, expectedIn);

        tokenOut.mint(address(vault), amountOut);

        vm.prank(hookEOA);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, amountOut);
    }

    function _setOrderAmountRemaining(bytes32 orderId, uint128 newRemaining) internal {
        bytes32 base = keccak256(abi.encode(orderId, uint256(3)));
        bytes32 slot = bytes32(uint256(base) + 5);
        uint256 current = uint256(vm.load(address(vault), slot));

        uint256 low = current & ((uint256(1) << 128) - 1);
        uint256 updated = low | (uint256(newRemaining) << 128);
        vm.store(address(vault), slot, bytes32(updated));
    }

    function _setOrderSliceBounds(bytes32 orderId, uint128 maxSlice, uint128 minSlice) internal {
        bytes32 base = keccak256(abi.encode(orderId, uint256(3)));
        bytes32 slot = bytes32(uint256(base) + 8);
        uint256 packed = uint256(maxSlice) | (uint256(minSlice) << 128);
        vm.store(address(vault), slot, bytes32(packed));
    }

    function _setPendingObservedImpact(bytes32 orderId, uint24 observedImpactBps) internal {
        bytes32 base = keccak256(abi.encode(orderId, uint256(4)));
        bytes32 slot = bytes32(uint256(base) + 1);
        uint256 current = uint256(vm.load(address(vault), slot));
        uint256 clearMask = ~(uint256(0xFFFFFF) << 64);
        uint256 updated = (current & clearMask) | (uint256(observedImpactBps) << 64);
        vm.store(address(vault), slot, bytes32(updated));
    }

    function _defaultParams() internal view returns (CreateOrderParams memory params) {
        params.poolId = POOL_ID;
        params.tokenIn = address(tokenIn);
        params.tokenOut = address(tokenOut);
        params.zeroForOne = true;
        params.amountInTotal = 1_000e18;
        params.mode = ExecutionMode.BBE;
        params.startTime = uint40(block.timestamp);
        params.endTime = uint40(block.timestamp + 7 days);
        params.minIntervalSeconds = 0;
        params.blocksPerSlice = 1;
        params.maxSliceAmount = 100e18;
        params.minSliceAmount = 10e18;
        params.maxImpactBps = 100;
        params.minAmountOutPerSlice = 1;
        params.allowedExecutor = keeper;
    }
}
