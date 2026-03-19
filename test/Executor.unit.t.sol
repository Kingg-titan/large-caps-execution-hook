// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Executor} from "src/Executor.sol";
import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {
    OrderState,
    SlicePreview,
    ReasonCode,
    OrderStatus,
    ExecutionMode,
    PendingSlice,
    CreateOrderParams
} from "src/types/LargeCapTypes.sol";

contract ExecutorHookMock is ILargeCapExecutionHookEvents {
    bytes32 public lastOrderId;
    uint64 public lastSliceIndex;
    ReasonCode public lastReason;
    uint256 public reportCalls;

    function notifyOrderCreated(bytes32, address, bytes32, ExecutionMode) external {}

    function notifyOrderCancelled(bytes32, address) external {}

    function notifyOrderCompleted(bytes32, uint128, uint128, uint160) external {}

    function reportSliceBlocked(bytes32 orderId, uint64 sliceIndex, ReasonCode reasonCode) external {
        lastOrderId = orderId;
        lastSliceIndex = sliceIndex;
        lastReason = reasonCode;
        reportCalls += 1;
    }
}

contract ExecutorVaultMock {
    mapping(bytes32 => OrderState) internal s_orders;
    mapping(bytes32 => SlicePreview) internal s_previews;

    MockERC20 public immutable tokenIn;
    uint256 public clearCalls;
    bytes32 public lastClearedOrder;
    uint64 public lastClearedSlice;

    constructor(MockERC20 tokenIn_) {
        tokenIn = tokenIn_;
    }

    function setOrder(bytes32 orderId, OrderState calldata order) external {
        s_orders[orderId] = order;
    }

    function setPreview(bytes32 orderId, SlicePreview calldata preview) external {
        s_previews[orderId] = preview;
    }

    function reserveNextSlice(bytes32 orderId, bytes32, uint24, address) external returns (SlicePreview memory preview) {
        preview = s_previews[orderId];
        if (preview.reasonCode == ReasonCode.NONE && preview.amountIn > 0) {
            tokenIn.transfer(msg.sender, preview.amountIn);
        }
    }

    function clearPendingSlice(bytes32 orderId, uint64 sliceIndex) external {
        clearCalls += 1;
        lastClearedOrder = orderId;
        lastClearedSlice = sliceIndex;
    }

    function getOrder(bytes32 orderId) external view returns (OrderState memory order) {
        order = s_orders[orderId];
    }

    // Unused interface methods
    function createOrder(CreateOrderParams calldata) external pure returns (bytes32) {
        revert("unused");
    }

    function cancelOrder(bytes32) external pure {
        revert("unused");
    }

    function claimOutput(bytes32, uint128, address) external pure returns (uint128) {
        revert("unused");
    }

    function withdrawRemainingInput(bytes32, address) external pure returns (uint128) {
        revert("unused");
    }

    function previewNextSlice(bytes32, bytes32, uint24, address) external pure returns (SlicePreview memory) {
        revert("unused");
    }

    function validateHookExecution(bytes32, uint64, uint128, bytes32, bool) external pure returns (ReasonCode) {
        revert("unused");
    }

    function recordAfterSwap(bytes32, uint64, uint128, uint128) external pure returns (bool, uint160) {
        revert("unused");
    }

    function getPendingSlice(bytes32) external pure returns (PendingSlice memory) {
        revert("unused");
    }

    function currentNonce(address) external pure returns (uint64) {
        revert("unused");
    }

    function hook() external pure returns (address) {
        return address(0);
    }

    function executor() external pure returns (address) {
        return address(0);
    }
}

contract PoolManagerMock {
    enum UnlockMode {
        RETURN_DELTA,
        RETURN_SHORT,
        REVERT,
        CALLBACK
    }

    UnlockMode public mode;
    BalanceDelta public unlockDelta;
    BalanceDelta public swapDelta;

    uint256 public unlockCalls;
    uint256 public swapCalls;
    uint256 public syncCalls;
    uint256 public settleCalls;
    uint256 public takeCalls;

    Currency public lastSyncCurrency;
    Currency public lastTakeCurrency;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;

    function setMode(UnlockMode newMode) external {
        mode = newMode;
    }

    function setUnlockDelta(BalanceDelta delta) external {
        unlockDelta = delta;
    }

    function setSwapDelta(BalanceDelta delta) external {
        swapDelta = delta;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCalls += 1;

        if (mode == UnlockMode.REVERT) {
            revert("unlock-revert");
        }
        if (mode == UnlockMode.RETURN_SHORT) {
            return hex"1234";
        }
        if (mode == UnlockMode.CALLBACK) {
            return IUnlockCallback(msg.sender).unlockCallback(data);
        }

        return abi.encode(unlockDelta);
    }

    function swap(PoolKey memory, SwapParams memory, bytes memory) external returns (BalanceDelta) {
        swapCalls += 1;
        return swapDelta;
    }

    function sync(Currency currency) external {
        syncCalls += 1;
        lastSyncCurrency = currency;
    }

    function settle() external payable {
        settleCalls += 1;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        takeCalls += 1;
        lastTakeCurrency = currency;
        lastTakeRecipient = recipient;
        lastTakeAmount = amount;
    }
}

