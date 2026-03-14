// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OrderBookVault} from "src/OrderBookVault.sol";
import {
    CreateOrderParams,
    ExecutionMode,
    OrderState,
    OrderStatus,
    SlicePreview,
    ReasonCode
} from "src/types/LargeCapTypes.sol";

contract VaultHandler {
    OrderBookVault public immutable vault;
    MockERC20 public immutable tokenOut;
    bytes32 public immutable orderId;
    bytes32 public immutable poolId;

    uint64 public executions;

    constructor(OrderBookVault vault_, MockERC20 tokenOut_, bytes32 orderId_, bytes32 poolId_) {
        vault = vault_;
        tokenOut = tokenOut_;
        orderId = orderId_;
        poolId = poolId_;
    }

    function execute(uint24 impactBps) external {
        SlicePreview memory preview = vault.reserveNextSlice(orderId, poolId, impactBps % 2_000, address(this));
        if (preview.reasonCode != ReasonCode.NONE) {
            return;
        }

        tokenOut.mint(address(vault), preview.amountIn);
        vault.recordAfterSwap(orderId, preview.sliceIndex, preview.amountIn, preview.amountIn);
        executions += 1;
    }
}

contract OrderBookVaultInvariantTest is StdInvariant, Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    OrderBookVault internal vault;
    VaultHandler internal handler;

    bytes32 internal orderId;
    bytes32 internal constant POOL_ID = keccak256("ETH/USDC-INVARIANT");

    bool internal seenCompleted;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH", 18);
        tokenOut = new MockERC20("USDC", "USDC", 6);

        vault = new OrderBookVault(address(this));

        tokenIn.mint(address(this), 10_000e18);
        tokenIn.approve(address(vault), type(uint256).max);

        orderId = vault.createOrder(
            CreateOrderParams({
                poolId: POOL_ID,
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                zeroForOne: true,
                amountInTotal: 1_000e18,
                mode: ExecutionMode.BBE,
                startTime: uint40(block.timestamp),
                endTime: uint40(block.timestamp + 365 days),
                minIntervalSeconds: 0,
                blocksPerSlice: 1,
                maxSliceAmount: 100e18,
                minSliceAmount: 1e18,
                maxImpactBps: 1_000,
                minAmountOutPerSlice: 1,
                allowedExecutor: address(0)
            })
        );

        handler = new VaultHandler(vault, tokenOut, orderId, POOL_ID);
        vault.setExecutor(address(handler));
        vault.setHook(address(handler));

        targetContract(address(handler));
    }

    function invariant_RemainingAndExecutedAreBounded() external {
        OrderState memory order = vault.getOrder(orderId);
        uint128 executed = order.amountInTotal - order.amountInRemaining;

        assertLe(executed, order.amountInTotal, "executed > total");
        assertLe(order.amountInRemaining, order.amountInTotal, "remaining > total");
    }

    function invariant_SliceIndexTracksExecutions() external {
        OrderState memory order = vault.getOrder(orderId);
        assertEq(order.nextSliceIndex, handler.executions(), "slice index diverged from execution count");
    }

    function invariant_CompletedOrderNeverReactivates() external {
        OrderState memory order = vault.getOrder(orderId);
        if (order.status == OrderStatus.COMPLETED) {
            seenCompleted = true;
        }

        if (seenCompleted) {
            assertTrue(order.status != OrderStatus.ACTIVE, "completed order moved back to active");
        }
    }
}
