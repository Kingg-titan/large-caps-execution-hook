// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractPausableReactive} from "reactive-lib/abstract-base/AbstractPausableReactive.sol";

import {ReasonCode} from "src/types/LargeCapTypes.sol";

/**
 * @title LargeCapReactiveScheduler
 * @notice Reactive Network scheduler that listens to large-cap hook events and emits callback jobs.
 * @custom:security-contact security@largecap-hook.example
 */
contract LargeCapReactiveScheduler is IReactive, AbstractPausableReactive {
    error LargeCapReactiveScheduler__InvalidAddress();
    error LargeCapReactiveScheduler__InvalidGasLimit();

    bytes32 public constant ORDER_CREATED_SIG = keccak256("OrderCreated(bytes32,address,bytes32,uint8)");
    bytes32 public constant ORDER_CANCELLED_SIG = keccak256("OrderCancelled(bytes32,address)");
    bytes32 public constant ORDER_COMPLETED_SIG = keccak256("OrderCompleted(bytes32,uint128,uint128,uint160)");
    bytes32 public constant SLICE_EXECUTED_SIG = keccak256("SliceExecuted(bytes32,uint64,uint128,uint128,uint256)");
    bytes32 public constant SLICE_BLOCKED_SIG = keccak256("SliceBlocked(bytes32,uint64,uint8)");

    uint64 public constant DEFAULT_CALLBACK_GAS_LIMIT = 750_000;

    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable hookContract;

    address public callbackContract;
    uint64 public callbackGasLimit;

    mapping(bytes32 orderId => bool isActive) public activeOrders;
    mapping(bytes32 orderId => uint256 blockNumber) public lastTriggeredOriginBlock;

    event ReactiveOrderActivated(bytes32 indexed orderId);
    event ReactiveOrderDeactivated(bytes32 indexed orderId);
    event ReactiveCallbackQueued(bytes32 indexed orderId, uint64 callbackGasLimit);
    event ReactiveCallbackIgnored(bytes32 indexed orderId, uint256 indexed originBlockNumber, uint8 reasonCode);
    event ReactiveCallbackContractUpdated(address indexed oldCallbackContract, address indexed newCallbackContract);
    event ReactiveCallbackGasLimitUpdated(uint64 indexed oldGasLimit, uint64 indexed newGasLimit);
    event ReactiveSubscriptionFailed(uint256 indexed chainId, address indexed sourceContract, uint256 indexed topic0);

    constructor(
        address serviceAddress,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address hookContract_,
        address callbackContract_,
        uint64 callbackGasLimit_
    ) payable {
        if (serviceAddress == address(0) || hookContract_ == address(0) || callbackContract_ == address(0)) {
            revert LargeCapReactiveScheduler__InvalidAddress();
        }

        service = ISystemContract(payable(serviceAddress));
        addAuthorizedSender(serviceAddress);
        owner = msg.sender;
        paused = false;

        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        hookContract = hookContract_;
        callbackContract = callbackContract_;

        if (callbackGasLimit_ == 0) {
            callbackGasLimit_ = DEFAULT_CALLBACK_GAS_LIMIT;
        }
        callbackGasLimit = callbackGasLimit_;

        if (!vm) {
            Subscription[] memory subscriptions = getPausableSubscriptions();
            uint256 length = subscriptions.length;

            for (uint256 i = 0; i < length; ++i) {
                try service.subscribe(
                    subscriptions[i].chain_id,
                    subscriptions[i]._contract,
                    subscriptions[i].topic_0,
                    subscriptions[i].topic_1,
                    subscriptions[i].topic_2,
                    subscriptions[i].topic_3
                ) {} catch {
                    emit ReactiveSubscriptionFailed(
                        subscriptions[i].chain_id, subscriptions[i]._contract, subscriptions[i].topic_0
                    );
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setCallbackContract(address newCallbackContract) external rnOnly onlyOwner {
        if (newCallbackContract == address(0)) {
            revert LargeCapReactiveScheduler__InvalidAddress();
        }

        address oldCallbackContract = callbackContract;
        callbackContract = newCallbackContract;

        emit ReactiveCallbackContractUpdated(oldCallbackContract, newCallbackContract);
    }

    function setCallbackGasLimit(uint64 newGasLimit) external rnOnly onlyOwner {
        if (newGasLimit == 0) {
            revert LargeCapReactiveScheduler__InvalidGasLimit();
        }

        uint64 oldGasLimit = callbackGasLimit;
        callbackGasLimit = newGasLimit;

        emit ReactiveCallbackGasLimitUpdated(oldGasLimit, newGasLimit);
    }

    /*//////////////////////////////////////////////////////////////
                             REACTIVE LOGIC
    //////////////////////////////////////////////////////////////*/

    function getPausableSubscriptions() internal view override returns (Subscription[] memory subscriptions) {
        subscriptions = new Subscription[](5);

        subscriptions[0] = Subscription({
            chain_id: originChainId,
            _contract: hookContract,
            topic_0: uint256(ORDER_CREATED_SIG),
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subscriptions[1] = Subscription({
            chain_id: originChainId,
            _contract: hookContract,
            topic_0: uint256(SLICE_EXECUTED_SIG),
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subscriptions[2] = Subscription({
            chain_id: originChainId,
            _contract: hookContract,
            topic_0: uint256(SLICE_BLOCKED_SIG),
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subscriptions[3] = Subscription({
            chain_id: originChainId,
            _contract: hookContract,
            topic_0: uint256(ORDER_COMPLETED_SIG),
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        subscriptions[4] = Subscription({
            chain_id: originChainId,
            _contract: hookContract,
            topic_0: uint256(ORDER_CANCELLED_SIG),
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
    }

    function react(LogRecord calldata log) external vmOnly {
        bytes32 topic0 = bytes32(log.topic_0);

        if (log.chain_id != originChainId || address(uint160(log._contract)) != hookContract) {
            return;
        }

        if (topic0 == ORDER_CREATED_SIG) {
            _activateAndQueue(bytes32(log.topic_1), log.block_number);
            return;
        }

        if (topic0 == SLICE_EXECUTED_SIG) {
            bytes32 orderId = bytes32(log.topic_1);
            if (activeOrders[orderId]) {
                _emitCallback(orderId, log.block_number);
            }
            return;
        }

        if (topic0 == SLICE_BLOCKED_SIG) {
            _handleSliceBlocked(log);
            return;
        }

        if (topic0 == ORDER_COMPLETED_SIG || topic0 == ORDER_CANCELLED_SIG) {
            _deactivate(bytes32(log.topic_1));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _activateAndQueue(bytes32 orderId, uint256 originBlockNumber) internal {
        activeOrders[orderId] = true;
        emit ReactiveOrderActivated(orderId);
        _emitCallback(orderId, originBlockNumber);
    }

    function _deactivate(bytes32 orderId) internal {
        if (!activeOrders[orderId]) {
            return;
        }

        activeOrders[orderId] = false;
        emit ReactiveOrderDeactivated(orderId);
    }

    function _handleSliceBlocked(LogRecord calldata log) internal {
        bytes32 orderId = bytes32(log.topic_1);
        if (!activeOrders[orderId]) {
            return;
        }

        (, uint8 reasonCode) = abi.decode(log.data, (uint64, uint8));

        if (reasonCode != uint8(ReasonCode.COOLDOWN)) {
            _deactivate(orderId);
            emit ReactiveCallbackIgnored(orderId, log.block_number, reasonCode);
            return;
        }

        if (lastTriggeredOriginBlock[orderId] >= log.block_number) {
            emit ReactiveCallbackIgnored(orderId, log.block_number, reasonCode);
            return;
        }

        _emitCallback(orderId, log.block_number);
    }

    function _emitCallback(bytes32 orderId, uint256 originBlockNumber) internal {
        lastTriggeredOriginBlock[orderId] = originBlockNumber;

        // Reactive callback infra injects ReactVM ID into the first address argument.
        bytes memory payload = abi.encodeWithSignature("callback(address,bytes32)", address(0), orderId);

        emit Callback(destinationChainId, callbackContract, callbackGasLimit, payload);
        emit ReactiveCallbackQueued(orderId, callbackGasLimit);
    }
}
