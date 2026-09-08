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
/// @dev State of play: two bounds live here.
///
///   `naiveBound` — position amounts plus the residual converted at spot, with no price impact and
///   no swap fee. Knowingly an over-estimate, kept because it is what the impact is *measured
///   against*: D4 put the gap at 0.63bp on the stable venue.
///
///   `boundBySlippage` — the single-step version, D5. It simulates the residual swap against the
///   route venue's active liquidity and bisects on how much liquidity to burn, subject to a
///   slippage budget. Exact while the swap stays inside the active tick range, which on a stable
///   pair a small residual does; D6's multi-tick walk removes that qualifier.
///
/// @dev Both findings from `bound.py` are implemented here rather than approximated (see
/// `JOURNAL.md`, "Two findings"):
///
///   **A.** Burning liquidity does not move the price — it *thins the book you are about to trade
///   into*. Removing `dL` leaves `sqrtP` unchanged but reduces active `L`, so the residual swap
///   then executes against a thinner pool. Naive algebra misses this entirely and understates the
///   cost. The self-impact is real, and it is self-inflicted. `sourcedFor` subtracts the burn from
///   the route venue's active liquidity — but only when the parked position *is* in that venue and
///   in range, which `bound.py` could assume and this cannot. Park and route are independently
///   chosen here, and a burn on one pool does not thin another.
///
///   **B.** `dL` needs a hard cap at a fraction of active liquidity (0.5 works), *independent* of
///   the slippage budget. Burn past that and `sourced(dL)` stops being monotone, at which point
///   bisection is invalid — it converges on a point that is neither maximal nor safe. See
///   `maxBurnableLiquidity`.
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
    /// fill, which is why the caller still needs a fallback.
    ///
    /// @dev **It stays a constant, and D5 did not replace it.** The impact *is* modelled now — in
    /// `boundBySlippage`, which bisects and can afford to. This constant serves the other half:
    /// `liquidityForTarget` runs inside `onBuy`, on the taker's gas, where a bisection is not
    /// something to spend a taker's money on. Model in the view, execute in the callback. A quoted
    /// fill has already been checked against the real thing, so the margin's job is only to absorb
    /// what moved between the quote and the block.
    uint256 internal constant IMPACT_MARGIN_BPS = 25;

    /// @dev How far past the sized burn a caller may escalate when the estimate came up short.
    /// See `escalationCeiling`.
    uint256 internal constant ESCALATION_FACTOR = 2;

    /// @dev **Finding B, as a number.** The largest share of the route venue's *active* liquidity a
    /// single burn may remove, in WAD. Above this the position being unwound is too large a part of
    /// the book it is about to trade into: `sourcedFor` stops rising with `dL`, and the bisection
    /// in `boundBySlippage` is then searching a function that is not monotone — it converges on a
    /// point that is neither maximal nor safe.
    ///
    /// @dev 0.5 is `bound.py`'s validated value, not a guess: at half-width 50 ticks the uncapped
    /// function is measurably non-monotone and the capped one is monotone, and the cap does not
    /// distort the answer in the ordinary case where the slippage budget binds first.
    ///
    /// @dev It binds *only* when the parked position sits in the route venue, in range. Park and
    /// route are independently chosen, and a burn on one pool does not thin another.
    uint256 internal constant MAX_ACTIVE_SHARE_WAD = 0.5e18;

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
    /// time. Price impact pushes the other way, and here it is approximated by `IMPACT_MARGIN_BPS`
    /// rather than simulated: this is the execution path, and `boundBySlippage` is where the real
    /// model lives. The caller keeps a bounded fallback for the optimistic case — see
    /// `escalationCeiling`.
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

    /// @notice The most liquidity a fill may burn in total, given what the sizing said it needed.
    ///
    /// @dev Twice the sized burn: ample for the impact `IMPACT_MARGIN_BPS` failed to cover — that
    /// would have to run to eight times the margin before this binds on an honest fill — while
    /// keeping the burn proportional to the fill.
    ///
    /// @dev **Proportionality is the invariant.** Escalating straight to the remaining liquidity
    /// means any fill too small to survive the rounding in `liquidityForTarget` unwinds the entire
    /// position: a take of one wei sizes to a burn that yields zero tokens, comes up short, and
    /// takes the maker's whole LP with it. A fill that cannot justify its own sourcing has to fail
    /// closed instead. See `JOURNAL.md`, "A one-wei take could destroy the whole position".
    ///
    /// @dev Lives here rather than in an adapter because it is arithmetic on liquidity units and
    /// nothing else — the same answer on v3, on a v4 position owned by the callback, and on a v4
    /// position the maker holds. All three call it.
    ///
    /// @param sized What `liquidityForTarget` asked for.
    /// @param available The position's whole liquidity, which the ceiling can never exceed.
    function escalationCeiling(uint128 sized, uint128 available) internal pure returns (uint256) {
        uint256 ceiling = uint256(sized) * ESCALATION_FACTOR;
        return ceiling < available ? ceiling : available;
    }

    /// SINGLE-STEP BOUND (D5) ///

    /// @notice Everything `boundBySlippage` needs about the two venues, in one struct.
    ///
    /// @dev A struct rather than eleven arguments because this is threaded through a bisection —
    /// but also because the split is the point. The first block is the *parked* position, the
    /// second is the *route* venue where its residual gets sold, and they are separate on purpose:
    /// nothing in this design holds their prices together, and a bound that assumed one pool would
    /// silently be wrong for every maker who routed elsewhere.
    struct BoundParams {
        /// @dev Park venue: spot, the position's range, and its liquidity.
        uint160 sqrtPriceX96;
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint128 liquidity;
        /// @dev Whether the loan token is the *park* pool's token0. The other side is the residual.
        bool loanIsToken0;
        /// @dev Route venue: spot, active liquidity at the current tick, and the fee.
        uint160 routeSqrtPriceX96;
        uint128 routeLiquidity;
        uint24 routeFeePips;
        /// @dev Whether the residual is the *route* pool's token0. Sorting can differ between the
        /// two venues, so this is not derivable from `loanIsToken0`.
        bool residualIsRouteToken0;
        /// @dev Whether the parked position and the route venue are the same pool. When they are,
        /// burning `dL` thins the very book the residual is about to be sold into — finding A.
        bool routeIsParkVenue;
        /// @dev Slippage budget, WAD. Cost is measured against the route venue's pre-trade spot.
        uint256 maxSlippageWad;
    }

    /// @notice Output of an exact-input swap that does not leave the active tick range.
    ///
    /// @dev This is `SwapMath.computeSwapStep` with the target price removed: one step, constant
    /// `liquidity`, no tick crossing. Exact whenever the swap really does stay inside the range —
    /// which for a small residual on a stable pair it does, and which is precisely the case D5
    /// claims. Outside it, this assumes `liquidity` continues forever in the direction of travel,
    /// so it **over**-estimates against a book that thins out. D6's tick walk is what removes the
    /// assumption; until then the caller's slippage budget is what keeps the swap small enough for
    /// it to hold.
    ///
    /// @param liquidityRemoved Liquidity burnt out of this same venue immediately beforehand.
    /// Finding A: the burn does not move `sqrtPriceX96`, it reduces the `L` the swap executes
    /// against.
    /// @return amountOut Tokens received, net of the venue's fee.
    /// @return sqrtPriceAfterX96 Where the swap left the price. Returned so a caller — or a test —
    /// can check the single-step assumption actually held rather than trusting it.
    function singleStepOut(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint24 feePips,
        bool zeroForOne,
        uint256 amountIn,
        uint128 liquidityRemoved
    ) internal pure returns (uint256 amountOut, uint160 sqrtPriceAfterX96) {
        uint128 active = liquidity > liquidityRemoved ? liquidity - liquidityRemoved : 0;
        if (active == 0 || amountIn == 0 || sqrtPriceX96 == 0) return (0, sqrtPriceX96);

        // The fee is taken off the input and never reaches the curve, exactly as the pool does it.
        uint256 amountInLessFee = FullMath.mulDiv(amountIn, 1e6 - feePips, 1e6);
        if (amountInLessFee == 0) return (0, sqrtPriceX96);

        sqrtPriceAfterX96 = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, active, amountInLessFee, zeroForOne);

        // Round down: this feeds a bound that must never over-promise.
        amountOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtPriceAfterX96, sqrtPriceX96, active, false)
            : SqrtPriceMath.getAmount0Delta(sqrtPriceAfterX96, sqrtPriceX96, active, false);
    }

    /// @notice What burning `dL` of the parked position actually sources, and what that costs.
    ///
    /// @dev The whole unwind, modelled: burn `dL`, keep the loan-token side, sell the residual side
    /// on the route venue against a book that `dL` has just thinned (when it is the same book).
    ///
    /// @dev `cost` is measured against the route venue's **pre-trade spot**, so it is exactly fee
    /// plus price impact — the two things the single step models and can therefore be held to. It
    /// deliberately does *not* capture the park-venue-versus-route-venue dislocation, which is a
    /// price question rather than a swap question and belongs to `PRICE_REF` at D8. Note that this
    /// choice moves where the budget bites, never what `sourced` is worth: `sourced` is the
    /// simulated output either way.
    ///
    /// @return sourced Loan token obtained: the direct side plus the residual's swap proceeds.
    /// @return cost What the residual lost on the way through the route venue, in loan token.
    function sourcedFor(BoundParams memory p, uint128 dL) internal pure returns (uint256 sourced, uint256 cost) {
        if (dL == 0) return (0, 0);

        (uint256 amount0, uint256 amount1) = amountsForLiquidity(p.sqrtPriceX96, p.sqrtLowerX96, p.sqrtUpperX96, dL);
        (uint256 direct, uint256 residual) = p.loanIsToken0 ? (amount0, amount1) : (amount1, amount0);

        // A zero residual means one of two very different things. Out of range, the position
        // really is all loan token, there is nothing to swap, and sourcing it is genuinely free.
        // *In* range it is a rounding artifact of a `dL` too small to express both sides — and
        // pricing that as free is what lets a bisection latch onto dust and return a bound no fill
        // can honour. Below the model's resolution is not quotable.
        if (residual == 0) return _isInRange(p) ? (0, 0) : (direct, 0);

        (uint256 got,) = singleStepOut(
            p.routeSqrtPriceX96,
            p.routeLiquidity,
            p.routeFeePips,
            p.residualIsRouteToken0,
            residual,
            _selfThinning(p, dL)
        );

        uint256 atSpot = p.residualIsRouteToken0
            ? quote0For1(residual, p.routeSqrtPriceX96)
            : quote1For0(residual, p.routeSqrtPriceX96);

        // A residual too small to price at all is below the model's resolution, and quoting it as
        // free is how a bisection ends up returning dust. Not quotable.
        if (atSpot == 0) return (0, 0);

        sourced = direct + got;
        cost = atSpot > got ? atSpot - got : 0;

        // The venue charges its fee whatever the arithmetic rounds to, so the modelled cost may
        // never come in under it. Without this floor the fee vanishes at small `dL` — and the fee
        // is precisely the term that is *proportional*, so a config whose route fee alone exceeds
        // the slippage budget has no honest bound at any size. Rounding it away turns that "zero"
        // into a spurious dust quote.
        uint256 feeFloor = FullMath.mulDivRoundingUp(atSpot, p.routeFeePips, 1e6);
        if (cost < feeFloor) cost = feeFloor;
    }

    /// @notice The most liquidity `boundBySlippage` is allowed to consider burning.
    /// @dev Finding B. See `MAX_ACTIVE_SHARE_WAD`.
    function maxBurnableLiquidity(BoundParams memory p) internal pure returns (uint128) {
        if (!_thinsRoute(p)) return p.liquidity;

        uint256 share = FullMath.mulDiv(p.routeLiquidity, MAX_ACTIVE_SHARE_WAD, 1e18);
        return share < p.liquidity ? uint128(share) : p.liquidity;
    }

    /// @notice Largest amount of loan token the position can source with unwind cost inside
    /// `maxSlippageWad`.
    ///
    /// @dev The answer `buyerAssetsBound` exists to give, and the reason it is an `external view`:
    /// this bisects, up to 128 times, and over `eth_call` that is free. Executing on the taker's
    /// gas could never afford it — model in the view, execute in the callback.
    ///
    /// @dev `sourcedFor` is increasing and its cost ratio is increasing in `dL` inside the cap, so
    /// the predicate flips once and bisection finds the flip. The one wrinkle is at the very
    /// bottom: a `dL` small enough that the residual rounds away is not quotable, so the predicate
    /// is false-then-true-then-false rather than monotone. That costs nothing — `lo` only ever
    /// advances on a *true*, so the search either finds the upper boundary or returns 0.
    /// Under-reporting is the safe direction for a bound; over-reporting is not.
    ///
    /// @dev The dust floor is load-bearing rather than tidy. Before `sourcedFor` refused it, a
    /// `dL` whose residual rounded to zero priced as *free* and passed any budget, so a maker whose
    /// route fee alone exceeded their slippage budget — where the honest answer is zero at every
    /// size — got a bound of **1 wei** instead, and a fill of 1 wei then reverted. A bound that
    /// small is not merely useless, it is wrong in both directions at once.
    function boundBySlippage(BoundParams memory p) internal pure returns (uint256) {
        uint128 hi = maxBurnableLiquidity(p);
        if (hi == 0) return 0;

        // The common case on a deep venue: the whole position is within budget, no search needed.
        if (_withinBudget(p, hi)) {
            (uint256 sourced,) = sourcedFor(p, hi);
            return sourced;
        }

        uint128 lo = 0;
        while (hi - lo > 1) {
            uint128 mid = lo + (hi - lo) / 2;
            if (_withinBudget(p, mid)) lo = mid;
            else hi = mid;
        }

        if (lo == 0) return 0;

        (uint256 sourcedAtLo,) = sourcedFor(p, lo);
        return sourcedAtLo;
    }

    /// @dev Whether burning out of the parked position thins the route venue — finding A. True only
    /// when the two are the same pool *and* the position straddles the live tick, because an
    /// out-of-range position contributes nothing to active liquidity.
    function _thinsRoute(BoundParams memory p) private pure returns (bool) {
        return p.routeIsParkVenue && p.routeLiquidity > 0 && _isInRange(p);
    }

    /// @dev Straddling the live tick, on exactly the boundaries `amountsForLiquidity` uses. The two
    /// have to agree: an out-of-range position is one-sided there and contributes nothing to active
    /// liquidity here, and a disagreement at the edge would be a silent wrong answer either way.
    function _isInRange(BoundParams memory p) private pure returns (bool) {
        return p.sqrtPriceX96 > p.sqrtLowerX96 && p.sqrtPriceX96 < p.sqrtUpperX96;
    }

    /// @dev How much of a `dL` burn comes out of the route venue's active liquidity.
    function _selfThinning(BoundParams memory p, uint128 dL) private pure returns (uint128) {
        return _thinsRoute(p) ? dL : 0;
    }

    /// @dev Whether burning `dL` keeps the unwind inside the slippage budget.
    function _withinBudget(BoundParams memory p, uint128 dL) private pure returns (bool) {
        (uint256 sourced, uint256 cost) = sourcedFor(p, dL);
        if (sourced == 0) return false;

        return FullMath.mulDiv(cost, 1e18, sourced) <= p.maxSlippageWad;
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
