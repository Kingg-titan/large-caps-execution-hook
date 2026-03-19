// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {Executor} from "src/Executor.sol";
import {CreateOrderParams, ExecutionMode, OrderState, ReasonCode} from "src/types/LargeCapTypes.sol";
import {LargeCapReactiveCallback} from "src/reactive/LargeCapReactiveCallback.sol";
import {LargeCapScriptBase} from "script/base/LargeCapScriptBase.s.sol";

contract DemoCompareUnichainScript is LargeCapScriptBase {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant DEFAULT_MAX_EXECUTION_ATTEMPTS = 40;
    uint256 internal constant DEFAULT_WAIT_BETWEEN_ATTEMPTS_MS = 3500;

    struct DemoConfig {
        uint128 totalIn;
        uint128 maxSlice;
        uint256 maxExecutionAttempts;
        uint256 waitBetweenAttemptsMs;
        ExecutionMode mode;
        uint32 blocksPerSlice;
        uint32 minIntervalSeconds;
    }

    function run() external {
        _bootstrapArtifacts();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        (OrderBookVault vault, LargeCapExecutionHook hook, Executor executor) = _loadOrDeploySystem(deployer);

        console2.log("PHASE 1/6 - Deploy mock large-cap pair");
        (,, Currency currency0, Currency currency1) = _deployMockPairFor(deployer);

        PoolKey memory baselinePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolKey memory segmentedPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        console2.log("PHASE 2/6 - Initialize pools and seed liquidity");
        _initializePoolAndSeedLiquidityFor(baselinePoolKey, deployer);
        _initializePoolAndSeedLiquidityFor(segmentedPoolKey, deployer);

        _configureReactiveCallbackIfSet(segmentedPoolKey);

        DemoConfig memory cfg = _loadDemoConfig();

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);

        console2.log("PHASE 3/6 - User baseline execution (single-shot swap)");
        uint128 baselineOut = _runBaselineSwap(
            IUniswapV4Router04(payable(address(swapRouter))), baselinePoolKey, cfg.totalIn, deployer
        );

        console2.log("PHASE 4/6 - User creates segmented order");
        bytes32 orderId = _createSegmentedOrder(vault, segmentedPoolKey, currency0, currency1, cfg);

        console2.log("orderId");
        console2.logBytes32(orderId);

        console2.log("PHASE 5/6 - Keeper/executor processes slices");
        (uint256 attempts, uint256 executedSlices) =
            _executeSlices(executor, vault, segmentedPoolKey, orderId, cfg.maxExecutionAttempts, cfg.waitBetweenAttemptsMs);

        console2.log("attempts", attempts);
        console2.log("executedSlices", executedSlices);

        console2.log("PHASE 6/6 - Final accounting and execution quality comparison");
        OrderState memory segmentedOrder = vault.getOrder(orderId);

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
        console2.log("total in", cfg.totalIn);
        console2.log("baseline out", baselineOut);
        console2.log("segmented out", segmentedOut);
        console2.log("slices", segmentedOrder.nextSliceIndex);
        console2.log("avg segmented px x96", (uint256(segmentedOut) << 96) / uint256(cfg.totalIn));
        console2.log("improvement bps", improvementBps);

        vm.stopBroadcast();
    }

    function _loadOrDeploySystem(address owner)
        internal
        returns (OrderBookVault vault, LargeCapExecutionHook hook, Executor executor)
    {
        address vaultAddress = vm.envOr("LARGE_CAP_VAULT_ADDRESS", address(0));
        address hookAddress = vm.envOr("LARGE_CAP_HOOK_ADDRESS", address(0));
        address executorAddress = vm.envOr("LARGE_CAP_EXECUTOR_ADDRESS", address(0));

        if (vaultAddress != address(0) && hookAddress != address(0) && executorAddress != address(0)) {
            vault = OrderBookVault(vaultAddress);
            hook = LargeCapExecutionHook(hookAddress);
            executor = Executor(payable(executorAddress));
            console2.log("Using existing deployed system");
            console2.log("vault", vaultAddress);
            console2.log("hook", hookAddress);
            console2.log("executor", executorAddress);
            return (vault, hook, executor);
        }

        console2.log("LARGE_CAP_* env vars missing; deploying a fresh system");
        return _deploySystem(owner);
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

    function _loadDemoConfig() internal view returns (DemoConfig memory cfg) {
        cfg.totalIn = uint128(vm.envOr("DEMO_TOTAL_IN", uint256(50e18)));
        cfg.maxSlice = uint128(vm.envOr("DEMO_SLICE_SIZE", uint256(10e18)));
        cfg.maxExecutionAttempts = vm.envOr("DEMO_MAX_EXECUTION_ATTEMPTS", DEFAULT_MAX_EXECUTION_ATTEMPTS);
        cfg.waitBetweenAttemptsMs = vm.envOr("DEMO_WAIT_BETWEEN_ATTEMPTS_MS", DEFAULT_WAIT_BETWEEN_ATTEMPTS_MS);

        uint256 executionModeRaw = vm.envOr("DEMO_MODE", uint256(0)); // 0=BBE, 1=SOF
        cfg.mode = executionModeRaw == 1 ? ExecutionMode.SOF : ExecutionMode.BBE;
        cfg.blocksPerSlice = cfg.mode == ExecutionMode.BBE ? uint32(vm.envOr("DEMO_BLOCKS_PER_SLICE", uint256(1))) : 0;
        cfg.minIntervalSeconds =
            cfg.mode == ExecutionMode.SOF ? uint32(vm.envOr("DEMO_MIN_INTERVAL_SECONDS", uint256(5))) : 0;
    }

    function _createSegmentedOrder(
        OrderBookVault vault,
        PoolKey memory segmentedPoolKey,
        Currency currency0,
        Currency currency1,
        DemoConfig memory cfg
    ) internal returns (bytes32 orderId) {
        orderId = vault.createOrder(
            CreateOrderParams({
                poolId: PoolId.unwrap(segmentedPoolKey.toId()),
                tokenIn: Currency.unwrap(currency0),
                tokenOut: Currency.unwrap(currency1),
                zeroForOne: true,
                amountInTotal: cfg.totalIn,
                mode: cfg.mode,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 2 hours),
                minIntervalSeconds: cfg.minIntervalSeconds,
                blocksPerSlice: cfg.blocksPerSlice,
                maxSliceAmount: cfg.maxSlice,
                minSliceAmount: cfg.maxSlice,
                maxImpactBps: 500,
                minAmountOutPerSlice: 1,
                allowedExecutor: address(0)
            })
        );
    }

    function _configureReactiveCallbackIfSet(PoolKey memory segmentedPoolKey) internal {
        address callbackAddress = vm.envOr("LARGE_CAP_REACTIVE_CALLBACK_ADDRESS", address(0));
        if (callbackAddress == address(0)) {
            return;
        }

        LargeCapReactiveCallback callbackContract = LargeCapReactiveCallback(payable(callbackAddress));
        try callbackContract.registerPoolKey(segmentedPoolKey) {} catch {
            console2.log("reactive callback pool registration skipped (owner mismatch or preconfigured)");
        }

        bool enforceSender = vm.envOr("DEMO_REACTIVE_ENFORCE_SENDER", false);
        address schedulerAddress = vm.envOr("LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS", address(0));
        address expectedSender = vm.envOr("LARGE_CAP_REACTIVE_EXPECTED_SENDER", address(0));
        if (expectedSender == address(0)) {
            expectedSender = schedulerAddress;
        }

        if (enforceSender && expectedSender != address(0)) {
            try callbackContract.setExpectedReactiveSender(expectedSender) {} catch {
                console2.log("reactive sender enforcement skipped (owner mismatch)");
            }
        }

        console2.log("reactive callback configured", callbackAddress);
        if (expectedSender != address(0)) {
            console2.log("reactive expected sender", expectedSender);
        }
        if (schedulerAddress != address(0)) {
            console2.log("reactive scheduler", schedulerAddress);
        }
    }

    function _executeSlices(
        Executor executor,
        OrderBookVault vault,
        PoolKey memory segmentedPoolKey,
        bytes32 orderId,
        uint256 maxExecutionAttempts,
        uint256 waitBetweenAttemptsMs
    ) internal returns (uint256 attempts, uint256 executedSlices) {
        while (attempts < maxExecutionAttempts) {
            attempts += 1;

            (bool executed, ReasonCode reasonCode,) = executor.executeNextSlice(
                Executor.ExecuteParams({
                    orderId: orderId,
                    poolKey: segmentedPoolKey,
                    observedImpactBps: 50,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    deadline: uint40(block.timestamp + 10 minutes)
                })
            );

            if (executed) {
                executedSlices += 1;
            } else {
                if (reasonCode != ReasonCode.COOLDOWN) {
                    console2.log("slice blocked with reasonCode", uint256(uint8(reasonCode)));
                    break;
                }
                if (waitBetweenAttemptsMs > 0) {
                    vm.sleep(waitBetweenAttemptsMs);
                }
                continue;
            }

            OrderState memory currentOrder = vault.getOrder(orderId);
            if (currentOrder.amountInRemaining == 0) {
                break;
            }

            if (waitBetweenAttemptsMs > 0) {
                vm.sleep(waitBetweenAttemptsMs);
            }
        }
    }

    function _deployMockPairFor(address holder)
        internal
        returns (MockERC20 token0, MockERC20 token1, Currency currency0, Currency currency1)
    {
        token0 = new MockERC20("Mock WETH", "mWETH", 18);
        token1 = new MockERC20("Mock USDC", "mUSDC", 6);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Oversized mint so liquidity seeding cannot fail due token decimal mismatch.
        token0.mint(holder, 10_000_000e24);
        token1.mint(holder, 10_000_000e24);

        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);

        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _initializePoolAndSeedLiquidityFor(PoolKey memory key, address recipient) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 1_000_000e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            recipient,
            Constants.ZERO_BYTES
        );

        positionManager.initializePool(key, Constants.SQRT_PRICE_1_1);
        positionManager.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 10 minutes);

        console2.log("seeded liquidity for pool");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        params = new bytes[](4);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, recipient);
        params[3] = abi.encode(poolKey.currency1, recipient);
    }
}
