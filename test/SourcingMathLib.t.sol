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
