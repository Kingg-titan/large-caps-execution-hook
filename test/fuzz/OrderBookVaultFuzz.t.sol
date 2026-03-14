// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {
    CreateOrderParams,
    ExecutionMode,
    OrderState,
    OrderStatus,
    SlicePreview,
    ReasonCode
} from "src/types/LargeCapTypes.sol";

contract OrderBookVaultFuzzTest is Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    OrderBookVault internal vault;

    address internal user = makeAddr("user");
    address internal executor = makeAddr("executor");
    address internal hook = makeAddr("hook");
    address internal keeper = makeAddr("keeper");

    bytes32 internal constant POOL_ID = keccak256("WBTC/ETH");

    function setUp() public {
        tokenIn = new MockERC20("WBTC", "WBTC", 8);
        tokenOut = new MockERC20("WETH", "WETH", 18);

        vault = new OrderBookVault(address(this));
        vault.setExecutor(executor);
        vault.setHook(hook);

        tokenIn.mint(user, type(uint128).max);
    }

    function testFuzz_ExecutedNeverExceedsOrderTotal(uint128 totalInput, uint128 maxSliceInput, uint8 maxIterations)
        external
    {
        uint128 total = uint128(bound(totalInput, 10_000, 1_000_000_000_000));
        uint128 maxSlice = uint128(bound(maxSliceInput, 1, total));
        uint128 minSlice = uint128(bound(maxSliceInput, 1, maxSlice));
        uint8 iterations = uint8(bound(maxIterations, 1, 32));

        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);
        bytes32 orderId = vault.createOrder(
            CreateOrderParams({
                poolId: POOL_ID,
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                zeroForOne: true,
                amountInTotal: total,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 30 days),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: maxSlice,
                minSliceAmount: minSlice,
                maxImpactBps: 1_000,
                minAmountOutPerSlice: 1,
                allowedExecutor: keeper
            })
        );
        vm.stopPrank();

        uint8 i;
        for (; i < iterations; ++i) {
            vm.roll(block.number + 1);

            vm.prank(executor);
            SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 100, keeper);
            if (preview.reasonCode != ReasonCode.NONE) {
                continue;
            }

            uint128 amountOut = preview.amountIn;
            tokenOut.mint(address(vault), amountOut);

            vm.prank(hook);
            vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, amountOut);
        }

        OrderState memory order = vault.getOrder(orderId);
        uint128 executed = order.amountInTotal - order.amountInRemaining;

        assertLe(executed, order.amountInTotal, "executed amount exceeded order total");
        assertLe(order.amountInRemaining, order.amountInTotal, "remaining amount exceeded order total");

        if (order.status == OrderStatus.COMPLETED) {
            assertEq(order.amountInRemaining, 0, "completed order still has remaining amount");
        }
    }

    function testFuzz_CancelPreventsFurtherExecution(uint128 amountInput) external {
        uint128 total = uint128(bound(amountInput, 100_000, 1_000_000_000_000));

        vm.startPrank(user);
        tokenIn.approve(address(vault), type(uint256).max);
        bytes32 orderId = vault.createOrder(
            CreateOrderParams({
                poolId: POOL_ID,
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                zeroForOne: true,
                amountInTotal: total,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 30 days),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: total,
                minSliceAmount: 1,
                maxImpactBps: 1_000,
                minAmountOutPerSlice: 1,
                allowedExecutor: keeper
            })
        );
        vault.cancelOrder(orderId);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(executor);
        SlicePreview memory preview = vault.reserveNextSlice(orderId, POOL_ID, 10, keeper);

        assertEq(uint8(preview.reasonCode), uint8(ReasonCode.INVALID_CALLER));
    }
}
