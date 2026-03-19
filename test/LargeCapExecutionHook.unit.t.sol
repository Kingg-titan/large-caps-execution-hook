// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LargeCapExecutionHook} from "src/LargeCapExecutionHook.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {HookOrderData, ExecutionMode, ReasonCode} from "src/types/LargeCapTypes.sol";

contract HookVaultMock {
    ReasonCode internal s_reason;
    address internal s_executor;

    bytes32 public lastOrderId;
    uint64 public lastSliceIndex;
    uint128 public lastAmountIn;
    uint128 public lastAmountOut;
    uint256 public afterSwapCalls;

    function setReason(ReasonCode reason) external {
        s_reason = reason;
    }

    function setExecutor(address executorAddress) external {
        s_executor = executorAddress;
    }

    function executor() external view returns (address) {
        return s_executor;
    }

    function validateHookExecution(bytes32, uint64, uint128, bytes32, bool) external view returns (ReasonCode) {
        return s_reason;
    }

    function recordAfterSwap(bytes32 orderId, uint64 sliceIndex, uint128 amountIn, uint128 amountOut)
        external
        returns (bool, uint160)
    {
        lastOrderId = orderId;
        lastSliceIndex = sliceIndex;
        lastAmountIn = amountIn;
        lastAmountOut = amountOut;
        afterSwapCalls += 1;
        return (false, 0);
    }
}

