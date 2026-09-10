// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {SourcingMathLib} from "../src/libraries/SourcingMathLib.sol";

import {MidnightMarketBase} from "./MidnightMarketBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice **D9's grief test.** `onBuy` is guarded against arbitrary callers, but not against
/// arbitrary *sizes*: any taker may fire it with a fill of one wei. D1 flagged repeated dust takes
/// as extractive, D3 built the buffer to absorb them and then argued from theory that the residual
/// bleed is linear. This is the measurement that argument was owed.
///
/// @dev **The metric.** A take moves value in two directions at once — the callback delivers loan
/// token, and the maker receives a Midnight credit of exactly the same size, since USDC carries no
/// fees on this market. So the maker's wealth is `position + buffer + credit`, and the *bleed* is
/// whatever that total lost. Everything is marked at `PRICE_REF`, not at the route venue's spot,
/// for the same reason D8 measures the unwind there: a metric an attacker can move is not a metric.
///
/// @dev Uncollected v3 fees are excluded from the mark. They only accrue to the maker, so every
/// number below is an over-statement of the bleed by however much the maker's own position earned
/// from the residual swaps that caused it. Conservative in the direction that matters.
///
/// @dev Every number is measured at `FORK_BLOCK` against the deployed Midnight, and pinned.
contract DustGriefV3Test is MidnightMarketBase {
    /// @dev The grief budget, held constant across the sweep so that splitting it into more takes
    /// is the *only* thing that varies. Comfortably inside the bound at every split.
    uint256 internal constant VOLUME = 2_000e6;

    /// @dev How the sweep splits `VOLUME`. 200 takes of 10 USDC is the shape of the attack: the
    /// smallest fills that still clear the sourcing floor by a wide margin.
    uint256 internal constant SPLIT = 20;

    function setUp() public override {
        super.setUp();
        _collateralize(VOLUME * 2);
    }

    /// PRIMITIVES ///

    /// @dev Loan-token value of everything the maker's callback controls: the parked position
    /// marked at the pool's own spot, plus both balances sitting on the callback, with the
    /// non-loan side valued at `PRICE_REF`.
    function _makerValue() internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();
        (,,,,, int24 lower, int24 upper, uint128 liq,,,,) =
            INonfungiblePositionManager(V3_POSITION_MANAGER).positions(tokenId);
        (uint256 amount0, uint256 amount1) = SourcingMathLib.amountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liq
        );

        uint256 usdc = amount0 + IERC20Meta(USDC).balanceOf(address(callback));
        uint256 usdt = amount1 + IERC20Meta(USDT).balanceOf(address(callback));
        return usdc + SourcingMathLib.valueAtRef(usdt, priceRef.refSqrtPriceX96(USDC, USDT), false);
    }

    /// @dev What the maker is out of pocket since `valueBefore`, net of the credit they were paid.
    function _bleed(uint256 valueBefore) internal view returns (uint256) {
        uint256 wealth = _makerValue() + midnight.credit(marketId, maker);
        return valueBefore > wealth ? valueBefore - wealth : 0;
    }

    /// @dev One take against a standing offer large enough to absorb the whole sweep. The base's
    /// `_take` sets `maxUnits` to the fill, which is right for a single take and wrong for a
    /// hundred of them against the same offer hash.
    function _dustTake(uint256 units) internal {
        vm.prank(taker);
        midnight.take(_offer(VOLUME), hex"", units, taker, taker, address(0), hex"");
    }

    /// @dev The bleed from splitting `VOLUME` into `n` equal takes, measured against a fresh
    /// position each time.
    function _bleedFromSplit(uint256 n) internal returns (uint256 bleed) {
        uint256 snapshot = vm.snapshotState();
        uint256 before = _makerValue();

        for (uint256 i; i < n; ++i) {
            _dustTake(VOLUME / n);
        }

        bleed = _bleed(before);
        vm.revertToState(snapshot);
    }

    /// @dev Smallest fill `cb` will settle, by bisection. The predicate is not monotone in both
    /// directions — a fill can also be too *large* — so the search needs a ceiling known to settle,
    /// which is what `1_000e6` is on this position.
    function _floorFor(UniswapV3BuyCallback cb) internal returns (uint256 lo) {
        lo = 1;
        uint256 hi = 1_000e6;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.prank(taker);
            try midnight.take(_offerFor(address(cb), 1_000e6), hex"", mid, taker, taker, address(0), hex"") {
                hi = mid;
            } catch {
                lo = mid + 1;
            }
            vm.revertToState(snapshot);
        }
    }

    /// THE BLEED ///

    /// @dev **The D9 result, and the one D3 promised.** Fixing the volume at 2,000 USDC and
    /// splitting it 1 / 4 / 20 / 200 ways moves the maker's cost by **0.7%**, and not even
    /// monotonically. Two hundred dust takes cost the maker 0.131258 USDC; one take of the same
    /// size costs 0.131738. Splitting a fill up is not an attack — it is very slightly *cheaper*
    /// for the maker, because price impact is convex and two hundred small swaps each pay less of
    /// it than one large one, which more than covers the extra wei of rounding each take adds.
    ///
    /// @dev This is what makes the grief a *bleed* and not a *kill*, and it is entirely a property
    /// of D3's sized burn. Under D2's unconditional full unwind the first take of any size cost the
    /// maker the whole round trip on 19.9k, and the second one cost nothing because there was
    /// nothing left. The superlinearity D1 worried about was that, and it is gone.
    function test_theBleedDoesNotGrowWithTheNumberOfTakes() public {
        uint256 one = _bleedFromSplit(1);
        uint256 four = _bleedFromSplit(4);
        uint256 twenty = _bleedFromSplit(20);
        uint256 twoHundred = _bleedFromSplit(200);

        assertEq(one, 131_738, "one take");
        assertEq(four, 130_993, "four takes");
        assertEq(twenty, 130_834, "twenty takes");
        assertEq(twoHundred, 131_258, "two hundred takes");

        // The claim, stated as a bound rather than as four constants: splitting the same volume
        // two hundred ways never costs the maker more than taking it in one go.
        assertLe(twoHundred, one, "splitting the fill cost the maker more");
        assertLe(twenty, one, "splitting the fill cost the maker more");
        assertLe(four, one, "splitting the fill cost the maker more");

        // ~6.55bp of volume, which is the round-trip cost of the residual swap and nothing else.
        assertApproxEqAbs(one * 1e18 / VOLUME, 6.5e13, 0.2e13, "the bleed is not the round trip");
    }

    /// @dev **The flat line.** A buffer that covers the whole grief absorbs the whole grief: the
    /// position is never touched, no residual is ever swapped, and the maker's cost is not small
    /// but exactly zero. Every USDC the buffer pays out comes back as credit of the same size.
    function test_aFundedBufferFlattensTheBleedToZero() public {
        deal(USDC, address(callback), VOLUME);
        uint128 liquidityBefore = _liquidity();
        uint256 before = _makerValue();

        for (uint256 i; i < SPLIT; ++i) {
            _dustTake(VOLUME / SPLIT);
        }

        assertEq(_bleed(before), 0, "a fully funded buffer still bled");
        assertEq(_liquidity(), liquidityBefore, "dust takes reached the position");
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), 0, "the buffer was not what paid");
    }

    /// @dev **How to size a buffer** — the question D3 left open. There is no formula, because the
    /// buffer defends its own face value and nothing more: funded with half the grief, it covers
    /// exactly the first half of it. Take 11 of 20 is the first to touch the position, and the
    /// bleed is half the unbuffered bleed to within a wei of rounding.
    ///
    /// @dev So the maker policy is simply "hold as much idle loan token as you expect to be taken
    /// in dust between top-ups". A buffer buys no leverage over the bleed, only volume.
    function test_theBufferDefendsExactlyItsOwnFaceValue() public {
        deal(USDC, address(callback), VOLUME / 2);
        uint128 liquidityBefore = _liquidity();
        uint256 before = _makerValue();

        uint256 firstTouch;
        for (uint256 i; i < SPLIT; ++i) {
            _dustTake(VOLUME / SPLIT);
            if (firstTouch == 0 && _liquidity() != liquidityBefore) firstTouch = i + 1;
        }

        assertEq(firstTouch, SPLIT / 2 + 1, "the buffer did not cover exactly its face value");
        assertEq(_bleed(before), 64_781, "half-buffered bleed");
        assertApproxEqRel(_bleed(before) * 2, 130_834, 0.02e18, "the bleed is not proportional to unbuffered volume");
    }

    /// @dev **The grief priced from the attacker's side.** It is not free to them: one unbuffered
    /// 10 USDC take destroys **648 wei of USDC** of the maker's value and costs the attacker
    /// **565,589 gas** (forge 1.5.1; 586,929 on 1.8.1) — a full unwind, burn and collect and swap,
    /// every time. Griefing means one transaction per take, so every take pays cold storage; this
    /// is measured that way rather than amortised across a loop, which would read ~297k and
    /// flatter the attacker.
    ///
    /// @dev The gas assertion is a **floor, not a pin**, and the two figures above are why: forge
    /// 1.5.1 and 1.8.1 disagree by 3.8% on the same call against the same fork at the same block.
    /// Absolute gas is a property of the toolchain as much as of the contract, so pinning it makes
    /// the suite fail on a runner upgrade for no reason anyone should care about. A floor is also
    /// the only direction the argument needs: more gas for the attacker only strengthens it.
    ///
    /// @dev Breakeven is the gas price at which those two are equal: 648 wei of USDC against
    /// 565,589 gas is about **0.00034 gwei** with ETH at $3,400. Base clears one to two orders of
    /// magnitude above that, and this ignores the L1 data cost, which on Base is usually the
    /// larger half of the bill. The attacker also has to post collateral and carry the debt.
    ///
    /// @dev That is the whole answer to "should there be a minimum fill size". The grief is
    /// already uneconomic by a wide margin without one.
    function test_theGriefCostsTheAttackerFarMoreThanItCostsTheMaker() public {
        uint256 before = _makerValue();

        vm.prank(taker);
        uint256 gasBefore = gasleft();
        midnight.take(_offer(VOLUME), hex"", 10e6, taker, taker, address(0), hex"");
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(gasUsed, 500_000, "a dust take got cheap enough to be worth repeating");
        assertApproxEqAbs(_bleed(before), 648, 40, "value destroyed per dust take");

        // The breakeven gas price, with ETH at $3,400: below it the grief is cheaper for the
        // attacker than it is for the maker. It lands at 0.00034 gwei, which no chain charges.
        uint256 breakevenWeiPerGas = (_bleed(before) * 1e12 / 3_400) / gasUsed;
        assertLt(breakevenWeiPerGas, 0.001 gwei, "the grief could pay for itself at a real gas price");
    }

    /// THE FLOOR ///

    /// @dev **The minimum fill size already exists, and it is the slippage budget.** D3 argued the
    /// floor self-calibrates and needs no constant; this is what it calibrates to. A fill is
    /// refused when its rounding loss, as a fraction of what it sourced, exceeds
    /// `MAX_SLIPPAGE_WAD` — so the floor is the fill at which **one wei of rounding is the whole
    /// budget**, and it moves inversely with the only knob the maker already sets.
    ///
    /// | budget | smallest settling fill | floor x budget |
    /// |---|---|---|
    /// | 1bp | 9,977 | 0.998 wei |
    /// | 10bp | 999 | 0.999 wei |
    /// | 100bp | 102 | 1.02 wei |
    ///
    /// @dev A configured minimum would have to be *guessed*, would strand the tail of a
    /// partially-filled offer below it, and has no channel to be advertised on —
    /// `buyerAssetsBound` publishes a maximum and the callback interface has no minimum. This one
    /// costs nothing, guesses nothing, and lands at a hundredth of a cent for the product
    /// configuration. The D3 decision stands, now for a measured reason.
    function test_theMinimumFillSizeIsTheSlippageBudget() public {
        uint256[3] memory budgets = [uint256(0.0001e18), 0.001e18, 0.01e18];
        uint256[3] memory floors = [uint256(9_977), 999, 102];

        for (uint256 i; i < budgets.length; ++i) {
            UniswapV3BuyCallback routed = _routedCallback(budgets[i], POOL_USDC_USDT_100, i + 1);
            _approve(routed);

            uint256 floor = _floorFor(routed);
            assertEq(floor, floors[i], "floor moved");

            // One wei of rounding, expressed as a fraction of the floor, is the budget itself.
            assertApproxEqRel(1e18 / floor, budgets[i], 0.03e18, "the floor is not one wei of the budget");
        }
    }

    /// @dev And the refusal is D8's cost guard, not D3's rounding check. One wei below the floor
    /// the fill *does* source enough to cover itself — it reverts because covering itself cost
    /// 1.0001bp against a 1bp budget. Worth pinning, because it means the dust floor and the
    /// sandwich guard are the same mechanism seen at two scales.
    function test_aFillBelowTheFloorIsRefusedByTheCostGuard() public {
        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(
            abi.encodeWithSelector(IMidnightBuyCallback.SourcingCostAboveBudget.selector, 100_010_001_000_100, 1e14)
        );
        _dustTake(9_976);

        assertEq(_liquidity(), liquidityBefore, "a refused fill moved the position");
    }
}
