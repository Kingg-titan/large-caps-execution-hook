// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolManagerSettlement} from "src/libraries/PoolManagerSettlement.sol";

contract SettlementManagerMock {
    uint256 public syncCalls;
    uint256 public settleCalls;
    uint256 public settleValueTotal;
    uint256 public takeCalls;

    Currency public lastSyncCurrency;
    Currency public lastTakeCurrency;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;

    function sync(Currency currency) external {
        syncCalls += 1;
        lastSyncCurrency = currency;
    }

    function settle() external payable returns (uint256 paid) {
        settleCalls += 1;
        settleValueTotal += msg.value;
        paid = msg.value;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        takeCalls += 1;
        lastTakeCurrency = currency;
        lastTakeRecipient = recipient;
        lastTakeAmount = amount;
    }
}

contract SettlementHarness {
    using PoolManagerSettlement for Currency;

    function settleCurrency(Currency currency, IPoolManager manager, address payer, uint256 amount) external {
        currency.settle(manager, payer, amount);
    }

    function takeCurrency(Currency currency, IPoolManager manager, address recipient, uint256 amount) external {
        currency.take(manager, recipient, amount);
    }

    receive() external payable {}
}

contract PoolManagerSettlementTest is Test {
    MockERC20 internal token;
    SettlementManagerMock internal manager;
    SettlementHarness internal harness;

    address internal payer = makeAddr("payer");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        token = new MockERC20("SET", "SET", 18);
        manager = new SettlementManagerMock();
        harness = new SettlementHarness();

        token.mint(address(harness), 1_000e18);
        token.mint(payer, 1_000e18);
        vm.prank(payer);
        token.approve(address(harness), type(uint256).max);

        vm.deal(address(harness), 10 ether);
    }

    function testSettleNoopsOnZeroAmount() external {
        harness.settleCurrency(Currency.wrap(address(token)), IPoolManager(address(manager)), address(harness), 0);
        assertEq(manager.syncCalls(), 0);
        assertEq(manager.settleCalls(), 0);
    }

    function testSettleNativeCurrencyUsesValuePath() external {
        uint256 amount = 1 ether;

        harness.settleCurrency(Currency.wrap(address(0)), IPoolManager(address(manager)), address(harness), amount);

        assertEq(manager.syncCalls(), 0);
        assertEq(manager.settleCalls(), 1);
        assertEq(manager.settleValueTotal(), amount);
    }

    function testSettleTokenCurrencyPayerIsHarnessUsesTransfer() external {
        uint256 amount = 11e18;

        harness.settleCurrency(Currency.wrap(address(token)), IPoolManager(address(manager)), address(harness), amount);

        assertEq(manager.syncCalls(), 1);
        assertEq(manager.settleCalls(), 1);
        assertEq(token.balanceOf(address(manager)), amount);
    }

    function testSettleTokenCurrencyPayerIsExternalUsesTransferFrom() external {
        uint256 amount = 7e18;

        harness.settleCurrency(Currency.wrap(address(token)), IPoolManager(address(manager)), payer, amount);

        assertEq(manager.syncCalls(), 1);
        assertEq(manager.settleCalls(), 1);
        assertEq(token.balanceOf(address(manager)), amount);
        assertEq(token.balanceOf(payer), 1_000e18 - amount);
    }

    function testTakeNoopsOnZeroAmountAndCallsManagerOnPositiveAmount() external {
        harness.takeCurrency(Currency.wrap(address(token)), IPoolManager(address(manager)), recipient, 0);
        assertEq(manager.takeCalls(), 0);

        harness.takeCurrency(Currency.wrap(address(token)), IPoolManager(address(manager)), recipient, 5e18);
        assertEq(manager.takeCalls(), 1);
        assertEq(Currency.unwrap(manager.lastTakeCurrency()), address(token));
        assertEq(manager.lastTakeRecipient(), recipient);
        assertEq(manager.lastTakeAmount(), 5e18);
    }
}
