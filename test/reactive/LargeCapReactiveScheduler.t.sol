// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {LargeCapReactiveScheduler} from "src/reactive/LargeCapReactiveScheduler.sol";
import {ReasonCode} from "src/types/LargeCapTypes.sol";

contract MockSystemService {
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCount += 1;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCount += 1;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract MockRevertingSystemService {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external pure {
        revert("failure");
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external pure {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract LargeCapReactiveSchedulerVmTest is Test {
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    uint256 internal constant ORIGIN_CHAIN_ID = 1301;
    uint256 internal constant DESTINATION_CHAIN_ID = 1301;
    address internal constant HOOK_CONTRACT = address(0x1111111111111111111111111111111111111111);
    address internal constant CALLBACK_CONTRACT = address(0x2222222222222222222222222222222222222222);
    address internal constant SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    MockSystemService internal service;
    LargeCapReactiveScheduler internal scheduler;

    function setUp() external {
        // VM mode: system address has no code.
        vm.etch(SYSTEM_ADDR, bytes(""));

        service = new MockSystemService();
        scheduler = new LargeCapReactiveScheduler(
            address(service), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK_CONTRACT, CALLBACK_CONTRACT, 0
        );
    }

    function testConstructorDefaultsInVmMode() external view {
        assertEq(scheduler.callbackGasLimit(), scheduler.DEFAULT_CALLBACK_GAS_LIMIT());
        assertEq(scheduler.callbackContract(), CALLBACK_CONTRACT);
        assertEq(scheduler.hookContract(), HOOK_CONTRACT);
        assertEq(scheduler.originChainId(), ORIGIN_CHAIN_ID);
        assertEq(scheduler.destinationChainId(), DESTINATION_CHAIN_ID);
    }

    function testConstructorRevertsOnZeroAddresses() external {
        vm.expectRevert(LargeCapReactiveScheduler.LargeCapReactiveScheduler__InvalidAddress.selector);
        new LargeCapReactiveScheduler(address(0), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK_CONTRACT, CALLBACK_CONTRACT, 1);

        vm.expectRevert(LargeCapReactiveScheduler.LargeCapReactiveScheduler__InvalidAddress.selector);
        new LargeCapReactiveScheduler(address(service), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, address(0), CALLBACK_CONTRACT, 1);

        vm.expectRevert(LargeCapReactiveScheduler.LargeCapReactiveScheduler__InvalidAddress.selector);
        new LargeCapReactiveScheduler(address(service), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK_CONTRACT, address(0), 1);
    }

    function testReactIgnoresMismatchedChainAndContract() external {
        bytes32 orderId = keccak256("order-1");

        IReactive.LogRecord memory wrongChainLog = _buildLog(
            ORIGIN_CHAIN_ID + 1,
            HOOK_CONTRACT,
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            10
        );
        scheduler.react(wrongChainLog);
        assertFalse(scheduler.activeOrders(orderId));

        IReactive.LogRecord memory wrongContractLog = _buildLog(
            ORIGIN_CHAIN_ID,
            address(0x3333333333333333333333333333333333333333),
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            11
        );
        scheduler.react(wrongContractLog);
        assertFalse(scheduler.activeOrders(orderId));
    }

    function testReactOrderCreatedActivatesAndQueuesCallback() external {
        bytes32 orderId = keccak256("order-created");
        uint256 originBlock = 42;

        bytes memory payload = abi.encodeWithSignature("callback(address,bytes32)", address(0), orderId);

        vm.expectEmit(true, true, true, true, address(scheduler));
        emit Callback(DESTINATION_CHAIN_ID, CALLBACK_CONTRACT, scheduler.callbackGasLimit(), payload);

        IReactive.LogRecord memory orderCreatedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            originBlock
        );

        scheduler.react(orderCreatedLog);

        assertTrue(scheduler.activeOrders(orderId));
        assertEq(scheduler.lastTriggeredOriginBlock(orderId), originBlock);
    }

    function testReactSliceExecutedQueuesOnlyWhenOrderActive() external {
        bytes32 orderId = keccak256("order-active");

        IReactive.LogRecord memory orderCreatedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            100
        );
        scheduler.react(orderCreatedLog);

        IReactive.LogRecord memory sliceExecutedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_EXECUTED_SIG(),
            uint256(orderId),
            "",
            101
        );
        scheduler.react(sliceExecutedLog);

        assertEq(scheduler.lastTriggeredOriginBlock(orderId), 101);

        bytes32 inactiveOrderId = keccak256("order-inactive");
        IReactive.LogRecord memory inactiveSliceExecutedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_EXECUTED_SIG(),
            uint256(inactiveOrderId),
            "",
            102
        );
        scheduler.react(inactiveSliceExecutedLog);

        assertEq(scheduler.lastTriggeredOriginBlock(inactiveOrderId), 0);
    }

    function testReactSliceBlockedCooldownThrottleAndRetry() external {
        bytes32 orderId = keccak256("order-cooldown");

        IReactive.LogRecord memory orderCreatedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            200
        );
        scheduler.react(orderCreatedLog);

        IReactive.LogRecord memory cooldownBlockedSameBlock = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_BLOCKED_SIG(),
            uint256(orderId),
            abi.encode(uint64(1), uint8(ReasonCode.COOLDOWN)),
            200
        );
        scheduler.react(cooldownBlockedSameBlock);

        assertEq(scheduler.lastTriggeredOriginBlock(orderId), 200);

        IReactive.LogRecord memory cooldownBlockedNextBlock = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_BLOCKED_SIG(),
            uint256(orderId),
            abi.encode(uint64(2), uint8(ReasonCode.COOLDOWN)),
            201
        );
        scheduler.react(cooldownBlockedNextBlock);

        assertEq(scheduler.lastTriggeredOriginBlock(orderId), 201);
    }

    function testReactSliceBlockedNonCooldownDeactivatesOrder() external {
        bytes32 orderId = keccak256("order-blocked");

        IReactive.LogRecord memory orderCreatedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.ORDER_CREATED_SIG(),
            uint256(orderId),
            "",
            300
        );
        scheduler.react(orderCreatedLog);

        IReactive.LogRecord memory blockedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_BLOCKED_SIG(),
            uint256(orderId),
            abi.encode(uint64(1), uint8(ReasonCode.SLIPPAGE_TOO_HIGH)),
            301
        );
        scheduler.react(blockedLog);

        assertFalse(scheduler.activeOrders(orderId));
    }

    function testReactSliceBlockedIgnoredWhenOrderInactive() external {
        bytes32 inactiveOrderId = keccak256("inactive-order");

        IReactive.LogRecord memory blockedLog = _buildLog(
            ORIGIN_CHAIN_ID,
            HOOK_CONTRACT,
            scheduler.SLICE_BLOCKED_SIG(),
            uint256(inactiveOrderId),
            abi.encode(uint64(1), uint8(ReasonCode.COOLDOWN)),
            305
        );
        scheduler.react(blockedLog);

        assertFalse(scheduler.activeOrders(inactiveOrderId));
        assertEq(scheduler.lastTriggeredOriginBlock(inactiveOrderId), 0);
    }

    function testReactOrderCompletionAndCancellationDeactivateOrder() external {
        bytes32 completedOrderId = keccak256("order-completed");
        bytes32 cancelledOrderId = keccak256("order-cancelled");

        scheduler.react(_buildLog(ORIGIN_CHAIN_ID, HOOK_CONTRACT, scheduler.ORDER_CREATED_SIG(), uint256(completedOrderId), "", 401));
        scheduler.react(_buildLog(ORIGIN_CHAIN_ID, HOOK_CONTRACT, scheduler.ORDER_CREATED_SIG(), uint256(cancelledOrderId), "", 402));

        scheduler.react(_buildLog(ORIGIN_CHAIN_ID, HOOK_CONTRACT, scheduler.ORDER_COMPLETED_SIG(), uint256(completedOrderId), "", 403));
        scheduler.react(_buildLog(ORIGIN_CHAIN_ID, HOOK_CONTRACT, scheduler.ORDER_CANCELLED_SIG(), uint256(cancelledOrderId), "", 404));

        assertFalse(scheduler.activeOrders(completedOrderId));
        assertFalse(scheduler.activeOrders(cancelledOrderId));
    }

    function testReactOrderCompletionNoopsForInactiveOrder() external {
        bytes32 inactiveOrderId = keccak256("inactive-completed");

        scheduler.react(
            _buildLog(ORIGIN_CHAIN_ID, HOOK_CONTRACT, scheduler.ORDER_COMPLETED_SIG(), uint256(inactiveOrderId), "", 500)
        );

        assertFalse(scheduler.activeOrders(inactiveOrderId));
        assertEq(scheduler.lastTriggeredOriginBlock(inactiveOrderId), 0);
    }

    function testRnOnlyFunctionsRevertInVmMode() external {
        vm.expectRevert("Reactive Network only");
        scheduler.setCallbackContract(address(0x1234));

        vm.expectRevert("Reactive Network only");
        scheduler.setCallbackGasLimit(1);
    }

    function _buildLog(
        uint256 chainId,
        address source,
        bytes32 topic0,
        uint256 topic1,
        bytes memory data,
        uint256 originBlock
    ) internal pure returns (IReactive.LogRecord memory logRecord) {
        logRecord = IReactive.LogRecord({
            chain_id: chainId,
            _contract: source,
            topic_0: uint256(topic0),
            topic_1: topic1,
            topic_2: 0,
            topic_3: 0,
            data: data,
            block_number: originBlock,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }
}

contract LargeCapReactiveSchedulerRnModeTest is Test {
    uint256 internal constant ORIGIN_CHAIN_ID = 1301;
    uint256 internal constant DESTINATION_CHAIN_ID = 1301;
    address internal constant HOOK_CONTRACT = address(0x1111111111111111111111111111111111111111);
    address internal constant CALLBACK_CONTRACT = address(0x2222222222222222222222222222222222222222);
    address internal constant SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    MockSystemService internal service;
    MockRevertingSystemService internal revertingService;
    LargeCapReactiveScheduler internal scheduler;

    function setUp() external {
        // RN mode: system address has code.
        vm.etch(SYSTEM_ADDR, hex"01");

        service = new MockSystemService();
        revertingService = new MockRevertingSystemService();
        scheduler = new LargeCapReactiveScheduler(
            address(service), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK_CONTRACT, CALLBACK_CONTRACT, 123_456
        );
    }

    function testConstructorSubscribesInRnMode() external view {
        assertEq(service.subscribeCount(), 5);
    }

    function testRnOnlyOwnerSetters() external {
        scheduler.setCallbackContract(address(0xABCDEF));
        assertEq(scheduler.callbackContract(), address(0xABCDEF));

        scheduler.setCallbackGasLimit(999_999);
        assertEq(scheduler.callbackGasLimit(), 999_999);
    }

    function testOnlyOwnerAndValidationOnSetters() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert("Unauthorized");
        scheduler.setCallbackContract(address(0xCAFE));

        vm.expectRevert(LargeCapReactiveScheduler.LargeCapReactiveScheduler__InvalidAddress.selector);
        scheduler.setCallbackContract(address(0));

        vm.prank(address(0xBEEF));
        vm.expectRevert("Unauthorized");
        scheduler.setCallbackGasLimit(11);

        vm.expectRevert(LargeCapReactiveScheduler.LargeCapReactiveScheduler__InvalidGasLimit.selector);
        scheduler.setCallbackGasLimit(0);
    }

    function testReactRevertsInRnMode() external {
        IReactive.LogRecord memory emptyLog = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: HOOK_CONTRACT,
            topic_0: 0,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectRevert("VM only");
        scheduler.react(emptyLog);
    }

    function testConstructorSwallowsSubscriptionFailures() external {
        LargeCapReactiveScheduler fallbackScheduler = new LargeCapReactiveScheduler(
            address(revertingService), ORIGIN_CHAIN_ID, DESTINATION_CHAIN_ID, HOOK_CONTRACT, CALLBACK_CONTRACT, 123_456
        );

        assertEq(fallbackScheduler.callbackContract(), CALLBACK_CONTRACT);
        assertEq(fallbackScheduler.callbackGasLimit(), 123_456);
    }
}
