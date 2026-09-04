// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";

/// @title SourcingMathLib
/// @notice Venue-agnostic math behind `buyerAssetsBound`.
///
/// @dev Deliberately knows nothing about v3 or v4. A concentrated-liquidity position is a
/// `(sqrtPrice, sqrtLower, sqrtUpper, liquidity)` tuple in both, and the formulas are identical —
/// which is why the math libraries come from **v4-core** even here, in the v3 adapter. They are
/// 0.8-native, so they compile in this project's single profile; v3's own copies are pinned to
/// `=0.7.6` and cannot.
///
/// @dev State of play: this file currently holds only the *naive* bound — position amounts plus
/// the residual converted at spot, with no price impact and no swap fee. That is knowingly an
/// over-estimate. Two corrections are scheduled, and both come from actually running the numbers
/// in `bound.py` rather than from algebra (see `JOURNAL.md`, "Two findings"):
///
///   **A.** Burning liquidity does not move the price — it *thins the book you are about to trade
///   into*. Removing `dL` leaves `sqrtP` unchanged but reduces active `L`, so the residual swap
///   then executes against a thinner pool. Naive algebra misses this entirely and understates the
///   cost. The self-impact is real, and it is self-inflicted.
///
///   **B.** `dL` needs a hard cap at a fraction of active liquidity (0.5 works), *independent* of
///   the slippage budget. Burn past that and `sourced(dL)` stops being monotone, at which point
///   bisection is invalid — it converges on a point that is neither maximal nor safe.
library SourcingMathLib {
    /// @notice Token amounts a position of `liquidity` over `[sqrtLower, sqrtUpper]` is worth at
    /// `sqrtPriceX96`.
    /// @dev Rounds down: this feeds a bound that must never over-promise.
    /// @dev Out of range on either side, a v3 position is entirely one token — which is the whole
    /// sourcing risk. Drift one way and the position is all loan token and the bound is the full
    /// balance; drift the other and it is all residual and the bound collapses. Range exit, not
    /// asset volatility, is the variable that matters.
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);

        if (sqrtPriceX96 <= sqrtLowerX96) {
            // Entirely below the range: all token0.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            // In range: both sides.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            // Entirely above the range: all token1.
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        }
    }

    /// @notice Value of `amount1` of token1, denominated in token0, at `sqrtPriceX96`.
    /// @dev Naive: spot, no price impact, no fee. See the note on this library.
    function quote1For0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount1 == 0) return 0;

        // priceX96 = (sqrtP / 2^96)^2 * 2^96, staged through mulDiv so the square never has to fit
        // in 256 bits — sqrtP can reach 2^160, and sqrtP^2 would be 2^320.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        if (priceX96 == 0) return 0;

        return FullMath.mulDiv(amount1, FixedPoint96.Q96, priceX96);
    }

    /// @notice Value of `amount0` of token0, denominated in token1, at `sqrtPriceX96`.
    /// @dev Naive: spot, no price impact, no fee. See the note on this library.
    function quote0For1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount0 == 0) return 0;

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);

        return FullMath.mulDiv(amount0, priceX96, FixedPoint96.Q96);
    }
}
