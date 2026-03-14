// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {Executor} from "src/Executor.sol";
import {LargeCapScriptBase} from "script/base/LargeCapScriptBase.s.sol";

contract DeployLargeCapSystemScript is LargeCapScriptBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        _bootstrapArtifacts();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        (OrderBookVault vault, LargeCapExecutionHook hook, Executor executor) = _deploySystem(deployer);

        if (block.chainid == 31337) {
            (,, Currency currency0, Currency currency1) = _deployMockPair();
            PoolKey memory hookPoolKey =
                PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

            _initializePoolAndSeedLiquidity(hookPoolKey);
            console2.log("local hook poolId");
            console2.logBytes32(PoolId.unwrap(hookPoolKey.toId()));
        }

        vm.stopBroadcast();

        vault;
        executor;
    }
}
