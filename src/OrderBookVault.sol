// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILargeCapExecutionHookEvents} from "src/interfaces/ILargeCapExecutionHookEvents.sol";
import {IOrderBookVault} from "src/interfaces/IOrderBookVault.sol";
import {
    CreateOrderParams,
    OrderState,
    PendingSlice,
    SlicePreview,
    ExecutionMode,
    OrderStatus,
    ReasonCode
} from "src/types/LargeCapTypes.sol";

/**
 * @title OrderBookVault
 * @notice Custodies segmented orders, enforces execution policy and accounts settled slice output.
 * @custom:security-contact security@largecap-hook.example
 */
contract OrderBookVault is IOrderBookVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OrderBookVault__InvalidAddress();
    error OrderBookVault__InvalidTokenPair();
    error OrderBookVault__InvalidAmount();
    error OrderBookVault__InvalidSchedule();
    error OrderBookVault__InvalidCadence();
    error OrderBookVault__InvalidStatus();
    error OrderBookVault__NotOrderOwner();
    error OrderBookVault__NotExecutor();
    error OrderBookVault__NotHook();
    error OrderBookVault__PendingSliceExists();
    error OrderBookVault__PendingSliceMissing();
    error OrderBookVault__SliceMismatch();
    error OrderBookVault__InsufficientClaimableOutput();
    error OrderBookVault__InsufficientRemainingInput();

    mapping(bytes32 orderId => OrderState order) private s_orders;
    mapping(bytes32 orderId => PendingSlice pending) private s_pending;
    mapping(address owner => uint64 nonce) private s_nonces;

    address public override hook;
    address public override executor;

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyExecutor() {
        if (msg.sender != executor) {
            revert OrderBookVault__NotExecutor();
        }
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) {
            revert OrderBookVault__NotHook();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        USER-FACING STATE CHANGES
    //////////////////////////////////////////////////////////////*/

    function createOrder(CreateOrderParams calldata params) external nonReentrant returns (bytes32 orderId) {
        _validateCreateOrder(params);

        uint64 nonce = s_nonces[msg.sender];
        s_nonces[msg.sender] = nonce + 1;

        orderId = keccak256(
            abi.encode(
                msg.sender,
                nonce,
                block.chainid,
                params.poolId,
                params.tokenIn,
                params.tokenOut,
                params.amountInTotal,
                params.mode,
                params.startTime,
                params.endTime,
                address(this)
            )
        );

        OrderState storage order = s_orders[orderId];
        order.orderId = orderId;
        order.owner = msg.sender;
        order.poolId = params.poolId;
        order.tokenIn = params.tokenIn;
        order.tokenOut = params.tokenOut;
        order.zeroForOne = params.zeroForOne;
        order.amountInTotal = params.amountInTotal;
        order.amountInRemaining = params.amountInTotal;
        order.mode = params.mode;
        order.startTime = params.startTime;
        order.endTime = params.endTime;
        order.minIntervalSeconds = params.minIntervalSeconds;
        order.blocksPerSlice = params.blocksPerSlice;
        order.maxSliceAmount = params.maxSliceAmount;
        order.minSliceAmount = params.minSliceAmount;
        order.maxImpactBps = params.maxImpactBps;
        order.minAmountOutPerSlice = params.minAmountOutPerSlice;
        order.status = OrderStatus.ACTIVE;
        order.nonce = nonce;
        order.epoch = 0;
        order.nextSliceIndex = 0;
        order.allowedExecutor = params.allowedExecutor;

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountInTotal);

        emit OrderCreated(orderId, msg.sender, params.poolId, params.mode);
        _notifyOrderCreated(orderId, msg.sender, params.poolId, params.mode);
    }

    function cancelOrder(bytes32 orderId) external nonReentrant {
        OrderState storage order = s_orders[orderId];

        if (order.orderId == bytes32(0)) {
            revert OrderBookVault__InvalidStatus();
        }
        if (order.owner != msg.sender) {
            revert OrderBookVault__NotOrderOwner();
        }
        if (order.status != OrderStatus.ACTIVE) {
            revert OrderBookVault__InvalidStatus();
        }
        if (s_pending[orderId].exists) {
            revert OrderBookVault__PendingSliceExists();
        }

        order.status = OrderStatus.CANCELLED;
        order.epoch += 1;

        emit OrderCancelled(orderId, msg.sender);
        _notifyOrderCancelled(orderId, msg.sender);
    }

    function claimOutput(bytes32 orderId, uint128 requestedAmount, address recipient)
        external
        nonReentrant
        returns (uint128 claimed)
    {
        OrderState storage order = s_orders[orderId];

        if (order.orderId == bytes32(0)) {
            revert OrderBookVault__InvalidStatus();
        }
        if (order.owner != msg.sender) {
            revert OrderBookVault__NotOrderOwner();
        }
        if (recipient == address(0)) {
            revert OrderBookVault__InvalidAddress();
        }

        uint128 available = order.amountOutTotal - order.amountOutClaimed;
        if (requestedAmount == 0) {
            requestedAmount = available;
        }
        if (requestedAmount == 0 || requestedAmount > available) {
            revert OrderBookVault__InsufficientClaimableOutput();
        }

        claimed = requestedAmount;
        order.amountOutClaimed += claimed;
        IERC20(order.tokenOut).safeTransfer(recipient, claimed);
    }

    function withdrawRemainingInput(bytes32 orderId, address recipient) external nonReentrant returns (uint128 amount) {
        OrderState storage order = s_orders[orderId];

        if (order.orderId == bytes32(0)) {
            revert OrderBookVault__InvalidStatus();
        }
        if (order.owner != msg.sender) {
            revert OrderBookVault__NotOrderOwner();
        }
        if (recipient == address(0)) {
            revert OrderBookVault__InvalidAddress();
        }
        if (s_pending[orderId].exists) {
            revert OrderBookVault__PendingSliceExists();
        }

        if (order.status == OrderStatus.ACTIVE) {
            if (block.timestamp <= order.endTime) {
                revert OrderBookVault__InvalidStatus();
            }
            order.status = OrderStatus.EXPIRED;
            order.epoch += 1;
        }

        amount = order.amountInRemaining;
        if (amount == 0) {
            revert OrderBookVault__InsufficientRemainingInput();
        }

        order.amountInRemaining = 0;
        IERC20(order.tokenIn).safeTransfer(recipient, amount);
    }

    function reserveNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)
        external
        onlyExecutor
        nonReentrant
        returns (SlicePreview memory preview)
    {
        preview = _previewNextSlice(orderId, poolId, observedImpactBps, keeper);

        OrderState storage order = s_orders[orderId];
        if (preview.reasonCode != ReasonCode.NONE) {
            if (preview.reasonCode == ReasonCode.EXPIRED && order.status == OrderStatus.ACTIVE) {
                order.status = OrderStatus.EXPIRED;
                order.epoch += 1;
            }
            emit SliceSkipped(orderId, order.nextSliceIndex, preview.reasonCode);
            return preview;
        }

        PendingSlice storage pending = s_pending[orderId];
        pending.amountIn = preview.amountIn;
        pending.minAmountOut = preview.minAmountOut;
        pending.sliceIndex = preview.sliceIndex;
        pending.observedImpactBps = observedImpactBps;
        pending.exists = true;

        IERC20(order.tokenIn).safeTransfer(msg.sender, preview.amountIn);
    }

    function clearPendingSlice(bytes32 orderId, uint64 sliceIndex) external onlyExecutor {
        PendingSlice storage pending = s_pending[orderId];

        if (!pending.exists) {
            revert OrderBookVault__PendingSliceMissing();
        }
        if (pending.sliceIndex != sliceIndex) {
            revert OrderBookVault__SliceMismatch();
        }

        delete s_pending[orderId];
    }

    /*//////////////////////////////////////////////////////////////
                         USER-FACING READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function previewNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)
        external
        view
        returns (SlicePreview memory preview)
    {
        preview = _previewNextSlice(orderId, poolId, observedImpactBps, keeper);
    }

    function getOrder(bytes32 orderId) external view returns (OrderState memory order) {
        order = s_orders[orderId];
    }

    function getPendingSlice(bytes32 orderId) external view returns (PendingSlice memory pending) {
        pending = s_pending[orderId];
    }

    function currentNonce(address ownerAddress) external view returns (uint64 nonce) {
        nonce = s_nonces[ownerAddress];
    }

    /*//////////////////////////////////////////////////////////////
                     HOOK-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function validateHookExecution(
        bytes32 orderId,
        uint64 sliceIndex,
        uint128 amountIn,
        bytes32 poolId,
        bool zeroForOne
    ) external view returns (ReasonCode reasonCode) {
        if (msg.sender != hook) {
            return ReasonCode.INVALID_CALLER;
        }

        OrderState storage order = s_orders[orderId];
        if (order.orderId == bytes32(0)) {
            return ReasonCode.INVALID_CALLER;
        }
        if (order.poolId != poolId || order.zeroForOne != zeroForOne) {
            return ReasonCode.INVALID_CALLER;
        }
        if (order.status != OrderStatus.ACTIVE) {
            if (order.status == OrderStatus.EXPIRED) {
                return ReasonCode.EXPIRED;
            }
            return ReasonCode.ALREADY_COMPLETED;
        }
        if (block.timestamp < order.startTime) {
            return ReasonCode.NOT_STARTED;
        }
        if (block.timestamp > order.endTime) {
            return ReasonCode.EXPIRED;
        }

        PendingSlice storage pending = s_pending[orderId];
        if (!pending.exists) {
            return ReasonCode.INVALID_CALLER;
        }
        if (pending.sliceIndex != sliceIndex || pending.amountIn != amountIn) {
            return ReasonCode.INVALID_CALLER;
        }
        return pending.observedImpactBps <= order.maxImpactBps ? ReasonCode.NONE : ReasonCode.IMPACT_TOO_HIGH;
    }

    function recordAfterSwap(bytes32 orderId, uint64 sliceIndex, uint128 amountIn, uint128 amountOut)
        external
        onlyHook
        nonReentrant
        returns (bool completed, uint160 avgPriceX96)
    {
        OrderState storage order = s_orders[orderId];
        PendingSlice storage pending = s_pending[orderId];

        if (order.status != OrderStatus.ACTIVE) {
            revert OrderBookVault__InvalidStatus();
        }
        if (!pending.exists) {
            revert OrderBookVault__PendingSliceMissing();
        }
        if (pending.sliceIndex != sliceIndex || pending.amountIn != amountIn) {
            revert OrderBookVault__SliceMismatch();
        }
        if (amountOut < pending.minAmountOut) {
            revert OrderBookVault__InvalidAmount();
        }
        if (amountIn > order.amountInRemaining) {
            revert OrderBookVault__InvalidAmount();
        }

        delete s_pending[orderId];

        order.amountInRemaining -= amountIn;
        order.amountOutTotal += amountOut;
        order.nextSliceIndex += 1;
        order.lastExecutionBlock = uint64(block.number);
        order.lastExecutionTime = uint40(block.timestamp);

        if (order.amountInRemaining == 0) {
            order.status = OrderStatus.COMPLETED;
            order.epoch += 1;

            avgPriceX96 = uint160((uint256(order.amountOutTotal) << 96) / uint256(order.amountInTotal));
            completed = true;

            emit OrderCompleted(orderId, order.amountInTotal, order.amountOutTotal, avgPriceX96);
            _notifyOrderCompleted(orderId, order.amountInTotal, order.amountOutTotal, avgPriceX96);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       OWNER CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setHook(address newHook) external onlyOwner {
        if (newHook == address(0)) {
            revert OrderBookVault__InvalidAddress();
        }

        address oldHook = hook;
        hook = newHook;

        emit HookUpdated(oldHook, newHook);
    }

    function setExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) {
            revert OrderBookVault__InvalidAddress();
        }

        address oldExecutor = executor;
        executor = newExecutor;

        emit ExecutorUpdated(oldExecutor, newExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _previewNextSlice(bytes32 orderId, bytes32 poolId, uint24 observedImpactBps, address keeper)
        internal
        view
        returns (SlicePreview memory preview)
    {
        OrderState storage order = s_orders[orderId];

        if (order.orderId == bytes32(0)) {
            preview.reasonCode = ReasonCode.INVALID_CALLER;
            return preview;
        }
        if (order.poolId != poolId) {
            preview.reasonCode = ReasonCode.INVALID_CALLER;
            return preview;
        }
        if (order.status == OrderStatus.COMPLETED) {
            preview.reasonCode = ReasonCode.ALREADY_COMPLETED;
            return preview;
        }
        if (order.status == OrderStatus.CANCELLED) {
            preview.reasonCode = ReasonCode.INVALID_CALLER;
            return preview;
        }
        if (order.status == OrderStatus.EXPIRED) {
            preview.reasonCode = ReasonCode.EXPIRED;
            return preview;
        }
        if (order.allowedExecutor != address(0) && keeper != order.allowedExecutor) {
            preview.reasonCode = ReasonCode.INVALID_CALLER;
            return preview;
        }
        if (block.timestamp < order.startTime) {
            preview.reasonCode = ReasonCode.NOT_STARTED;
            return preview;
        }
        if (block.timestamp > order.endTime) {
            preview.reasonCode = ReasonCode.EXPIRED;
            return preview;
        }
        if (s_pending[orderId].exists) {
            preview.reasonCode = ReasonCode.COOLDOWN;
            return preview;
        }
        if (observedImpactBps > order.maxImpactBps) {
            preview.reasonCode = ReasonCode.IMPACT_TOO_HIGH;
            return preview;
        }
        if (order.mode == ExecutionMode.BBE) {
            if (order.lastExecutionBlock != 0 && block.number < order.lastExecutionBlock + order.blocksPerSlice) {
                preview.reasonCode = ReasonCode.COOLDOWN;
                return preview;
            }
        } else if (order.lastExecutionTime != 0 && block.timestamp < order.lastExecutionTime + order.minIntervalSeconds)
        {
            preview.reasonCode = ReasonCode.COOLDOWN;
            return preview;
        }

        uint128 amountIn = order.amountInRemaining;
        if (amountIn == 0) {
            preview.reasonCode = ReasonCode.ALREADY_COMPLETED;
            return preview;
        }

        if (amountIn > order.maxSliceAmount) {
            amountIn = order.maxSliceAmount;
        }

        if (amountIn < order.minSliceAmount && amountIn != order.amountInRemaining) {
            preview.reasonCode = ReasonCode.NO_LIQUIDITY;
            return preview;
        }

        preview.reasonCode = ReasonCode.NONE;
        preview.amountIn = amountIn;
        preview.minAmountOut = order.minAmountOutPerSlice;
        preview.sliceIndex = order.nextSliceIndex;
    }

    function _validateCreateOrder(CreateOrderParams calldata params) internal view {
        if (params.tokenIn == address(0) || params.tokenOut == address(0)) {
            revert OrderBookVault__InvalidAddress();
        }
        if (params.tokenIn == params.tokenOut) {
            revert OrderBookVault__InvalidTokenPair();
        }
        if (params.amountInTotal == 0 || params.maxSliceAmount == 0 || params.minSliceAmount == 0) {
            revert OrderBookVault__InvalidAmount();
        }
        if (params.maxSliceAmount < params.minSliceAmount || params.minSliceAmount > params.amountInTotal) {
            revert OrderBookVault__InvalidAmount();
        }
        if (params.startTime >= params.endTime || params.endTime <= block.timestamp) {
            revert OrderBookVault__InvalidSchedule();
        }
        if (params.maxImpactBps == 0 || params.maxImpactBps > 10_000) {
            revert OrderBookVault__InvalidAmount();
        }

        if (params.mode == ExecutionMode.BBE) {
            if (params.blocksPerSlice == 0) {
                revert OrderBookVault__InvalidCadence();
            }
        } else if (params.minIntervalSeconds == 0) {
            revert OrderBookVault__InvalidCadence();
        }
    }

    function _notifyOrderCreated(bytes32 orderId, address orderOwner, bytes32 poolId, ExecutionMode mode) internal {
        address localHook = hook;
        if (localHook == address(0) || localHook.code.length == 0) {
            return;
        }

        try ILargeCapExecutionHookEvents(localHook).notifyOrderCreated(orderId, orderOwner, poolId, mode) {} catch {}
    }

    function _notifyOrderCancelled(bytes32 orderId, address orderOwner) internal {
        address localHook = hook;
        if (localHook == address(0) || localHook.code.length == 0) {
            return;
        }

        try ILargeCapExecutionHookEvents(localHook).notifyOrderCancelled(orderId, orderOwner) {} catch {}
    }

    function _notifyOrderCompleted(bytes32 orderId, uint128 totalIn, uint128 totalOut, uint160 avgPriceX96) internal {
        address localHook = hook;
        if (localHook == address(0) || localHook.code.length == 0) {
            return;
        }

        try ILargeCapExecutionHookEvents(localHook).notifyOrderCompleted(orderId, totalIn, totalOut, avgPriceX96) {}
            catch {}
    }
}
