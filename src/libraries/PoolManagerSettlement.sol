// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

library PoolManagerSettlement {
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        if (Currency.unwrap(currency) == address(0)) {
            manager.settle{value: amount}();
            return;
        }

        manager.sync(currency);
        if (payer == address(this)) {
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        }
        manager.settle();
    }

    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        manager.take(currency, recipient, amount);
    }
}
