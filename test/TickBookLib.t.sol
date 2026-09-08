// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SourcingMathLib} from "../src/libraries/SourcingMathLib.sol";
import {TickBookLib} from "../src/libraries/TickBookLib.sol";

/// @notice A tick bitmap and a set of tick liquidities, standing in for a pool.
///
/// @dev The point of testing against this rather than against a fork is control. A live pool's book
/// is whatever it is; here the exact set of initialized ticks is chosen, so a walk that misses one,
/// invents one, or reads a word boundary wrong has nowhere to hide.
contract MockTickSource {
    int24 public immutable SPACING;

    mapping(int16 => uint256) internal bitmap;
    mapping(int24 => int128) internal liquidityNet;

    constructor(int24 spacing) {
        SPACING = spacing;
    }

    /// @dev Flips a tick on, exactly as a pool does when a position first uses it.
    function initialize(int24 tick, int128 net) external {
        require(tick % SPACING == 0, "unaligned tick");

        (int16 wordPos, uint8 bitPos) = TickBitmap.position(TickBitmap.compress(tick, SPACING));
        bitmap[wordPos] |= (uint256(1) << bitPos);
        liquidityNet[tick] = net;
    }

    function read(int24 tick, bool zeroForOne) external view returns (SourcingMathLib.TickStep[] memory) {
        return TickBookLib.readBook(tick, SPACING, zeroForOne, _word, _net);
    }

    function _word(int16 wordPosition) private view returns (uint256) {
        return bitmap[wordPosition];
    }

    function _net(int24 tick) private view returns (int128) {
        return liquidityNet[tick];
    }
}

