// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {BaseTest} from "test/utils/BaseTest.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {Executor} from "src/Executor.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {CreateOrderParams, ExecutionMode, OrderState, OrderStatus, ReasonCode} from "src/types/LargeCapTypes.sol";

contract LargeCapExecutionHookIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    OrderBookVault internal vault;
    LargeCapExecutionHook internal hook;
    Executor internal executor;

    function setUp() public {
        deployArtifactsAndLabel();

        vault = new OrderBookVault(address(this));

        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x7777 << 144));
        deployCodeTo("LargeCapExecutionHook.sol:LargeCapExecutionHook", abi.encode(poolManager, vault), flags);
        hook = LargeCapExecutionHook(flags);

        executor = new Executor(address(this), IOrderBookVault(vault), poolManager, ILargeCapExecutionHookEvents(hook));

        vault.setHook(address(hook));
        vault.setExecutor(address(executor));

        (currency0, currency1) = deployCurrencyPair();

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 1_000e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
    }

    function testLifecycle_BlockBasedExecutionCompletes() external {
        bytes32 orderId = vault.createOrder(
            CreateOrderParams({
                poolId: PoolId.unwrap(poolId),
                tokenIn: Currency.unwrap(currency0),
                tokenOut: Currency.unwrap(currency1),
                zeroForOne: true,
                amountInTotal: 5e18,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 1 days),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: 1e18,
                minSliceAmount: 1e18,
                maxImpactBps: 500,
                minAmountOutPerSlice: 1,
                allowedExecutor: address(0)
            })
        );

        _executeOneSlice(orderId);
        OrderState memory afterFirst = vault.getOrder(orderId);
        assertEq(afterFirst.amountInRemaining, 4e18);
        assertEq(afterFirst.nextSliceIndex, 1);

        for (uint256 i = 0; i < 4; ++i) {
            _executeOneSlice(orderId);
        }

        OrderState memory finished = vault.getOrder(orderId);
        assertEq(uint8(finished.status), uint8(OrderStatus.COMPLETED));
        assertEq(finished.amountInRemaining, 0);
        assertGt(finished.amountOutTotal, 0);

        uint256 outputBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        vault.claimOutput(orderId, finished.amountOutTotal, address(this));
        uint256 outputAfter = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        assertEq(outputAfter - outputBefore, finished.amountOutTotal);
    }

    function testAllowedExecutorEnforcedThroughExecutorCaller() external {
        address keeper = makeAddr("keeper");
        address attacker = makeAddr("attacker");

        bytes32 orderId = vault.createOrder(
            CreateOrderParams({
                poolId: PoolId.unwrap(poolId),
                tokenIn: Currency.unwrap(currency0),
                tokenOut: Currency.unwrap(currency1),
                zeroForOne: true,
                amountInTotal: 2e18,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 1 days),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: 1e18,
                minSliceAmount: 1e18,
                maxImpactBps: 500,
                minAmountOutPerSlice: 1,
                allowedExecutor: keeper
            })
        );

        vm.prank(attacker);
        (bool executed, ReasonCode reasonCode,) = executor.executeNextSlice(
            Executor.ExecuteParams({
                orderId: orderId,
                poolKey: poolKey,
                observedImpactBps: 25,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                deadline: uint40(block.timestamp + 1 minutes)
            })
        );

        assertFalse(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.INVALID_CALLER));
    }

    function _executeOneSlice(bytes32 orderId) internal {
        vm.roll(block.number + 1);

        (bool executed, ReasonCode reasonCode,) = executor.executeNextSlice(
            Executor.ExecuteParams({
                orderId: orderId,
                poolKey: poolKey,
                observedImpactBps: 25,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                deadline: uint40(block.timestamp + 1 minutes)
            })
        );

        assertTrue(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.NONE));
    }
}