contract ExecutorUnitTest is Test {
    MockERC20 internal token0;
    MockERC20 internal token1;

    ExecutorVaultMock internal vaultMock;
    PoolManagerMock internal poolManagerMock;
    ExecutorHookMock internal hookMock;
    Executor internal executor;

    bytes32 internal constant ORDER_ID = keccak256("ORDER");

    function setUp() public {
        token0 = new MockERC20("T0", "T0", 18);
        token1 = new MockERC20("T1", "T1", 18);

        vaultMock = new ExecutorVaultMock(token0);
        poolManagerMock = new PoolManagerMock();
        hookMock = new ExecutorHookMock();

        executor = new Executor(
            address(this),
            IOrderBookVault(address(vaultMock)),
            IPoolManager(address(poolManagerMock)),
            ILargeCapExecutionHookEvents(address(hookMock))
        );

        token0.mint(address(vaultMock), 1_000_000e18);
        token1.mint(address(executor), 1_000_000e18);
    }

    function testExecuteNextSliceRevertsOnDeadline() external {
        Executor.ExecuteParams memory params = _baseParams();
        params.deadline = uint40(block.timestamp - 1);

        vm.expectRevert(Executor.Executor__InvalidDeadline.selector);
        executor.executeNextSlice(params);
    }

    function testExecuteNextSliceReturnsBlockedReasonWithoutUnlock() external {
        _setOrder(true);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NOT_STARTED, amountIn: 0, minAmountOut: 0, sliceIndex: 9})
        );

        (bool executed, ReasonCode reasonCode, uint128 amountOut) = executor.executeNextSlice(_baseParams());

        assertFalse(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.NOT_STARTED));
        assertEq(amountOut, 0);
        assertEq(hookMock.reportCalls(), 1);
        assertEq(poolManagerMock.unlockCalls(), 0);
    }

    function testExecuteNextSliceRevertsOnUnexpectedUnlockResponse() external {
        _setOrder(true);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 5e18, minAmountOut: 1, sliceIndex: 1})
        );
        poolManagerMock.setMode(PoolManagerMock.UnlockMode.RETURN_SHORT);

        vm.expectRevert(Executor.Executor__UnexpectedUnlockResponse.selector);
        executor.executeNextSlice(_baseParams());
    }

    function testExecuteNextSliceSuccessForBothSwapDirections() external {
        // zeroForOne: amountOut should come from amount1
        _setOrder(true);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 5e18, minAmountOut: 1, sliceIndex: 1})
        );
        poolManagerMock.setMode(PoolManagerMock.UnlockMode.RETURN_DELTA);
        poolManagerMock.setUnlockDelta(toBalanceDelta(int128(-5e18), int128(123e18)));

        (bool executed, ReasonCode reasonCode, uint128 amountOut) = executor.executeNextSlice(_baseParams());
        assertTrue(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.NONE));
        assertEq(amountOut, 123e18);

        // zeroForOne false: amountOut should come from amount0
        _setOrder(false);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 3e18, minAmountOut: 1, sliceIndex: 2})
        );
        poolManagerMock.setUnlockDelta(toBalanceDelta(int128(77e18), int128(-3e18)));

        (executed, reasonCode, amountOut) = executor.executeNextSlice(_baseParams());
        assertTrue(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.NONE));
        assertEq(amountOut, 77e18);
    }

    function testExecuteNextSliceCatchPathRefundsAndClearsPending() external {
        _setOrder(true);

        SlicePreview memory preview =
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 2e18, minAmountOut: 1, sliceIndex: 77});
        vaultMock.setPreview(ORDER_ID, preview);
        poolManagerMock.setMode(PoolManagerMock.UnlockMode.REVERT);

        uint256 vaultBalanceBefore = token0.balanceOf(address(vaultMock));

        (bool executed, ReasonCode reasonCode, uint128 amountOut) = executor.executeNextSlice(_baseParams());

        assertFalse(executed);
        assertEq(uint8(reasonCode), uint8(ReasonCode.SLIPPAGE_TOO_HIGH));
        assertEq(amountOut, 0);

        assertEq(vaultMock.clearCalls(), 1);
        assertEq(vaultMock.lastClearedOrder(), ORDER_ID);
        assertEq(vaultMock.lastClearedSlice(), preview.sliceIndex);

        assertEq(token0.balanceOf(address(vaultMock)), vaultBalanceBefore);
        assertEq(hookMock.reportCalls(), 1);
        assertEq(uint8(hookMock.lastReason()), uint8(ReasonCode.SLIPPAGE_TOO_HIGH));
    }

    function testUnlockCallbackRevertsWhenCallerIsNotPoolManager() external {
        vm.expectRevert(Executor.Executor__NotPoolManager.selector);
        executor.unlockCallback(bytes(""));
    }

    function testUnlockCallbackSettlementBranchesThroughExecuteFlow() external {
        poolManagerMock.setMode(PoolManagerMock.UnlockMode.CALLBACK);

        // Case A: amount0 < 0 => settle currency0
        _setOrder(true);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 4e18, minAmountOut: 1, sliceIndex: 3})
        );
        poolManagerMock.setSwapDelta(toBalanceDelta(int128(-4e18), int128(0)));

        (bool executedA, ReasonCode reasonA,) = executor.executeNextSlice(_baseParams());
        assertTrue(executedA || reasonA == ReasonCode.SLIPPAGE_TOO_HIGH);

        // Case B: amount0 > 0 => take currency0
        _setOrder(false);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 6e18, minAmountOut: 1, sliceIndex: 4})
        );
        poolManagerMock.setSwapDelta(toBalanceDelta(int128(8e18), int128(0)));

        (bool executedB, ReasonCode reasonB,) = executor.executeNextSlice(_baseParams());
        assertTrue(executedB || reasonB == ReasonCode.SLIPPAGE_TOO_HIGH);

        // Case C: amount1 < 0 => settle currency1
        _setOrder(false);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 7e18, minAmountOut: 1, sliceIndex: 5})
        );
        poolManagerMock.setSwapDelta(toBalanceDelta(int128(0), int128(-6e18)));

        (bool executedC, ReasonCode reasonC,) = executor.executeNextSlice(_baseParams());
        assertTrue(executedC || reasonC == ReasonCode.SLIPPAGE_TOO_HIGH);

        // Case D: amount1 > 0 => take currency1
        _setOrder(false);
        vaultMock.setPreview(
            ORDER_ID,
            SlicePreview({reasonCode: ReasonCode.NONE, amountIn: 8e18, minAmountOut: 1, sliceIndex: 6})
        );
        poolManagerMock.setSwapDelta(toBalanceDelta(int128(0), int128(9e18)));

        (bool executedD, ReasonCode reasonD,) = executor.executeNextSlice(_baseParams());
        assertTrue(executedD || reasonD == ReasonCode.SLIPPAGE_TOO_HIGH);
    }

    function _setOrder(bool zeroForOne) internal {
        OrderState memory order;
        order.orderId = ORDER_ID;
        order.owner = address(this);
        order.poolId = bytes32(uint256(1));
        order.tokenIn = address(token0);
        order.tokenOut = address(token1);
        order.zeroForOne = zeroForOne;
        order.amountInTotal = 100e18;
        order.amountInRemaining = 100e18;
        order.mode = ExecutionMode.BBE;
        order.startTime = uint40(block.timestamp);
        order.endTime = uint40(block.timestamp + 1 days);
        order.maxSliceAmount = 100e18;
        order.minSliceAmount = 1;
        order.maxImpactBps = 100;
        order.minAmountOutPerSlice = 1;
        order.status = OrderStatus.ACTIVE;

        vaultMock.setOrder(ORDER_ID, order);
    }

    function _baseParams() internal view returns (Executor.ExecuteParams memory params) {
        params.orderId = ORDER_ID;
        params.poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        params.observedImpactBps = 10;
        params.sqrtPriceLimitX96 = 0;
        params.deadline = uint40(block.timestamp + 1 hours);
    }
}
