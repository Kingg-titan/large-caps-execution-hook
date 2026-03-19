// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LargeCapReactiveScheduler} from "src/reactive/LargeCapReactiveScheduler.sol";

contract DeployReactiveSchedulerScript is Script {
    uint64 internal constant DEFAULT_CALLBACK_GAS_LIMIT = 750_000;
    uint256 internal constant DEFAULT_FUNDING_WEI = 0.1 ether;

    function run() external returns (LargeCapReactiveScheduler scheduler) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address serviceAddress = vm.envAddress("SYSTEM_CONTRACT_ADDR");
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        uint256 destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address hookAddress = vm.envAddress("LARGE_CAP_HOOK_ADDRESS");
        address callbackAddress = vm.envAddress("LARGE_CAP_REACTIVE_CALLBACK_ADDRESS");
        uint256 callbackGasLimitRaw = vm.envOr("REACTIVE_CALLBACK_GAS_LIMIT", uint256(DEFAULT_CALLBACK_GAS_LIMIT));
        uint256 fundingWei = vm.envOr("REACTIVE_SCHEDULER_FUNDING_WEI", uint256(DEFAULT_FUNDING_WEI));

        require(callbackGasLimitRaw <= type(uint64).max, "gas limit overflow");
        uint64 callbackGasLimit = uint64(callbackGasLimitRaw);

        vm.startBroadcast(deployerKey);
        scheduler = new LargeCapReactiveScheduler{value: fundingWei}(
            serviceAddress, originChainId, destinationChainId, hookAddress, callbackAddress, callbackGasLimit
        );
        vm.stopBroadcast();

        console2.log("reactive scheduler", address(scheduler));
        console2.log("service", serviceAddress);
        console2.log("origin chain id", originChainId);
        console2.log("destination chain id", destinationChainId);
        console2.log("hook", hookAddress);
        console2.log("callback", callbackAddress);
        console2.log("callback gas limit", callbackGasLimit);
    }
}
