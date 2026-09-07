// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SourcingMathLib} from "../src/libraries/SourcingMathLib.sol";

/// @notice Unit tests for the venue-agnostic sourcing math. No fork: these pin the branches and the
/// rounding exactly, which a fork test cannot do because the live price moves the answer.
contract SourcingMathLibTest is Test {
    /// @dev Tick 0, so token0 and token1 trade at parity and the arithmetic is checkable by hand.
    uint160 internal constant SQRT_PRICE_1 = 79228162514264337593543950336; // 2**96

    uint128 internal constant LIQUIDITY = 1e18;
    uint24 internal constant FEE_100 = 100; // 0.01%

    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;

    function _lower() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(TICK_LOWER);
    }

    function _upper() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(TICK_UPPER);
    }

    /// @dev Mirrors the library's own valuation so the tests can express targets as a fraction of
    /// capacity rather than as magic numbers.
    function _sourceable(bool targetIsToken0) internal pure returns (uint256) {
        (uint256 amount0, uint256 amount1) =
            SourcingMathLib.amountsForLiquidity(SQRT_PRICE_1, _lower(), _upper(), LIQUIDITY);
        (uint256 targetSide, uint256 residualSide) = targetIsToken0 ? (amount0, amount1) : (amount1, amount0);
        uint256 quoted = targetIsToken0
            ? SourcingMathLib.quote1For0(residualSide, SQRT_PRICE_1)
            : SourcingMathLib.quote0For1(residualSide, SQRT_PRICE_1);
        return targetSide + (quoted * (1e6 - FEE_100)) / 1e6;
    }

    function _liquidityFor(uint256 target, bool targetIsToken0) internal pure returns (uint128) {
        return SourcingMathLib.liquidityForTarget(
            SQRT_PRICE_1, _lower(), _upper(), LIQUIDITY, targetIsToken0, target, FEE_100
        );
    }

    /// AMOUNTS ///

    function test_amountsAreSymmetricAtParityInASymmetricRange() public pure {
        (uint256 amount0, uint256 amount1) =
            SourcingMathLib.amountsForLiquidity(SQRT_PRICE_1, _lower(), _upper(), LIQUIDITY);

        assertGt(amount0, 0, "no token0");
        assertApproxEqRel(amount0, amount1, 0.0001e18, "symmetric range at parity should be balanced");
    }

    function test_amountsBelowRangeAreAllToken0() public pure {
        (uint256 amount0, uint256 amount1) =
            SourcingMathLib.amountsForLiquidity(_lower() - 1, _lower(), _upper(), LIQUIDITY);

        assertGt(amount0, 0, "no token0 below range");
        assertEq(amount1, 0, "token1 below range");
    }

    function test_amountsAboveRangeAreAllToken1() public pure {
        (uint256 amount0, uint256 amount1) =
            SourcingMathLib.amountsForLiquidity(_upper(), _lower(), _upper(), LIQUIDITY);

        assertEq(amount0, 0, "token0 above range");
        assertGt(amount1, 0, "no token1 above range");
    }

    function test_amountsAreLinearInLiquidity() public pure {
        (uint256 halfAmount0,) = SourcingMathLib.amountsForLiquidity(SQRT_PRICE_1, _lower(), _upper(), LIQUIDITY / 2);
        (uint256 fullAmount0,) = SourcingMathLib.amountsForLiquidity(SQRT_PRICE_1, _lower(), _upper(), LIQUIDITY);

        // Linearity is what makes the whole sizing a single proportion rather than a search.
        assertApproxEqRel(halfAmount0 * 2, fullAmount0, 0.000001e18, "amounts not linear in liquidity");
    }

    function test_amountsAreZeroWithoutLiquidity() public pure {
        (uint256 amount0, uint256 amount1) = SourcingMathLib.amountsForLiquidity(SQRT_PRICE_1, _lower(), _upper(), 0);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    /// SIZING ///

    function test_sizingIsProportionalToTheTarget() public pure {
        uint256 capacity = _sourceable(true);

        uint128 quarter = _liquidityFor(capacity / 4, true);
        uint128 half = _liquidityFor(capacity / 2, true);

        assertApproxEqRel(uint256(half), uint256(quarter) * 2, 0.001e18, "sizing not proportional");
        assertApproxEqRel(uint256(half), uint256(LIQUIDITY) / 2, 0.01e18, "half the capacity is not half the position");
    }

    /// @dev The margin is what stops the estimate landing exactly on the target and coming up short
    /// the moment the swap moves the price at all.
    function test_sizingBurnsSlightlyMoreThanTheBareProportion() public pure {
        uint256 capacity = _sourceable(true);
        uint256 target = capacity / 2;

        uint128 sized = _liquidityFor(target, true);
        uint256 bare = (uint256(LIQUIDITY) * target) / capacity;

        assertGt(sized, bare, "no margin applied");
        // 25bp, so the overshoot is small enough not to matter.
        assertLt(sized, (bare * 1005) / 1000, "margin far larger than intended");
    }

    /// @dev The branch a fork test cannot pin, because it needs the target to sit inside the margin
    /// band just below capacity, and the live price moves that band.
    function test_sizingBurnsEverythingOnceTheMarginExceedsCapacity() public pure {
        uint256 capacity = _sourceable(true);

        // Below capacity, but within 25bp of it, so the margin pushes the requirement over.
        uint256 target = (capacity * 9999) / 10_000;

        assertLt(target, capacity, "target should be under capacity");
        assertEq(_liquidityFor(target, true), LIQUIDITY, "should burn the whole position");
    }

    function test_sizingBurnsEverythingWhenTheTargetExceedsCapacity() public pure {
        assertEq(_liquidityFor(_sourceable(true) * 2, true), LIQUIDITY, "should burn the whole position");
    }

    function test_sizingIsZeroForAZeroTarget() public pure {
        assertEq(_liquidityFor(0, true), 0);
    }

    function test_sizingIsZeroWithoutLiquidity() public pure {
        assertEq(
            SourcingMathLib.liquidityForTarget(SQRT_PRICE_1, _lower(), _upper(), 0, true, 1e18, FEE_100),
            0,
            "nothing to burn"
        );
    }

    /// @dev Works from either side of the pair. Token1-denominated targets are the case where the
    /// loan token is the pool's token1, which is a coin flip on any given pair.
    function test_sizingWorksWhenTheTargetIsToken1() public pure {
        uint256 capacity = _sourceable(false);

        assertApproxEqRel(
            uint256(_liquidityFor(capacity / 2, false)),
            uint256(LIQUIDITY) / 2,
            0.01e18,
            "token1 target sized differently from token0"
        );
    }

    /// @dev Out of range on the residual side: the position is entirely residual, so the whole
    /// target has to come through the swap. This is range exit, which is the sourcing risk that
    /// scales with exactly the parameter that generates the yield.
    function test_sizingHandlesAPositionThatIsAllResidual() public pure {
        // Above the range, the position is all token1; a token0 target must be swapped for.
        uint128 sized = SourcingMathLib.liquidityForTarget(_upper(), _lower(), _upper(), LIQUIDITY, true, 1e15, FEE_100);

        assertGt(sized, 0, "should still be sourceable through the swap");
        assertLe(sized, LIQUIDITY, "cannot burn more than exists");
    }

    /// ESCALATION CEILING ///

    /// @dev The property the ceiling exists for. A fill sized to almost nothing must not be able to
    /// reach the whole position, however far short its burn falls.
    function test_theCeilingKeepsADustBurnProportional() public pure {
        assertEq(SourcingMathLib.escalationCeiling(1, LIQUIDITY), 2, "a one-unit burn could escalate past two");
    }

    function test_theCeilingIsTwiceTheSizedBurn() public pure {
        assertEq(SourcingMathLib.escalationCeiling(1e17, LIQUIDITY), 2e17);
    }

    /// @dev It is a ceiling, not a target: it can never exceed what the position holds.
    function test_theCeilingClampsToTheAvailableLiquidity() public pure {
        assertEq(SourcingMathLib.escalationCeiling(uint128(LIQUIDITY), LIQUIDITY), LIQUIDITY, "clamp at exactly full");
        assertEq(SourcingMathLib.escalationCeiling(uint128(LIQUIDITY / 2 + 1), LIQUIDITY), LIQUIDITY, "clamp past full");
    }

    function test_theCeilingIsZeroForAZeroBurn() public pure {
        assertEq(SourcingMathLib.escalationCeiling(0, LIQUIDITY), 0, "nothing sized, nothing to escalate to");
    }

    /// @dev No `uint128` can overflow the ceiling, because it is computed in `uint256`.
    function testFuzz_theCeilingNeverExceedsTheAvailableLiquidity(uint128 sized, uint128 available) public pure {
        assertLe(SourcingMathLib.escalationCeiling(sized, available), available);
    }

    /// INVARIANTS ///

    function testFuzz_sizingNeverExceedsTheAvailableLiquidity(uint256 target, bool targetIsToken0) public pure {
        target = bound(target, 0, type(uint128).max);

        assertLe(_liquidityFor(target, targetIsToken0), LIQUIDITY);
    }

    function testFuzz_sizingIsMonotonicInTheTarget(uint256 smaller, uint256 larger) public pure {
        uint256 capacity = _sourceable(true);
        smaller = bound(smaller, 0, capacity);
        larger = bound(larger, smaller, capacity);

        assertLe(_liquidityFor(smaller, true), _liquidityFor(larger, true), "sizing must not decrease with the target");
    }

    /// SINGLE-STEP BOUND ///

    /// @dev A deep venue: the position is a thousandth of the book, so its residual barely moves it.
    function _params(uint128 routeLiquidity, bool routeIsParkVenue, uint256 budgetWad)
        internal
        pure
        returns (SourcingMathLib.BoundParams memory)
    {
        return SourcingMathLib.BoundParams({
            sqrtPriceX96: SQRT_PRICE_1,
            sqrtLowerX96: _lower(),
            sqrtUpperX96: _upper(),
            liquidity: LIQUIDITY,
            loanIsToken0: true,
            routeSqrtPriceX96: SQRT_PRICE_1,
            routeLiquidity: routeLiquidity,
            routeFeePips: FEE_100,
            residualIsRouteToken0: false,
            routeIsParkVenue: routeIsParkVenue,
            maxSlippageWad: budgetWad
        });
    }

    /// @dev The step is the exact-input formula and nothing else: no fee, no impact, no venue, just
    /// `L` and a price. At parity with a residual a millionth of the book, output is input to well
    /// under a basis point.
    function test_theSingleStepIsNearlyLosslessAgainstADeepBook() public pure {
        (uint256 out,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, 0, false, 1e18, 0);

        assertApproxEqRel(out, 1e18, 0.00001e18, "a millionth of the book should barely move it");
        assertLt(out, 1e18, "a swap returned more than it was given");
    }

    function test_theSingleStepChargesTheVenueFee() public pure {
        (uint256 free,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, 0, false, 1e18, 0);
        (uint256 paid,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 0);

        assertLt(paid, free, "the fee was not charged");
        assertApproxEqRel(free - paid, 1e14, 0.001e18, "1bp of 1e18 is 1e14");
    }

    /// @dev **Finding A.** Burning does not move the price, it removes liquidity from the book the
    /// residual is about to be sold into. Same swap, thinner book, worse fill.
    function test_burningTheBookMakesTheSameSwapWorse() public pure {
        (uint256 whole,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 0);
        (uint256 thinned,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 5e23);

        assertLt(thinned, whole, "thinning the book did not cost anything");
    }

    function test_theSingleStepIsZeroWhenTheBurnTookTheWholeBook() public pure {
        (uint256 out, uint160 after_) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 1e24);

        assertEq(out, 0, "sold into an empty book");
        assertEq(after_, SQRT_PRICE_1, "an impossible swap moved the price");
    }

    /// @dev Selling token1 raises the price, selling token0 lowers it. The direction is not
    /// cosmetic: it decides which `getAmountXDelta` prices the output, and getting it backwards
    /// would leave the bound plausible and wrong.
    function test_theSingleStepMovesThePriceInTheDirectionOfTheTrade() public pure {
        (, uint160 up) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 0);
        (, uint160 down) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, true, 1e18, 0);

        assertGt(up, SQRT_PRICE_1, "selling token1 did not raise the price");
        assertLt(down, SQRT_PRICE_1, "selling token0 did not lower the price");
    }

    /// @dev The cost the budget is measured against is exactly what the residual lost on the way
    /// through the route venue — fee plus impact — never the loan-token side, which is not swapped.
    function test_sourcingCostsOnlyWhatTheResidualLoses() public pure {
        SourcingMathLib.BoundParams memory p = _params(1e24, false, 1e18);

        (uint256 sourced, uint256 cost) = SourcingMathLib.sourcedFor(p, LIQUIDITY);

        assertGt(sourced, 0, "nothing sourced");
        assertGt(cost, 0, "a real swap cost nothing");
        assertLt(cost, sourced / 100, "the whole position cannot cost 1% on a book this deep");
    }

    function test_sourcingIsZeroForAZeroBurn() public pure {
        (uint256 sourced, uint256 cost) = SourcingMathLib.sourcedFor(_params(1e24, false, 1e18), 0);

        assertEq(sourced, 0);
        assertEq(cost, 0);
    }

    /// @dev **Finding B.** The cap is on the *route* venue's active liquidity, and it binds only
    /// when the burn actually thins that venue.
    function test_theActiveShareCapBindsOnlyWhenTheBurnThinsTheRoute() public pure {
        // Position is the whole book. Same pool: half of it is the most that may be burnt.
        assertEq(
            SourcingMathLib.maxBurnableLiquidity(_params(LIQUIDITY, true, 1e18)),
            LIQUIDITY / 2,
            "the active-share cap did not bind"
        );

        // Different pool: burning here thins nothing there, so the whole position is available.
        assertEq(
            SourcingMathLib.maxBurnableLiquidity(_params(LIQUIDITY, false, 1e18)),
            LIQUIDITY,
            "the cap bound on a venue the burn does not touch"
        );
    }

    /// @dev An out-of-range position contributes nothing to active liquidity, so burning it thins
    /// nothing even when park and route are the same pool.
    function test_theCapIgnoresAnOutOfRangePosition() public pure {
        SourcingMathLib.BoundParams memory p = _params(LIQUIDITY, true, 1e18);
        p.sqrtPriceX96 = _upper() + 1;
        p.routeSqrtPriceX96 = _upper() + 1;

        assertEq(SourcingMathLib.maxBurnableLiquidity(p), LIQUIDITY, "an idle position was treated as active");
    }

    /// @dev A budget wide enough to cover any real swap returns the whole position — the fast path,
    /// and the ordinary answer on a deep venue.
    function test_aGenerousBudgetQuotesTheWholePosition() public pure {
        SourcingMathLib.BoundParams memory p = _params(1e24, false, 1e18);

        (uint256 whole,) = SourcingMathLib.sourcedFor(p, LIQUIDITY);

        assertEq(SourcingMathLib.boundBySlippage(p), whole, "a 100% budget did not quote the whole position");
    }

    /// @dev The point of the whole exercise: tighten the budget and the quote falls, on the same
    /// position, at the same price, with the same paper value.
    /// @dev The route venue here is ten times the position rather than a thousand, because on a
    /// book deep enough neither budget binds and the test would pass for the wrong reason.
    function test_aTighterBudgetQuotesLess() public pure {
        uint256 wide = SourcingMathLib.boundBySlippage(_params(1e19, false, 0.001e18));
        uint256 tight = SourcingMathLib.boundBySlippage(_params(1e19, false, 0.0001e18));

        assertGt(tight, 0, "the tight budget quoted nothing at all");
        assertGt(wide, tight, "tightening the budget did not reduce the quote");
    }

    /// @dev A budget no swap can meet has to quote zero rather than a small-but-wrong number. The
    /// bisection's floor is where a bound that under-promises is still correct and one that rounds
    /// up is not.
    function test_anImpossibleBudgetQuotesNothing() public pure {
        assertEq(SourcingMathLib.boundBySlippage(_params(1e21, false, 0)), 0, "a zero budget quoted something");
    }

    /// @dev A route venue with no liquidity sells the residual for nothing, so the residual is a
    /// total loss and only the loan-token side of the burn survives. Under any realistic budget
    /// that whole-residual loss blows through the ratio at every `dL`, and the quote is zero.
    ///
    /// @dev It is *not* zero under a 100% budget, and that is consistent rather than a gap: a maker
    /// who authorises losing everything on the swap really can still source the direct side. The
    /// deployable ceiling on `MAX_SLIPPAGE_WAD` is 10%, so no deployment can ask for that.
    function test_anEmptyRouteVenueQuotesNothingUnderARealBudget() public pure {
        assertEq(SourcingMathLib.boundBySlippage(_params(0, true, 0.0001e18)), 0, "quoted against an empty route venue");

        (uint256 direct,) = SourcingMathLib.sourcedFor(_params(0, true, 1e18), LIQUIDITY);
        assertEq(
            SourcingMathLib.boundBySlippage(_params(0, true, 1e18)),
            direct,
            "a 100% budget should still reach the loan-token side"
        );
    }

    /// @dev Mirrors `bound.py`'s monotonicity check, which is what makes the bisection legitimate:
    /// inside the cap, burning more sources more and costs proportionally more. If this ever fails,
    /// `boundBySlippage` is searching a function it has no right to bisect.
    function test_sourcingRisesWithTheBurnAndSoDoesItsCostRatio() public pure {
        SourcingMathLib.BoundParams memory p = _params(2 * uint128(LIQUIDITY), true, 1e18);
        uint128 cap = SourcingMathLib.maxBurnableLiquidity(p);

        uint256 previousSourced = 0;
        uint256 previousRatio = 0;

        for (uint256 i = 1; i <= 20; ++i) {
            (uint256 sourced, uint256 cost) = SourcingMathLib.sourcedFor(p, uint128((uint256(cap) * i) / 20));
            uint256 ratio = (cost * 1e18) / sourced;

            assertGt(sourced, previousSourced, "sourcing did not rise with the burn");
            assertGe(ratio, previousRatio, "the cost ratio fell as the burn grew");

            previousSourced = sourced;
            previousRatio = ratio;
        }
    }

    function testFuzz_theBoundNeverExceedsTheWholePosition(uint256 budgetWad) public pure {
        budgetWad = bound(budgetWad, 0, 1e18);

        SourcingMathLib.BoundParams memory p = _params(1e24, false, budgetWad);
        (uint256 whole,) = SourcingMathLib.sourcedFor(p, LIQUIDITY);

        assertLe(SourcingMathLib.boundBySlippage(p), whole, "quoted more than the position can source");
    }

    /// QUOTES ///

    function test_quotesAreInverseAtParity() public pure {
        assertApproxEqRel(SourcingMathLib.quote1For0(1e18, SQRT_PRICE_1), 1e18, 0.000001e18, "1->0 at parity");
        assertApproxEqRel(SourcingMathLib.quote0For1(1e18, SQRT_PRICE_1), 1e18, 0.000001e18, "0->1 at parity");
    }

    function test_quotesAreZeroForZero() public pure {
        assertEq(SourcingMathLib.quote1For0(0, SQRT_PRICE_1), 0);
        assertEq(SourcingMathLib.quote0For1(0, SQRT_PRICE_1), 0);
    }

    /// @dev Above parity, token1 is worth less in token0 terms and token0 more in token1 terms.
    function test_quotesTrackThePrice() public pure {
        uint160 sqrtPriceHigh = TickMath.getSqrtPriceAtTick(10_000);

        assertLt(
            SourcingMathLib.quote1For0(1e18, sqrtPriceHigh),
            SourcingMathLib.quote1For0(1e18, SQRT_PRICE_1),
            "token1 should be worth less in token0 as price rises"
        );
        assertGt(
            SourcingMathLib.quote0For1(1e18, sqrtPriceHigh),
            SourcingMathLib.quote0For1(1e18, SQRT_PRICE_1),
            "token0 should be worth more in token1 as price rises"
        );
    }
}
