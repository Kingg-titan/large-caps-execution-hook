// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {
    CreateOrderParams,
    ExecutionMode,
    OrderStatus,
    ReasonCode,
    OrderState,
    SlicePreview
} from "src/types/LargeCapTypes.sol";

contract OrderBookVaultTest is Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    OrderBookVault internal vault;

    address internal owner = address(this);
    address internal user = makeAddr("user");
    address internal executor = makeAddr("executor");
    address internal hook = makeAddr("hook");
    address internal keeper = makeAddr("keeper");

    bytes32 internal constant POOL_ID = keccak256("ETH/USDC");

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH", 18);
        tokenOut = new MockERC20("USDC", "USDC", 6);

        vault = new OrderBookVault(owner);
        vault.setExecutor(executor);
        vault.setHook(hook);

        tokenIn.mint(user, 10_000e18);
    }

    function testCreateOrderStoresStateAndTransfersFunds() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);

        bytes32 orderId = vault.createOrder(_defaultParams());
        vm.stopPrank();

        OrderState memory order = vault.getOrder(orderId);

        assertEq(order.orderId, orderId);
        assertEq(order.owner, user);
        assertEq(order.amountInTotal, 1_000e18);
        assertEq(order.amountInRemaining, 1_000e18);
        assertEq(uint256(uint8(order.status)), uint256(uint8(OrderStatus.ACTIVE)));
        assertEq(tokenIn.balanceOf(address(vault)), 1_000e18);
    }

    function testCancelMidExecutionAndWithdraw() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);
        bytes32 orderId = vault.createOrder(_defaultParams());
        vault.cancelOrder(orderId);
        uint128 refunded = vault.withdrawRemainingInput(orderId, user);
        vm.stopPrank();

        assertEq(refunded, 1_000e18);

        OrderState memory order = vault.getOrder(orderId);
        assertEq(uint256(uint8(order.status)), uint256(uint8(OrderStatus.CANCELLED)));
        assertEq(order.amountInRemaining, 0);
    }

    function testReserveFailsBeforeStart() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);

        CreateOrderParams memory params = _defaultParams();
        params.startTime = uint40(block.timestamp + 1 days);
        params.endTime = uint40(block.timestamp + 2 days);

        bytes32 orderId = vault.createOrder(params);
        vm.stopPrank();

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 10, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NOT_STARTED));
    }

    function testReserveThenRecord() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);
        bytes32 orderId = vault.createOrder(_defaultParams());
        vm.stopPrank();

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 20, keeper);

        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));
        assertEq(preview.amountIn, 250e18);
        assertEq(tokenIn.balanceOf(executor), 250e18);

        tokenOut.mint(address(vault), 125_000_000);

        vm.prank(hook);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 125_000_000);

        OrderState memory order = vault.getOrder(orderId);
        assertEq(order.amountInRemaining, 750e18);
        assertEq(order.amountOutTotal, 125_000_000);
        assertEq(order.nextSliceIndex, 1);
    }

    function testUnauthorizedReserveAttemptReverts() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);
        bytes32 orderId = vault.createOrder(_defaultParams());
        vm.stopPrank();

        vm.expectRevert(OrderBookVault.OrderBookVault__NotExecutor.selector);
        vm.prank(keeper);
        vault.reserveNextSlice(orderId, POOL_ID, 10, keeper);
    }

    function testExpiryMidExecution() external {
        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);

        CreateOrderParams memory params = _defaultParams();
        params.endTime = uint40(block.timestamp + 5);

        bytes32 orderId = vault.createOrder(params);
        vm.stopPrank();

        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 20, keeper);
        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.NONE));

        tokenOut.mint(address(vault), 1);
        vm.prank(hook);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, 1);

        vm.warp(block.timestamp + 10);

        vm.prank(executor);
        SlicePreview memory afterExpiry = vault.reserveNextSlice(orderId, POOL_ID, 20, keeper);
        assertEq(uint8(afterExpiry.reasonCode), uint8(ReasonCode.EXPIRED));

        vm.prank(user);
        uint128 remaining = vault.withdrawRemainingInput(orderId, user);
        assertGt(remaining, 0);
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
        params.maxSliceAmount = 250e18;
        params.minSliceAmount = 50e18;
        params.maxImpactBps = 100;
        params.minAmountOutPerSlice = 1;
        params.allowedExecutor = keeper;
    }
}