contract LargeCapExecutionHookUnitTest is Test {
    HookVaultMock internal vaultMock;
    LargeCapExecutionHook internal hook;

    address internal poolManager = makeAddr("poolManager");
    address internal executor = makeAddr("executor");

    PoolKey internal key;

    function setUp() public {
        vaultMock = new HookVaultMock();
        vaultMock.setExecutor(executor);

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x9999 << 144));
        deployCodeTo(
            "LargeCapExecutionHook.sol:LargeCapExecutionHook",
            abi.encode(IPoolManager(poolManager), IOrderBookVault(address(vaultMock))),
            hookAddress
        );
        hook = LargeCapExecutionHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function testGetHookPermissionsAreBeforeAndAfterSwapOnly() external {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
    }

    function testNotifyFunctionsRestrictedToVault() external {
        vm.expectRevert(LargeCapExecutionHook.LargeCapExecutionHook__NotVault.selector);
        hook.notifyOrderCreated(bytes32(uint256(1)), makeAddr("owner"), bytes32(uint256(2)), ExecutionMode.BBE);

        vm.prank(address(vaultMock));
        hook.notifyOrderCreated(bytes32(uint256(1)), makeAddr("owner"), bytes32(uint256(2)), ExecutionMode.BBE);

        vm.prank(address(vaultMock));
        hook.notifyOrderCancelled(bytes32(uint256(1)), makeAddr("owner"));

        vm.prank(address(vaultMock));
        hook.notifyOrderCompleted(bytes32(uint256(1)), 10, 11, 12);
    }

    function testReportSliceBlockedReporterChecks() external {
        vm.expectRevert(LargeCapExecutionHook.LargeCapExecutionHook__InvalidReporter.selector);
        hook.reportSliceBlocked(bytes32(uint256(1)), 0, ReasonCode.NOT_STARTED);

        vm.prank(address(vaultMock));
        hook.reportSliceBlocked(bytes32(uint256(1)), 0, ReasonCode.NOT_STARTED);

        vm.prank(executor);
        hook.reportSliceBlocked(bytes32(uint256(1)), 1, ReasonCode.COOLDOWN);
    }

    function testBeforeSwapRevertsOnInvalidHookData() external {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(100), sqrtPriceLimitX96: 0});

        vm.expectRevert(LargeCapExecutionHook.LargeCapExecutionHook__InvalidHookData.selector);
        vm.prank(poolManager);
        hook.beforeSwap(executor, key, params, bytes("short"));
    }

    function testBeforeSwapRevertsWhenVaultReturnsBlockingReason() external {
        vaultMock.setReason(ReasonCode.IMPACT_TOO_HIGH);

        HookOrderData memory data = HookOrderData({
            orderId: bytes32(uint256(123)),
            sliceIndex: 4,
            amountIn: 1_000,
            minAmountOut: 1
        });
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1_000), sqrtPriceLimitX96: 0});

        vm.expectRevert(
            abi.encodeWithSelector(
                LargeCapExecutionHook.LargeCapExecutionHook__SliceBlocked.selector, ReasonCode.IMPACT_TOO_HIGH
            )
        );
        vm.prank(poolManager);
        hook.beforeSwap(executor, key, params, abi.encode(data));
    }

    function testBeforeSwapRevertsOnInvalidCallerWhenSenderIsNotExecutor() external {
        vaultMock.setReason(ReasonCode.NONE);

        HookOrderData memory data = HookOrderData({
            orderId: bytes32(uint256(123)),
            sliceIndex: 4,
            amountIn: 1_000,
            minAmountOut: 1
        });
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1_000), sqrtPriceLimitX96: 0});

        vm.expectRevert(
            abi.encodeWithSelector(
                LargeCapExecutionHook.LargeCapExecutionHook__SliceBlocked.selector, ReasonCode.INVALID_CALLER
            )
        );
        vm.prank(poolManager);
        hook.beforeSwap(makeAddr("notExecutor"), key, params, abi.encode(data));
    }

    function testBeforeSwapPassesWhenReasonIsNoneAndSenderIsExecutor() external {
        vaultMock.setReason(ReasonCode.NONE);

        HookOrderData memory data = HookOrderData({
            orderId: bytes32(uint256(123)),
            sliceIndex: 4,
            amountIn: 1_000,
            minAmountOut: 1
        });
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1_000), sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        (bytes4 selector,,) = hook.beforeSwap(executor, key, params, abi.encode(data));
        assertEq(selector, hook.beforeSwap.selector);
    }

    function testAfterSwapComputesAmountOutForBothDirections() external {
        HookOrderData memory dataOne = HookOrderData({
            orderId: bytes32(uint256(10)),
            sliceIndex: 1,
            amountIn: 500,
            minAmountOut: 1
        });

        SwapParams memory paramsOne = SwapParams({zeroForOne: true, amountSpecified: -int256(500), sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        (bytes4 selectorOne,) = hook.afterSwap(
            executor,
            key,
            paramsOne,
            toBalanceDelta(int128(-500), int128(250)),
            abi.encode(dataOne)
        );
        assertEq(selectorOne, hook.afterSwap.selector);
        assertEq(vaultMock.lastOrderId(), dataOne.orderId);
        assertEq(vaultMock.lastSliceIndex(), dataOne.sliceIndex);
        assertEq(vaultMock.lastAmountIn(), dataOne.amountIn);
        assertEq(vaultMock.lastAmountOut(), 250);

        HookOrderData memory dataTwo = HookOrderData({
            orderId: bytes32(uint256(11)),
            sliceIndex: 2,
            amountIn: 600,
            minAmountOut: 1
        });
        SwapParams memory paramsTwo = SwapParams({zeroForOne: false, amountSpecified: -int256(600), sqrtPriceLimitX96: 0});

        vm.prank(poolManager);
        hook.afterSwap(executor, key, paramsTwo, toBalanceDelta(int128(333), int128(-600)), abi.encode(dataTwo));
        assertEq(vaultMock.lastOrderId(), dataTwo.orderId);
        assertEq(vaultMock.lastAmountOut(), 333);

        HookOrderData memory dataThree = HookOrderData({
            orderId: bytes32(uint256(12)),
            sliceIndex: 3,
            amountIn: 700,
            minAmountOut: 1
        });
        vm.prank(poolManager);
        hook.afterSwap(executor, key, paramsTwo, toBalanceDelta(int128(-1), int128(-2)), abi.encode(dataThree));
        assertEq(vaultMock.lastOrderId(), dataThree.orderId);
        assertEq(vaultMock.lastAmountOut(), 0);
        assertEq(vaultMock.afterSwapCalls(), 3);
    }
}
