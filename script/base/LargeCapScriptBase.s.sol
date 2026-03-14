// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Deployers} from "test/utils/Deployers.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {OrderBookVault} from "src/OrderBookVault.sol";
import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {Executor} from "src/Executor.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";

abstract contract LargeCapScriptBase is Script, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid != 31337) {
            revert("LargeCapScriptBase: etch only supported on local anvil");
        }

        vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '","', vm.toString(bytecode), '"]'));
    }

    function _bootstrapArtifacts() internal {
        deployArtifacts();

        console2.log("poolManager", address(poolManager));
        console2.log("positionManager", address(positionManager));
        console2.log("swapRouter", address(swapRouter));
    }

    function _deploySystem(address owner)
        internal
        returns (OrderBookVault vault, LargeCapExecutionHook hook, Executor executor)
    {
        vault = new OrderBookVault(owner);

        bytes memory constructorArgs = abi.encode(poolManager, IOrderBookVault(vault));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, FLAGS, type(LargeCapExecutionHook).creationCode, constructorArgs);

        hook = new LargeCapExecutionHook{salt: salt}(poolManager, IOrderBookVault(vault));
        require(address(hook) == hookAddress, "LargeCapScriptBase: hook address mismatch");

        executor = new Executor(owner, IOrderBookVault(vault), poolManager, ILargeCapExecutionHookEvents(hook));

        vault.setHook(address(hook));
        vault.setExecutor(address(executor));

        console2.log("vault", address(vault));
        console2.log("hook", address(hook));
        console2.log("executor", address(executor));
    }

    function _deployMockPair()
        internal
        returns (MockERC20 token0, MockERC20 token1, Currency currency0, Currency currency1)
    {
        token0 = new MockERC20("Mock WETH", "mWETH", 18);
        token1 = new MockERC20("Mock USDC", "mUSDC", 6);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        token0.mint(address(this), 10_000_000e18);
        token1.mint(address(this), 10_000_000e6);

        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);

        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _initializePoolAndSeedLiquidity(PoolKey memory key) internal {
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 1_000_000e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        console2.log("seeded liquidity for pool");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
