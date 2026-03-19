// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {ILargeCapExecutor, LargeCapReactiveCallback} from "src/reactive/LargeCapReactiveCallback.sol";

contract DeployReactiveCallbackScript is Script {
    uint256 internal constant DEFAULT_FUNDING_WEI = 0.02 ether;

    function run() external returns (LargeCapReactiveCallback callbackContract) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address callbackProxy = vm.envAddress("DESTINATION_CALLBACK_PROXY_ADDR");
        address vaultAddress = vm.envAddress("LARGE_CAP_VAULT_ADDRESS");
        address executorAddress = vm.envAddress("LARGE_CAP_EXECUTOR_ADDRESS");
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        uint256 fundingWei = vm.envOr("REACTIVE_CALLBACK_FUNDING_WEI", uint256(DEFAULT_FUNDING_WEI));

        vm.startBroadcast(deployerKey);
        callbackContract = new LargeCapReactiveCallback{value: fundingWei}(
            callbackProxy, IOrderBookVault(vaultAddress), ILargeCapExecutor(executorAddress), owner
        );
        vm.stopBroadcast();

        console2.log("reactive callback", address(callbackContract));
        console2.log("callback proxy", callbackProxy);
        console2.log("vault", vaultAddress);
        console2.log("executor", executorAddress);
        console2.log("owner", owner);
    }
}
