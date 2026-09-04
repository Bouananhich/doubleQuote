// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IMidnight} from "midnight/src/interfaces/IMidnight.sol";

import {ForkBase} from "./ForkBase.sol";
import {
    IERC20Meta,
    INonfungiblePositionManager,
    IPositionManagerV4,
    IUniswapV3Factory,
    IUniswapV3Pool
} from "./interfaces/IUniswapMinimal.sol";

/// @dev Exercises `clz` (Osaka) so the fork EVM is proven to execute it, not just assumed to.
/// Midnight relies on it in `UtilsLib.mostSignificantBit`, and the whole build follows Midnight's
/// compiler settings on that basis.
contract ClzProbe {
    function mostSignificantBit(uint256 x) external pure returns (uint256 res) {
        assembly ("memory-safe") {
            res := sub(255, clz(x))
        }
    }
}

/// @notice D1 harness check: one compiler profile, forking Base, binding deployed Midnight and
/// Uniswap v3/v4 through interfaces only. If this is red, the fallback is v3-only (see PLAN.md).
contract ForkSanityTest is ForkBase {
    function test_forkIsBaseAtPinnedBlock() public view {
        assertEq(block.chainid, 8453, "not Base");
        assertEq(block.number, FORK_BLOCK, "fork block drifted");
    }

    function test_osakaOpcodesAvailable() public {
        ClzProbe probe = new ClzProbe();
        assertEq(probe.mostSignificantBit(1), 0, "msb(1)");
        assertEq(probe.mostSignificantBit(256), 8, "msb(256)");
        assertEq(probe.mostSignificantBit(type(uint256).max), 255, "msb(max)");
    }

    function test_midnightIsLive() public view {
        // A deployed Midnight is what makes the 0.8.34/osaka profile non-negotiable.
        assertGt(MIDNIGHT.code.length, 0, "no code at MIDNIGHT");
        assertTrue(IMidnight(MIDNIGHT).configurator() != address(0), "configurator unset");
    }

    function test_uniswapV3IsLive() public view {
        assertEq(IUniswapV3Factory(V3_FACTORY).feeAmountTickSpacing(500), 10, "500 tick spacing");
        assertEq(IUniswapV3Factory(V3_FACTORY).feeAmountTickSpacing(100), 1, "100 tick spacing");
        assertEq(
            INonfungiblePositionManager(V3_POSITION_MANAGER).factory(), V3_FACTORY, "NPM factory mismatch"
        );
    }

    function test_uniswapV4IsLive() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0, "no code at PoolManager");
        assertEq(
            IPositionManagerV4(V4_POSITION_MANAGER).poolManager(), V4_POOL_MANAGER, "posm/pm mismatch"
        );
    }

    function test_tokensResolve() public view {
        assertEq(IERC20Meta(USDC).decimals(), 6, "USDC decimals");
        assertEq(IERC20Meta(USDT).decimals(), 6, "USDT decimals");
        assertEq(IERC20Meta(CBBTC).decimals(), 8, "cbBTC decimals");
    }

    function test_parkingVenuesResolveAndAreLiquid() public view {
        // Stress venue: cbBTC/USDC 0.05%.
        assertEq(
            IUniswapV3Factory(V3_FACTORY).getPool(CBBTC, USDC, 500), POOL_CBBTC_USDC_500, "cbBTC/USDC"
        );
        assertGt(IUniswapV3Pool(POOL_CBBTC_USDC_500).liquidity(), 0, "cbBTC/USDC empty");

        // Product venue: USDC/USDT 0.01%.
        assertEq(
            IUniswapV3Factory(V3_FACTORY).getPool(USDC, USDT, 100), POOL_USDC_USDT_100, "USDC/USDT"
        );
        assertGt(IUniswapV3Pool(POOL_USDC_USDT_100).liquidity(), 0, "USDC/USDT empty");

        // The stable pool is the deeper of the two, which is why it is the product venue.
        assertGt(
            IUniswapV3Pool(POOL_USDC_USDT_100).liquidity(),
            IUniswapV3Pool(POOL_CBBTC_USDC_500).liquidity(),
            "stable pool should be deeper"
        );
    }

    /// @dev v3 gives every pool an oracle for free. This is the `V3TwapRef` dependency, and the
    /// reason v3 is the load-bearing adapter.
    function test_v3OracleIsUsableOnBothVenues() public view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 0;

        (int56[] memory cumulativesStable,) = IUniswapV3Pool(POOL_USDC_USDT_100).observe(secondsAgos);
        assertTrue(cumulativesStable[0] != cumulativesStable[1], "stable pool oracle flat");

        (int56[] memory cumulativesVolatile,) =
            IUniswapV3Pool(POOL_CBBTC_USDC_500).observe(secondsAgos);
        assertTrue(cumulativesVolatile[0] != cumulativesVolatile[1], "volatile pool oracle flat");
    }
}
