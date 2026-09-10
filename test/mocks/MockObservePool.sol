// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

/// @notice Test-only: a v3 pool that answers `observe()` with whatever cumulative ticks it is told.
///
/// @dev `V3TwapRef.meanTick` does integer division on a *difference* of accumulators, and the
/// interesting cases — a negative mean, a negative mean that does not divide evenly, an oracle too
/// young to answer — cannot be produced on demand from a real pool at a pinned fork block. This
/// makes them addressable, which is what lets the rounding branch be tested rather than reasoned
/// about.
contract MockObservePool {
    address public token0;
    address public token1;

    int56 internal cumulativeThen;
    int56 internal cumulativeNow;
    bool internal reverts;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    /// @dev `observe` returns oldest-first, so `then` is index 0 and `now` is index 1.
    function setCumulatives(int56 then_, int56 now_) external {
        cumulativeThen = then_;
        cumulativeNow = now_;
    }

    /// @dev Stands in for a pool whose `observationCardinality` cannot reach back far enough. The
    /// real one reverts with the string `OLD`.
    function setReverts(bool reverts_) external {
        reverts = reverts_;
    }

    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory) {
        require(!reverts, "OLD");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = cumulativeThen;
        tickCumulatives[1] = cumulativeNow;

        return (tickCumulatives, new uint160[](2));
    }
}