/// @notice Unit tests for the bitmap search `TickBookLib` re-implements by hand.
///
/// @dev These exist because that search is *copied arithmetic*. v4-core's own
/// `nextInitializedTickWithinOneWord` takes the bitmap as a `mapping storage`, which is unreachable
/// from a contract reading another contract's bitmap through a getter, so the mask-and-`BitMath`
/// work had to be rewritten against a word passed by value. v3 and v4 even formulate it
/// differently. A quoter has to match the pool bit for bit, and until now the only thing checking
/// that here was a fork test asserting a number several layers downstream — which would have
/// reported an off-by-one in the word arithmetic as a slightly wrong bound.
contract TickBookLibTest is Test {
    int24 internal constant SPACING = 10;

    MockTickSource internal pool;

    function setUp() public {
        pool = new MockTickSource(SPACING);
    }

    function _ticks(SourcingMathLib.TickStep[] memory book) internal pure returns (int24[] memory found) {
        found = new int24[](book.length);
        for (uint256 i; i < book.length; ++i) {
            found[i] = TickMath.getTickAtSqrtPrice(book[i].sqrtPriceX96);
        }
    }

    /// @dev Walking up finds every initialized tick above spot, in order, and nothing else.
    function test_theWalkFindsExactlyTheInitializedTicksAbove() public {
        pool.initialize(20, -1e12);
        pool.initialize(50, -2e12);
        pool.initialize(1000, -3e12);

        int24[] memory found = _ticks(pool.read(5, false));

        assertEq(found.length, 3, "wrong number of ticks found");
        assertEq(found[0], 20);
        assertEq(found[1], 50);
        assertEq(found[2], 1000);
    }

    /// @dev And walking down finds the ones below, nearest first. Ordering is not cosmetic: the walk
    /// consumes the array in sequence and would price a swap against the wrong tick if it were not
    /// outward from spot.
    function test_theWalkFindsTicksBelowInOutwardOrder() public {
        pool.initialize(-20, 1e12);
        pool.initialize(-50, 2e12);
        pool.initialize(-1000, 3e12);

        int24[] memory found = _ticks(pool.read(5, true));

        assertEq(found.length, 3, "wrong number of ticks found");
        assertEq(found[0], -20);
        assertEq(found[1], -50);
        assertEq(found[2], -1000);
    }

    /// @dev **The sign flip.** A pool stores `liquidityNet` as the change when the tick is crossed
    /// from below; a downward swap crosses from above and applies the negation. `TickBookLib` bakes
    /// that in so the walk is direction-free, which means getting it backwards would make a
    /// thinning book look like a deepening one — an over-estimate, in the one direction that
    /// matters.
    function test_theBookNegatesLiquidityNetForADownwardWalk() public {
        pool.initialize(-20, 1e12);
        pool.initialize(20, -5e12);

        assertEq(pool.read(0, true)[0].liquidityNet, -1e12, "downward crossing did not negate");
        assertEq(pool.read(0, false)[0].liquidityNet, -5e12, "upward crossing should be stored as-is");
    }

    /// @dev One word covers 256 tick-spacings, so a book that reaches past it is the ordinary case,
    /// not an edge one — and continuing across the boundary is the part of the search a
    /// hand-rewrite is most likely to get wrong, because the mask changes and the cursor has to be
    /// advanced rather than re-derived.
    function test_theWalkContinuesAcrossAWordBoundary() public {
        // Word 0 spans compressed ticks 0-255, i.e. ticks 0-2550 at this spacing.
        pool.initialize(2540, -1e12);
        pool.initialize(2560, -2e12);
        pool.initialize(6000, -3e12);

        int24[] memory found = _ticks(pool.read(0, false));

        assertEq(found.length, 3, "the walk stopped at the word boundary");
        assertEq(found[0], 2540);
        assertEq(found[1], 2560);
        assertEq(found[2], 6000);
    }

    /// @dev Negative ticks are their own case because `compress` rounds towards negative infinity
    /// and the word index goes negative with them. Getting this wrong reads a different pool's
    /// worth of bits and would look like a venue with no book.
    function test_theWalkHandlesNegativeTicksAndWords() public {
        pool.initialize(-2560, 1e12);
        pool.initialize(-2570, 2e12);

        int24[] memory found = _ticks(pool.read(-2500, true));

        assertEq(found.length, 2, "negative-word walk lost a tick");
        assertEq(found[0], -2560);
        assertEq(found[1], -2570);
    }

    /// @dev The current tick is inclusive going down and exclusive going up, which is v3's
    /// convention and has to be v3's convention: a tick the price is sitting exactly on has already
    /// been crossed on the way up and has not been on the way down.
    function test_theTickUnderSpotBelongsToTheDownwardWalkOnly() public {
        pool.initialize(0, 1e12);
        pool.initialize(100, -1e12);

        assertEq(_ticks(pool.read(0, true))[0], 0, "the current tick should be crossable downward");
        assertEq(_ticks(pool.read(0, false))[0], 100, "the current tick was recrossed upward");
    }

    /// @dev **The empty case, which is the one that mattered.** A venue with no initialized tick in
    /// the direction of travel yields an empty book — not an error, and not a signal that the book
    /// was never read. `SourcingMathLib` used to treat the two as the same thing and fall back to
    /// assuming liquidity continued forever, which is what made this reachable rather than
    /// theoretical. See `test_anEmptyBookQuotesNothingRatherThanFallingBackToTheSingleStep`.
    function test_aVenueWithNoInitializedTicksYieldsAnEmptyBook() public view {
        assertEq(pool.read(0, false).length, 0, "invented a tick out of an empty bitmap");
        assertEq(pool.read(0, true).length, 0, "invented a tick out of an empty bitmap");
    }

    /// @dev The read is bounded whether the book is dense or sparse. Dense is the binding case:
    /// every initialized tick costs an iteration, so a venue with more of them than `MAX_STEPS`
    /// gets truncated — and a truncated book is what `multiStepOut` reports as an incomplete swap
    /// rather than quoting past.
    function test_theWalkStopsAtMaxSteps() public {
        for (uint256 i = 1; i <= TickBookLib.MAX_STEPS + 20; ++i) {
            pool.initialize(int24(uint24(i)) * SPACING, -1e9);
        }

        assertEq(pool.read(0, false).length, TickBookLib.MAX_STEPS, "the walk ran past its budget");
    }

    /// @dev Prices are strictly ordered in the direction of travel, which is exactly the property
    /// `multiStepOut` refuses a book for lacking. Fuzzed over the tick offsets because the ordering
    /// has to hold for every arrangement, not the three or four a hand-written case would pick.
    function testFuzz_theBookIsStrictlyOrderedInTheDirectionOfTravel(uint8 count, bool zeroForOne) public {
        count = uint8(bound(count, 2, 30));

        for (uint256 i = 1; i <= count; ++i) {
            int24 offset = int24(uint24(i)) * SPACING;
            pool.initialize(zeroForOne ? -offset : offset, 1e9);
        }

        SourcingMathLib.TickStep[] memory book = pool.read(0, zeroForOne);
        assertEq(book.length, count, "lost a tick");

        for (uint256 i = 1; i < book.length; ++i) {
            if (zeroForOne) {
                assertLt(book[i].sqrtPriceX96, book[i - 1].sqrtPriceX96, "a downward book must fall");
            } else {
                assertGt(book[i].sqrtPriceX96, book[i - 1].sqrtPriceX96, "an upward book must rise");
            }
        }
    }
}
