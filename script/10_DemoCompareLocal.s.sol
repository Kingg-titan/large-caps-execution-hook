// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {Executor} from "src/Executor.sol";
import {CreateOrderParams, ExecutionMode, OrderState, ReasonCode} from "src/types/LargeCapTypes.sol";
import {LargeCapScriptBase} from "script/base/LargeCapScriptBase.s.sol";

contract DemoCompareLocalScript is LargeCapScriptBase {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    function run() external {
        if (block.chainid != 31337) {
            revert("DemoCompareLocalScript: run this on local anvil");
        }

        _bootstrapArtifacts();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        (OrderBookVault vault, LargeCapExecutionHook hook, Executor executor) = _deploySystem(deployer);
        (,, Currency currency0, Currency currency1) = _deployMockPair();

        PoolKey memory baselinePoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        PoolKey memory segmentedPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        _initializePoolAndSeedLiquidity(baselinePoolKey);
        _initializePoolAndSeedLiquidity(segmentedPoolKey);

        uint128 totalIn = 50e18;
        uint128 maxSlice = 10e18;

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);

        uint128 baselineOut =
            _runBaselineSwap(IUniswapV4Router04(payable(address(swapRouter))), baselinePoolKey, totalIn, deployer);
        OrderState memory segmentedOrder =
            _runSegmentedExecution(vault, executor, segmentedPoolKey, currency0, currency1, totalIn, maxSlice);

        uint128 segmentedOut = segmentedOrder.amountOutTotal;
        uint256 improvementBps;
        if (segmentedOut > baselineOut && baselineOut > 0) {
            improvementBps = ((uint256(segmentedOut) - uint256(baselineOut)) * 10_000) / uint256(baselineOut);
        }

        console2.log("--- LargeCap Execution Demo Summary ---");
        console2.log("baseline poolId");
        console2.logBytes32(PoolId.unwrap(baselinePoolKey.toId()));
        console2.log("segmented poolId");
        console2.logBytes32(PoolId.unwrap(segmentedPoolKey.toId()));
        console2.log("total in", totalIn);
        console2.log("baseline out", baselineOut);
        console2.log("segmented out", segmentedOut);
        console2.log("slices", segmentedOrder.nextSliceIndex);
        console2.log("avg segmented px x96", (uint256(segmentedOut) << 96) / uint256(totalIn));
        console2.log("improvement bps", improvementBps);

        vm.stopBroadcast();
    }

    function _runBaselineSwap(
        IUniswapV4Router04 router,
        PoolKey memory baselinePoolKey,
        uint128 totalIn,
        address receiver
    ) internal returns (uint128 baselineOut) {
        BalanceDelta baselineDelta = router.swapExactTokensForTokens(
            totalIn, 1, true, baselinePoolKey, bytes(""), receiver, block.timestamp + 10 minutes
        );
        baselineOut = uint128(uint128(baselineDelta.amount1()));
    }

    function _runSegmentedExecution(
        OrderBookVault vault,
        Executor executor,
        PoolKey memory segmentedPoolKey,
        Currency currency0,
        Currency currency1,
        uint128 totalIn,
        uint128 maxSlice
    ) internal returns (OrderState memory segmentedOrder) {
        bytes32 orderId = vault.createOrder(
            CreateOrderParams({
                poolId: PoolId.unwrap(segmentedPoolKey.toId()),
                tokenIn: Currency.unwrap(currency0),
                tokenOut: Currency.unwrap(currency1),
                zeroForOne: true,
                amountInTotal: totalIn,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 2 hours),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: maxSlice,
                minSliceAmount: maxSlice,
                maxImpactBps: 500,
                minAmountOutPerSlice: 1,
                allowedExecutor: address(0)
            })
        );

        for (uint256 i = 0; i < 5; ++i) {
            vm.roll(block.number + 1);

            (bool executed, ReasonCode reasonCode,) = executor.executeNextSlice(
                Executor.ExecuteParams({
                    orderId: orderId,
                    poolKey: segmentedPoolKey,
                    observedImpactBps: 50,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    deadline: uint40(block.timestamp + 10 minutes)
                })
            );

            require(executed, "segmented execution failed");
            require(reasonCode == ReasonCode.NONE, "non-zero reason code");
        }

        segmentedOrder = vault.getOrder(orderId);
    }
}
