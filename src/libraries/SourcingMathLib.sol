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
    /// @dev Stand-in for the residual swap's price impact, which `liquidityForTarget` does not
    /// model. Without it the sizing has no slack at all: the spot-and-fee estimate turns out to be
    /// very nearly exact, so *any* impact makes it come up short and forces a second burn.
    ///
    /// @dev Sized from measurement, not intuition. On the D2 fork run — a 10k+10k USDC/USDT
    /// position, a 5k fill — the realised sourcing came in **0.2bp** below the estimate. 25bp is
    /// roughly a hundredfold cushion on the product venue while costing the maker only the yield on
    /// 0.25% more liquidity than the fill strictly needed, and even that is not lost: the surplus
    /// lands in the buffer and serves the next fill.
    ///
    /// @dev It will not be enough everywhere. A thin venue can move further than this on a large
    /// fill, which is why the caller still needs a fallback. Replacing this constant with an actual
    /// impact term is D5/D6.
    uint256 internal constant IMPACT_MARGIN_BPS = 25;

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

    /// @notice How much liquidity to burn to raise `target` of the loan token.
    ///
    /// @dev Token amounts are exactly linear in liquidity at a fixed price and range, so the whole
    /// sizing reduces to one proportion: burn the fraction of the position whose value covers the
    /// target. What is *not* linear is the residual swap, and that is the entire error term.
    ///
    /// @dev Biased conservative on purpose — every approximation here rounds towards burning **more**
    /// liquidity than strictly necessary:
    ///   - the route pool's fee is subtracted from the residual's contribution;
    ///   - uncollected fees are excluded from the denominator, even though `collect` sweeps them
    ///     anyway, so they arrive as a bonus rather than as something the estimate leaned on;
    ///   - the division rounds up.
    ///
    /// @dev The bias is deliberate because the two failure directions are not symmetric. Burning a
    /// little too much costs some yield and parks the surplus in the buffer, where it serves the
    /// next fill. Burning too little means the caller has to go back and unwind the remainder,
    /// paying for a second burn and a second swap — strictly worse than having burnt more the first
    /// time. What is still missing is price impact, which pushes the other way; until that is
    /// modelled (D5/D6) the caller needs a fallback for the optimistic case.
    ///
    /// @param targetIsToken0 Whether the token being raised is the pool's `token0`.
    /// @param routeFeePips The residual swap venue's fee, in hundredths of a bip (e.g. 100 = 0.01%).
    /// @return The liquidity to burn, never more than `liquidity`.
    function liquidityForTarget(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity,
        bool targetIsToken0,
        uint256 target,
        uint24 routeFeePips
    ) internal pure returns (uint128) {
        if (liquidity == 0 || target == 0) return 0;

        (uint256 amount0, uint256 amount1) = amountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);

        (uint256 targetSide, uint256 residualSide) = targetIsToken0 ? (amount0, amount1) : (amount1, amount0);

        uint256 residualQuoted =
            targetIsToken0 ? quote1For0(residualSide, sqrtPriceX96) : quote0For1(residualSide, sqrtPriceX96);

        // Net of the swap that will convert it. `routeFeePips` is out of 1e6.
        uint256 residualNet = FullMath.mulDiv(residualQuoted, 1e6 - routeFeePips, 1e6);
        uint256 sourceable = targetSide + residualNet;

        uint256 targetWithMargin = target + FullMath.mulDivRoundingUp(target, IMPACT_MARGIN_BPS, 10_000);

        // The position cannot be valued, or cannot cover the target even in full. Burn all of it
        // and let the caller decide whether what came out was enough.
        if (sourceable == 0 || targetWithMargin >= sourceable) return liquidity;

        uint256 needed = FullMath.mulDivRoundingUp(liquidity, targetWithMargin, sourceable);

        return needed >= liquidity ? liquidity : uint128(needed);
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
