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

    /// @dev The book every `_params` case carries unless a test replaces it: four boundaries
    /// starting 5,000 ticks above spot. No residual any position here can produce reaches the first
    /// one — the worst case is a full burn against the thinnest route venue these tests use, which
    /// moves the price ~200 ticks — so the walk provably crosses nothing and reduces to the
    /// closed-form single step. That is what keeps the D5 numbers below meaningful after D6: they
    /// are still measuring the same arithmetic, on a venue deep enough that the book never bites.
    function _deepBook() internal pure returns (SourcingMathLib.TickStep[] memory) {
        return _book(5000, 1000, 4, -1e15);
    }

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
            routeBook: _deepBook(),
            maxSlippageWad: budgetWad
        });
    }

    /// @dev Replaces the deep default with a book that actually bites.
    ///
    /// @dev Mutates and returns the same struct: `BoundParams` is a memory reference, so a caller
    /// wanting both answers has to build the params twice rather than reuse one.
    function _withBook(SourcingMathLib.BoundParams memory p, SourcingMathLib.TickStep[] memory book)
        internal
        pure
        returns (SourcingMathLib.BoundParams memory)
    {
        p.routeBook = book;
        return p;
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
    /// @dev It is zero at *every* budget, including one no deployment could set — which changed
    /// with D6 and is worth stating rather than letting the assertion pass quietly. Before the walk
    /// this quoted the direct side under a 100% budget, on the reasoning that a maker authorising
    /// the loss of the whole residual can still source the loan-token half. That reasoning still
    /// holds; what no longer holds is the model's right to assert it, because a venue with no
    /// active liquidity is one whose book the walk cannot price at all. Under-reporting is the
    /// direction a bound may err in, and the deployable ceiling on `MAX_SLIPPAGE_WAD` is 10%, so
    /// nothing reachable is lost.
    function test_anEmptyRouteVenueQuotesNothingAtAnyBudget() public pure {
        assertEq(SourcingMathLib.boundBySlippage(_params(0, true, 0.0001e18)), 0, "quoted against an empty route venue");
        assertEq(SourcingMathLib.boundBySlippage(_params(0, true, 1e18)), 0, "an unreadable venue is not quotable");

        // Not vacuous: the same position over a venue that *has* a book quotes plenty.
        assertGt(SourcingMathLib.boundBySlippage(_params(1e24, false, 0.0001e18)), 0, "nothing quotes at all");
    }

    /// @dev **The dust floor.** A `dL` too small for the residual to survive rounding used to price
    /// as *free* — zero residual, therefore zero cost, therefore inside any budget. That is what let
    /// a bisection return a bound of 1 wei on a config whose honest answer was zero at every size.
    /// Below the model's resolution is not quotable.
    function test_aBurnTooSmallToPriceIsNotQuotable() public pure {
        (uint256 sourced, uint256 cost) = SourcingMathLib.sourcedFor(_params(1e24, false, 1e18), 1);

        assertEq(sourced, 0, "a dust burn was quoted");
        assertEq(cost, 0);
    }

    /// @dev The same rounding, but out of range, is not rounding at all: the position really is all
    /// loan token, there is nothing to sell, and sourcing it really is free. The two cases have to
    /// be told apart or the floor above would refuse a legitimate one-sided position.
    function test_aOneSidedPositionOutOfRangeIsStillQuotable() public pure {
        SourcingMathLib.BoundParams memory p = _params(1e24, false, 1e18);
        p.sqrtPriceX96 = _upper() + 1; // above the range: all token1, and token1 is the residual

        p.loanIsToken0 = false; // so the loan side is the one the position holds
        (uint256 sourced, uint256 cost) = SourcingMathLib.sourcedFor(p, LIQUIDITY);

        assertGt(sourced, 0, "an out-of-range position quoted nothing");
        assertEq(cost, 0, "a position with no residual to sell was charged for selling it");
    }

    /// @dev **The fee floor.** The venue charges its fee whatever the arithmetic rounds to, so the
    /// modelled cost may never come in under it. The fee is the *proportional* term — it costs the
    /// same fraction at every size — so letting it round away is what turns "no honest bound at any
    /// size" into a spurious dust quote.
    function test_theModelledCostIsNeverBelowTheVenueFee() public pure {
        SourcingMathLib.BoundParams memory p = _params(type(uint128).max, false, 1e18);

        (, uint256 cost) = SourcingMathLib.sourcedFor(p, LIQUIDITY);

        // A book this deep has no measurable impact, so the fee is all that is left — and it is
        // still charged rather than rounded to nothing.
        assertGt(cost, 0, "an effectively lossless swap was modelled as free");
    }

    /// @dev A route fee that exceeds the budget on its own admits no fill at any size, and the only
    /// honest answer is zero. This is the shape of the bug the D5 review found: 5bp of route fee
    /// against a 1bp budget quoted 1 wei, which then failed to settle.
    function test_aFeeAboveTheBudgetQuotesNothingRatherThanDust() public pure {
        SourcingMathLib.BoundParams memory p = _params(type(uint128).max, false, 0.0001e18);
        p.routeFeePips = 500; // 5bp against a 1bp budget

        assertEq(SourcingMathLib.boundBySlippage(p), 0, "quoted a size the route fee alone rules out");
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

    /// THE MULTI-TICK WALK (D6) ///

    /// @dev A book of `count` boundaries `spacingTicks` apart, each removing `netOut` liquidity on
    /// the way out — the shape of a concentrated pool's book above spot, expressed in the
    /// direction-of-travel sign convention `TickBookLib` writes.
    function _book(int24 from, int24 spacingTicks, uint256 count, int128 netOut)
        internal
        pure
        returns (SourcingMathLib.TickStep[] memory book)
    {
        book = new SourcingMathLib.TickStep[](count);
        for (uint256 i; i < count; ++i) {
            book[i] = SourcingMathLib.TickStep({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(from + spacingTicks * int24(uint24(i + 1))),
                liquidityNet: netOut
            });
        }
    }

    function _swap(uint128 liquidity, uint256 amountIn, SourcingMathLib.TickStep[] memory book)
        internal
        pure
        returns (SourcingMathLib.RouteSwap memory)
    {
        return SourcingMathLib.RouteSwap({
            sqrtPriceX96: SQRT_PRICE_1,
            activeLiquidity: liquidity,
            feePips: FEE_100,
            zeroForOne: false,
            amountIn: amountIn,
            book: book
        });
    }

    /// @dev The walk's floor: a swap that never reaches the first boundary crosses nothing, so it
    /// must be the single step to the wei. If these two ever disagree, one of them is wrong about
    /// the fee or the rounding, and this is the only test that would say so.
    function test_aSwapThatCrossesNothingIsExactlyTheSingleStep() public pure {
        (uint256 single,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e24, FEE_100, false, 1e18, 0);
        (uint256 walked, uint160 after_, bool complete) =
            SourcingMathLib.multiStepOut(_swap(1e24, 1e18, _book(0, 500, 4, -1e23)));

        assertTrue(complete, "a swap well inside the first tick should be priceable");
        assertEq(walked, single, "the walk and the single step disagree inside one range");
        assertGt(after_, SQRT_PRICE_1, "a one-for-zero swap should have raised the price");
    }

    /// @dev **The D6 result, in miniature.** Same swap, same starting liquidity; the only difference
    /// is that the walk knows the book thins out past the ticks it crosses and the single step does
    /// not. The single step returns more — that is the over-promise, and it is measured at 25.33%
    /// through a real adapter in `UniswapV3BuyCallback.t.sol`.
    function test_theSingleStepOverStatesASwapThatWalksIntoAThinningBook() public pure {
        SourcingMathLib.TickStep[] memory book = _book(0, 10, 8, -1e17);

        (uint256 single,) = SourcingMathLib.singleStepOut(SQRT_PRICE_1, 1e18, FEE_100, false, 1e15, 0);
        (uint256 walked,, bool complete) = SourcingMathLib.multiStepOut(_swap(1e18, 1e15, book));

        assertTrue(complete, "the book should absorb this one");
        assertLt(walked, single, "the walk did not charge for the liquidity it crossed out of");
    }

    /// @dev The fix itself. Beyond the last boundary the book says nothing, and the model does not
    /// get to assume. An input the book cannot absorb comes back incomplete, and the partial output
    /// it did compute is not a quote.
    function test_aSwapThatWalksOffTheBookIsNotPriceable() public pure {
        (uint256 walked,, bool complete) = SourcingMathLib.multiStepOut(_swap(1e18, 100e18, _book(0, 10, 2, -4e17)));

        assertFalse(complete, "walking off the end of the book was reported as a completed swap");
        assertGt(walked, 0, "the partial output is still worth returning, it is just not a quote");
    }

    /// @dev **The regression test for the review's critical finding.** `boundBySlippage` used to
    /// fall back to the single step when `routeBook` was empty, on the reasoning that an empty book
    /// meant *no book was read* and only library tests could produce one. Wrong on the second half:
    /// `TickBookLib.readBook` returns an empty array whenever it finds no initialized tick, so a
    /// real adapter over a sparse venue reached it — and it is the pre-D6 model, so it reopened the
    /// +25.33% fail-open on exactly the venues the walk exists for. The fallback is gone. An empty
    /// book prices nothing, at the swap and at the bound.
    ///
    /// @dev Deliberately asserted at both levels. `multiStepOut` refusing is not enough on its own:
    /// the bug was one layer up, in what `sourcedFor` did with the refusal.
    function test_anEmptyBookQuotesNothingRatherThanFallingBackToTheSingleStep() public pure {
        (,, bool complete) = SourcingMathLib.multiStepOut(_swap(1e18, 1e15, new SourcingMathLib.TickStep[](0)));
        assertFalse(complete, "an empty book priced a swap it knew nothing about");

        SourcingMathLib.BoundParams memory p = _params(1e24, false, 0.001e18);
        assertGt(SourcingMathLib.boundBySlippage(p), 0, "the deep-book control quoted nothing");

        assertEq(
            SourcingMathLib.boundBySlippage(
                _withBook(_params(1e24, false, 0.001e18), new SourcingMathLib.TickStep[](0))
            ),
            0,
            "an unreadable venue fell back to assuming its liquidity continues"
        );
    }

    /// @dev A gap between two liquidity ranges is ordinary, not the end of the book: the pool skips
    /// across it for free and so does the walk. Refusing here would truncate every quote on a venue
    /// whose liquidity is not contiguous — which is most of them.
    function test_theWalkCrossesAZeroLiquidityGap() public pure {
        SourcingMathLib.TickStep[] memory book = new SourcingMathLib.TickStep[](3);
        book[0] = SourcingMathLib.TickStep({sqrtPriceX96: TickMath.getSqrtPriceAtTick(10), liquidityNet: -1e18});
        book[1] = SourcingMathLib.TickStep({sqrtPriceX96: TickMath.getSqrtPriceAtTick(60), liquidityNet: 1e18});
        book[2] = SourcingMathLib.TickStep({sqrtPriceX96: TickMath.getSqrtPriceAtTick(200), liquidityNet: -1e18});

        (uint256 walked, uint160 after_, bool complete) = SourcingMathLib.multiStepOut(_swap(1e18, 2e15, book));

        assertTrue(complete, "an empty stretch of book ended the walk");
        assertGt(walked, 0, "the walk returned nothing across the gap");
        assertGt(after_, TickMath.getSqrtPriceAtTick(60), "the price should have jumped the gap for free");
    }

    /// @dev A book ordered against the direction of travel would make `computeSwapStep` infer the
    /// opposite direction and answer with total confidence. Refuse it: this is the one input to the
    /// walk an adapter could get wrong silently, and a silently wrong bound is the failure mode D6
    /// exists to remove.
    function test_aBookPointingTheWrongWayIsRefused() public pure {
        SourcingMathLib.TickStep[] memory downward = _book(-100, 10, 4, -1e17);

        (,, bool complete) = SourcingMathLib.multiStepOut(_swap(1e18, 1e15, downward));

        assertFalse(complete, "a book on the wrong side of spot was walked anyway");
    }

    /// @dev The walk, wired through `boundBySlippage`. The same position and budget quote strictly
    /// less once the model can see that the route venue thins out — and the difference is not a
    /// tuning choice, it is the part of the D5 answer that was never there to source.
    function test_theBoundIsSmallerOnceTheBookIsRead() public pure {
        SourcingMathLib.BoundParams memory p = _params(1e19, false, 0.001e18);
        uint256 assumed = SourcingMathLib.boundBySlippage(p);
        uint256 walked = SourcingMathLib.boundBySlippage(_withBook(p, _book(0, 1, 20, -2e18)));

        assertGt(assumed, 0, "the single-step path stopped quoting");
        assertLt(walked, assumed, "reading the book did not cost the optimistic bound anything");
    }

    /// @dev And it stays a bound. A book that describes a cliff one tick above spot — everything,
    /// then nothing — quotes only what fits below the cliff, which is an order of magnitude less
    /// than the same budget quotes when the model is free to assume the book continues. Note what
    /// it is *not*: zero. The part of the swap the book does account for is real, and refusing it
    /// would be its own kind of wrong answer.
    function test_theBoundStopsAtTheCliffTheBookDescribes() public pure {
        SourcingMathLib.TickStep[] memory cliff = new SourcingMathLib.TickStep[](1);
        cliff[0] = SourcingMathLib.TickStep({sqrtPriceX96: TickMath.getSqrtPriceAtTick(1), liquidityNet: -1e19});

        uint256 assumed = SourcingMathLib.boundBySlippage(_params(1e19, false, 0.001e18));
        uint256 walked = SourcingMathLib.boundBySlippage(_withBook(_params(1e19, false, 0.001e18), cliff));

        assertGt(walked, 0, "the fill that fits under the cliff is still quotable");
        assertLt(walked, assumed / 5, "the cliff did not cut the quote");
    }
}
