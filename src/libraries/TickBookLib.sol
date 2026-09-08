// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {BitMath} from "v4-core/libraries/BitMath.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SourcingMathLib} from "./SourcingMathLib.sol";

/// @title TickBookLib
/// @notice Reads a concentrated-liquidity venue's initialized ticks into the flat `TickStep[]` that
/// `SourcingMathLib.multiStepOut` walks.
///
/// @dev **Why a snapshot rather than a live walk.** `boundBySlippage` bisects, evaluating the
/// residual swap up to 128 times. Reading the book inside the swap — the way a pool does — would
/// make the state reads `O(ticks × 128)`. Reading it once, in the direction the residual will be
/// sold, makes them `O(ticks)` and leaves the swap model `pure`. That is also what keeps
/// `SourcingMathLib` venue-agnostic: it never learns whether the ticks came from a v3 pool's own
/// storage or a v4 `PoolManager`'s.
///
/// @dev **Why function pointers.** v3 and v4 differ in exactly two reads — one bitmap word and one
/// tick's `liquidityNet` — and in nothing else. Passing those two as `internal view` functions
/// writes the walk once instead of once per adapter, with no wrapper contract and no venue enum.
///
/// @dev v4-core's own `TickBitmap.nextInitializedTickWithinOneWord` takes the bitmap as a
/// `mapping(int16 => uint256) storage`, which is unreachable from here: the mapping lives in
/// another contract, and is read through a getter or `extsload`. The word arithmetic is
/// re-implemented against a word passed by value; `compress` and `position` are `pure` and reused.
library TickBookLib {
    /// @notice Iterations the walk may spend before it stops looking.
    ///
    /// @dev One iteration consults one bitmap word and either records the initialized tick it found
    /// or hops to the next word, so the cursor always advances and the read is bounded whether the
    /// book is dense or sparse. What that buys depends on which: 128 initialized ticks if they are
    /// packed against spot, or 128 words — 32,768 tick-spacings — if the venue is empty above it.
    ///
    /// @dev Deliberately generous, because the walk runs in an `external view` over `eth_call`
    /// where an extra hundred storage reads cost nothing and a short book costs quoted size.
    /// Measured on Base's USDC/USDT 0.05% pool the whole book is **eight** initialized ticks, all
    /// inside the first word, and raising this to 300 does not move the bound by a wei.
    ///
    /// @dev Running out is not an error and is never extrapolated over: the book simply ends, and
    /// `multiStepOut` reports a swap that walks off it as incomplete. Fail closed — a residual the
    /// book cannot absorb is not quotable, which is the whole of D6.
    uint256 internal constant MAX_STEPS = 128;

    /// @notice The venue's initialized ticks, ordered outward from `tick` in the direction a
    /// `zeroForOne` (or not) swap would travel.
    ///
    /// @param tick The venue's current tick, from `slot0`.
    /// @param tickSpacing The venue's tick spacing.
    /// @param zeroForOne Direction of the residual swap. True walks *down* in price.
    /// @param wordAt Reads one word of the venue's tick bitmap.
    /// @param netAt Reads one tick's `liquidityNet`, with the pool's own sign convention.
    function readBook(
        int24 tick,
        int24 tickSpacing,
        bool zeroForOne,
        function(int16) internal view returns (uint256) wordAt,
        function(int24) internal view returns (int128) netAt
    ) internal view returns (SourcingMathLib.TickStep[] memory book) {
        SourcingMathLib.TickStep[] memory scratch = new SourcingMathLib.TickStep[](MAX_STEPS);
        uint256 found;

        int24 cursor = tick;
        for (uint256 i; i < MAX_STEPS; ++i) {
            (int24 next, bool initialized) = _nextTick(cursor, tickSpacing, zeroForOne, wordAt);

            if (initialized) {
                // Stored pre-flipped: a `zeroForOne` swap crosses the tick from above, where the
                // pool applies `-liquidityNet`. The walk downstream is then direction-free.
                int128 net = netAt(next);
                scratch[found++] = SourcingMathLib.TickStep({
                    sqrtPriceX96: TickMath.getSqrtPriceAtTick(next), liquidityNet: zeroForOne ? -net : net
                });
            }

            // Off the end of the tick range there is nothing further to read, in either direction.
            if (zeroForOne ? next <= TickMath.MIN_TICK : next >= TickMath.MAX_TICK) break;

            cursor = zeroForOne ? next - 1 : next;
        }

        book = new SourcingMathLib.TickStep[](found);
        for (uint256 i; i < found; ++i) {
            book[i] = scratch[i];
        }
    }

    /// @dev The next tick at or beyond `tick` in the direction of travel, and whether it is
    /// initialized. Mirrors `TickBitmap.nextInitializedTickWithinOneWord`: the answer is confined
    /// to the current word, so an uninitialized result is a word boundary rather than a claim that
    /// nothing lies beyond it, and the caller advances and asks again.
    function _nextTick(int24 tick, int24 tickSpacing, bool lte, function(int16) internal view returns (uint256) wordAt)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);

        if (lte) {
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
            // All bits at or below the current one: everything at or below the current tick.
            uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
            uint256 masked = wordAt(wordPos) & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = wordAt(wordPos) & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }

        // `compress` rounds towards negative infinity and the multiply above can land outside the
        // representable range; clamp so `getSqrtPriceAtTick` is always given a legal tick.
        if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        else if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
    }
}
