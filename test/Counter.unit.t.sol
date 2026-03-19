// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Counter} from "src/Counter.sol";

contract CounterHarness is Counter {
    constructor(IPoolManager poolManager_) Counter(poolManager_) {}

    function exposedBeforeSwap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BalanceDelta, uint24)
    {
        (bytes4 selector,, uint24 feeOverride) = _beforeSwap(address(this), key, params, hookData);
        return (selector, toBalanceDelta(int128(0), int128(0)), feeOverride);
    }

    function exposedAfterSwap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        return _afterSwap(address(this), key, params, toBalanceDelta(int128(0), int128(0)), hookData);
    }

    function exposedBeforeAddLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (bytes4)
    {
        return _beforeAddLiquidity(address(this), key, params, hookData);
    }

    function exposedBeforeRemoveLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4)
    {
        return _beforeRemoveLiquidity(address(this), key, params, hookData);
    }
}

contract CounterUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    CounterHarness internal counter;
    PoolKey internal key;

    function setUp() public {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        address counterAddress = address(uint160(flags) ^ (0x4567 << 144));
        deployCodeTo(
            "Counter.unit.t.sol:CounterHarness", abi.encode(IPoolManager(makeAddr("poolManager"))), counterAddress
        );
        counter = CounterHarness(counterAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0x3000)),
            currency1: Currency.wrap(address(0x4000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(counter))
        });
    }

    function testHookPermissionsMatchCounterImplementation() external {
        Hooks.Permissions memory permissions = counter.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
    }

    function testCounterIncrementsAllConfiguredHooks() external {
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -int256(1), sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory liqParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});

        counter.exposedBeforeSwap(key, swapParams, hex"");
        counter.exposedAfterSwap(key, swapParams, hex"");
        counter.exposedBeforeAddLiquidity(key, liqParams, hex"");
        counter.exposedBeforeRemoveLiquidity(key, liqParams, hex"");

        PoolId poolId = key.toId();

        assertEq(counter.beforeSwapCount(poolId), 1);
        assertEq(counter.afterSwapCount(poolId), 1);
        assertEq(counter.beforeAddLiquidityCount(poolId), 1);
        assertEq(counter.beforeRemoveLiquidityCount(poolId), 1);
    }
}
