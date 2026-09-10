// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market} from "midnight/src/interfaces/IMidnight.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Vm} from "forge-std/Vm.sol";

import {ForkBase} from "./ForkBase.sol";
import {IERC20Meta, IPermit2} from "./interfaces/IUniswapMinimal.sol";
import {V3TwapRef} from "../src/price-refs/V3TwapRef.sol";
import {V4PoolPusher} from "./mocks/V4PoolPusher.sol";

/// @notice What both v4 suites start from: the real USDC/USDT 0.01% v4 pool, a range around the
/// live tick, and a maker holding the tokens to park.
///
/// @dev What is *not* here is the parking itself. The two adapters park in incompatible ways — one
/// owns its liquidity directly on the `PoolManager`, the other operates an NFT the maker keeps —
/// and that difference is the thing under test, so each suite does its own.
///
/// @dev **Sized to the venue, not to v3.** The v4 pool holds 5.43e11 of active liquidity against
/// the v3 pool's 3.93e14 — 724x thinner at this block, same pair, same fee tier, same tick.
/// Parking the v3 fixture's 10k+10k here would make the maker's position seven times the entire
/// pool, and every residual swap would move the price by more than the 25bp sizing margin covers.
/// So this parks 2k+2k and the suites fill in the hundreds. Not a workaround — it is what the
/// venue absorbs, and it is why the D11 gas table compares plumbing rather than trades.
abstract contract V4ParkedBase is ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAX_SLIPPAGE_WAD = 0.001e18;

    /// @dev 30 minutes, same window as the v3 suites.
    uint32 internal constant REF_WINDOW = 1800;

    /// @dev `Transfer(address,address,uint256)`.
    bytes32 internal constant TRANSFER_TOPIC = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @dev Found by sweeping: enough USDT into the route venue to push the residual's realised
    /// price well past the 25bp sizing margin, while leaving the pool able to trade.
    uint256 internal constant ROUTE_DRAIN = 3_000e6;

    uint256 internal constant PARKED_USDC = 2_000e6;
    uint256 internal constant PARKED_USDT = 2_000e6;

    address internal maker = makeAddr("maker");
    V3TwapRef internal priceRef;
    Market internal market;

    PoolKey internal poolKey;
    int24 internal tickLower;
    int24 internal tickUpper;

    function setUp() public virtual override {
        super.setUp();

        priceRef = new V3TwapRef(POOL_USDC_USDT_100, REF_WINDOW);
        poolKey = usdcUsdtKey();

        (, int24 tick,,) = IPoolManager(V4_POOL_MANAGER).getSlot0(poolKey.toId());
        tickLower = ((tick - 50) / poolKey.tickSpacing) * poolKey.tickSpacing;
        tickUpper = ((tick + 50) / poolKey.tickSpacing) * poolKey.tickSpacing;

        market.chainId = block.chainid;
        market.midnight = MIDNIGHT;
        market.loanToken = USDC;

        deal(USDC, maker, PARKED_USDC);
        deal(USDT, maker, PARKED_USDT);
    }

    /// @dev USDC sorts below native USDT, so USDC is currency0 and the residual is currency1 — the
    /// same orientation as the v3 fixture.
    function usdcUsdtKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: V4_USDC_USDT_FEE,
            tickSpacing: V4_USDC_USDT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev The thinner v4 pool on the same pair, used only as a route venue.
    function usdcUsdtRouteKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: V4_USDC_USDT_ROUTE_FEE,
            tickSpacing: V4_USDC_USDT_ROUTE_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Sells USDT into the route venue, taking most of its USDC with it, so the residual a
    /// callback is about to sell there fetches far less than the parked pool's spot says it should.
    /// Same direction the residual itself trades — the honest version of this is a taker moving the
    /// route venue and then taking.
    /// @param amountIn Tuned to the pool's depth at `FORK_BLOCK`: enough to push past the 25bp the
    /// sizing budgets for impact, while leaving the venue able to trade at all.
    function _drainRouteVenue(uint256 amountIn) internal {
        V4PoolPusher pusher = new V4PoolPusher(V4_POOL_MANAGER);
        deal(USDT, address(pusher), amountIn);
        pusher.sell(usdcUsdtRouteKey(), false, amountIn);
    }

    /// @dev The parked pool's active liquidity at the live tick — the book any residual sold here
    /// has to go through, and the denominator `SourcingMathLib.MAX_ACTIVE_SHARE_WAD` caps against.
    function _activeLiquidity() internal view returns (uint128) {
        return IPoolManager(V4_POOL_MANAGER).getLiquidity(poolKey.toId());
    }

    /// @dev Largest liquidity the two amounts can fund over the parked range, the way a position
    /// manager would compute it. In range, so both sides bind and the smaller one wins.
    function _liquidityFor(uint256 amount0, uint256 amount1) internal view returns (uint128) {
        (uint160 sqrtPriceX96,,,) = IPoolManager(V4_POOL_MANAGER).getSlot0(poolKey.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 liquidity0 = (amount0 * ((uint256(sqrtPriceX96) * upper) / (1 << 96))) / (upper - sqrtPriceX96);
        uint256 liquidity1 = (amount1 * (1 << 96)) / (sqrtPriceX96 - lower);

        return uint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1);
    }

    /// @dev How many times the residual token actually moved to or from `who` since
    /// `vm.recordLogs()`. This is the netting claim made measurable: the custodial adapter sells
    /// the residual as a delta and never touches it, so this is zero; the NFT adapter has it handed
    /// over by `TAKE_PAIR` and pays it back in, so this is two.
    function _residualTransfersTouching(address who) internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 target = bytes32(uint256(uint160(who)));

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != USDT || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            if (logs[i].topics[1] == target || logs[i].topics[2] == target) ++count;
        }
    }

    /// @dev v4's `PositionManager` pulls payment through Permit2, so funding a mint is a two-step
    /// approval rather than the single ERC-20 approval v3 needs. See `FRICTION.log`.
    function _approveThroughPermit2(address spender) internal {
        IERC20Meta(USDC).approve(PERMIT2, type(uint256).max);
        IERC20Meta(USDT).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(USDC, spender, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(USDT, spender, type(uint160).max, type(uint48).max);
    }
}
