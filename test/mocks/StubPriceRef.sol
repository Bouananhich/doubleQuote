// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IPriceRef} from "../../src/interfaces/IPriceRef.sol";

/// @dev Placeholder reference. The D2 adapter holds `PRICE_REF` as an immutable but does not read
/// it yet — wiring it into the bound is D8. This exists so the envelope can be constructed, and so
/// the day the adapter starts reading it, every test that should have been using a real reference
/// fails loudly instead of silently passing.
contract StubPriceRef is IPriceRef {
    uint160 public sqrtPrice;

    constructor(uint160 sqrtPrice_) {
        sqrtPrice = sqrtPrice_;
    }

    function set(uint160 sqrtPrice_) external {
        sqrtPrice = sqrtPrice_;
    }

    function refSqrtPriceX96(address token0, address token1) external view returns (uint160) {
        if (sqrtPrice == 0) revert PairNotSupported(token0, token1);
        return sqrtPrice;
    }
}
