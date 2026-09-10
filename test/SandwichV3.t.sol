// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {IUniswapV3BuyCallback} from "../src/interfaces/IUniswapV3BuyCallback.sol";

import {MidnightMarketBase} from "./MidnightMarketBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";
import {PoolPusher} from "./mocks/PoolPusher.sol";
import {StubPriceRef} from "./mocks/StubPriceRef.sol";

/// @notice **D7's griefing test, D8's fix.** The same attack, the same venue, the same numbers —
/// and now it reverts.
///
/// @dev The attack is an ordinary sandwich, and the thing being sandwiched is not a trade the maker
/// chose to make. It is the residual swap that every unwind drags behind it: the position pays out
/// in two tokens, only one of them settles the loan, and the other has to be sold. The maker does
/// not pick the moment, the size, or the venue of that sale — the taker picks the moment by taking,
/// the fill size picks the size, and `ROUTE_POOL` is fixed at deployment. That is a swap with a
/// publicly predictable trigger, which is the definition of a sandwichable one.
///
/// @dev **What D7 measured, and what D8 does about it.** Unprotected, the sandwich took 3,092.76
/// USDC out of a 5,000 fill — 61.86% — because `onBuy` must deliver the shortfall or revert, so a
/// residual that fetched less did not settle for less, it burnt more of the maker's position until
/// the loan was covered. D8 gives `onBuy` a third option: refuse. The unwind's cost is measured
/// against `PRICE_REF` and checked against `MAX_SLIPPAGE_WAD`, and the attacked settlement now
/// fails closed at **44.60% against a 1bp... against the maker's 10bp budget**.
///
/// @dev **The guard is on realised cost, not on spot, and D7 is why.** The front-run displaces the
/// route pool's spot by 7.70bp — *inside* the maker's 10bp budget. A guard comparing `slot0` to the
/// reference would wave this straight through. What it costs is only visible in what the swap
/// actually returned, which is where the check sits. See `SourcingMathLib.costWad`.
///
/// @dev **What D8 does not fix**, and `test_aQuoteGoesStaleTheMomentTheRouteVenueMoves` keeps
/// saying so: an attacker who never takes can still move the route venue and strand a quote read a
/// block earlier. No bound computed at block N can promise anything about block N+1. A price
/// reference stops the maker being *robbed* between quote and block, not being *stalled*.
///
/// @dev Every number here is measured at `FORK_BLOCK` against the deployed Midnight, and pinned.
contract SandwichV3Test is MidnightMarketBase {
    /// @dev 10bp. Wide enough that the thin route venue quotes a fill worth attacking — at the 1bp
    /// the rest of the suite uses, the 0.05% route fee alone exceeds the budget and the honest
    /// bound is zero at every size. See `test_aRouteFeeAboveTheBudgetQuotesNothingAtAnySize`.
    uint256 internal constant BUDGET_WAD = 0.001e18;

    /// @dev The fill under attack. Comfortably inside the honest bound on the thin venue, so the
    /// baseline take settles without escalating and the comparison is against a clean unwind.
    uint256 internal constant FILL = 5_000e6;

    /// @dev What the attacker pushes through the route venue ahead of the take. Tuned at
    /// `FORK_BLOCK`: large enough to move the 0.05% pool well past the 25bp the burn sizing budgets
    /// for impact, small enough that the position can still escalate its way to a settled fill —
    /// an attack that reverts the take is the *other* harm, and it has its own test below.
    uint256 internal constant FRONT_RUN = 3_000e6;

    /// @dev What it takes to knock the *whole* quote out rather than to profit from a fill.
    /// Bisected at `FORK_BLOCK`: 3,000 USDT still leaves the bound fillable, 6,000 does not.
    uint256 internal constant DENIAL_PUSH = 6_000e6;

    /// @dev The pusher needs loan token on hand to pay for the exact-output back-run. A float, not
    /// a position: it is netted out of the profit measurement.
    uint256 internal constant ATTACKER_FLOAT = 100_000e6;

    UniswapV3BuyCallback internal routed;
    /// @dev The same callback with its guard neutralised: a stub reference pricing the residual at
    /// a quarter of its worth, so the modelled cost is zero at any drift. This is the D7 callback,
    /// kept alive purely so `test_spotStaysInsideTheBudgetWhileTheRealisedPriceDoesNot` can still
    /// observe what a sandwiched settlement executes at. Nothing in this suite lets it settle a
    /// fill that the guarded one would refuse *and* calls that acceptable.
    UniswapV3BuyCallback internal unguarded;
    PoolPusher internal attacker;

    function setUp() public override {
        super.setUp();

        routed = _routedCallback(BUDGET_WAD, POOL_USDC_USDT_500, 7);
        unguarded = UniswapV3BuyCallback(
            factory.createCallback(
                maker,
                new StubPriceRef(158_456_325_028_528_675_187_087_900_672),
                BUDGET_WAD,
                POOL_USDC_USDT_500,
                bytes32(uint256(8))
            )
        );
        _approve(routed);

        attacker = new PoolPusher();
        deal(USDT, address(attacker), FRONT_RUN);
        deal(USDC, address(attacker), ATTACKER_FLOAT);
    }

    /// HELPERS ///

    /// @dev USDC is token0 and USDT token1 in both USDC/USDT pools, so the callback sells token1
    /// for token0 and the attacker's front-run has to travel the same way to hurt: dump USDT so
    /// USDT is cheap when the callback sells its own.
    function _frontRun() internal {
        attacker.sell(POOL_USDC_USDT_500, false, FRONT_RUN);
    }

    /// @dev Buys back exactly the USDT the front-run sold, paying USDC. The attacker therefore ends
    /// holding the USDT it started with, and its entire profit is the USDC delta.
    function _backRun() internal {
        attacker.buy(POOL_USDC_USDT_500, true, FRONT_RUN);
    }

    function _attackerProfit() internal view returns (int256) {
        assertEq(IERC20Meta(USDT).balanceOf(address(attacker)), FRONT_RUN, "attacker did not unwind its own position");
        return int256(IERC20Meta(USDC).balanceOf(address(attacker))) - int256(ATTACKER_FLOAT);
    }

    /// @dev Everything the maker's side of a refused take must leave untouched: the position, the
    /// buffer, and the NFT. Asserted directly rather than valued, because a take that reverts should
    /// move nothing at all — "worth about the same" would be a weaker claim than the truth.
    function _assertMakerUntouched(uint128 liquidityBefore, uint256 bufferBefore) internal view {
        assertEq(_liquidity(), liquidityBefore, "a refused take moved the position");
        assertEq(IERC20Meta(USDC).balanceOf(address(routed)), bufferBefore, "a refused take spent the buffer");
        assertEq(IERC20Meta(USDT).balanceOf(address(routed)), 0, "a refused take left residual behind");
        assertEq(INonfungiblePositionManager(V3_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
    }

    /// @dev Takes, and reports the price the callback's residual sale actually got — token1 per
    /// token0 as a WAD, measured off the route pool's own token balances across the take.
    ///
    /// @dev Balances rather than events, and aggregate rather than per-swap, both on purpose: a
    /// take that escalates hits the route venue twice, and what the maker loses is the blended
    /// price over the whole residual. Nothing else moves this pool's balances during a take — the
    /// position is parked in a different pool, and Midnight pulls the loan from the callback.
    function _takeAndMeasureRealised(address cb, uint256 units) internal returns (uint256) {
        uint256 usdcBefore = IERC20Meta(USDC).balanceOf(POOL_USDC_USDT_500);
        uint256 usdtBefore = IERC20Meta(USDT).balanceOf(POOL_USDC_USDT_500);

        _takeFor(cb, units);

        uint256 usdtIn = IERC20Meta(USDT).balanceOf(POOL_USDC_USDT_500) - usdtBefore;
        uint256 usdcOut = usdcBefore - IERC20Meta(USDC).balanceOf(POOL_USDC_USDT_500);
        assertGt(usdtIn, 0, "the callback sold no residual on the route venue");

        return FullMath.mulDiv(usdcOut, 1e18, usdtIn);
    }

    /// @dev A pool's spot price in the residual's orientation: USDC (token0) per USDT (token1), as
    /// a WAD. Both tokens are 6-decimal, so a healthy USDC/USDT pool reads near `1e18`.
    ///
    /// @dev `slot0` gives token1 per token0, which is the reciprocal of what the callback is about
    /// to realise, so it is inverted here. Both venues are read through this one function precisely
    /// so the inversion cannot be applied to one side of a comparison and not the other.
    function _priceOfResidual(address pool) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 token1PerToken0 = FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), 1e18, 1 << 96);
        return FullMath.mulDiv(1e18, 1e18, token1PerToken0);
    }

    /// THE DELIVERABLE ///

    /// @dev **The fix, stated in both directions on one callback.** The honest fill of the same
    /// size, on the same venue, still settles — and the sandwiched one reverts. Either assertion
    /// alone is worthless: a guard that refuses everything passes the second, and a guard that
    /// refuses nothing passes the first.
    ///
    /// @dev The maker keeps everything. No liquidity burnt, no credit, no debt, the NFT untouched —
    /// against D7, where the same transaction cost them 3,092.76 USDC of a 5,000 fill.
    function test_theSandwichNowFailsClosedAndTheMakerKeepsEverything() public {
        _collateralize(FILL);

        uint128 liquidityBefore = _liquidity();
        uint256 bufferBefore = IERC20Meta(USDC).balanceOf(address(routed));

        // The honest fill settles. Without this the revert below proves nothing.
        uint256 snapshot = vm.snapshotState();
        _takeFor(address(routed), FILL);
        assertEq(IERC20Meta(USDC).balanceOf(taker), FILL, "an unattacked fill was refused");
        assertLt(_liquidity(), liquidityBefore, "the honest fill did not draw on the position");
        vm.revertToState(snapshot);

        // The sandwiched one does not. 44.60% against the maker's 10bp — pinned, because this is
        // the number D7 measured the maker paying and D8 exists to refuse.
        _frontRun();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMidnightBuyCallback.SourcingCostAboveBudget.selector, 446_045_019_709_500_009, BUDGET_WAD
            )
        );
        vm.prank(taker);
        midnight.take(_offerFor(address(routed), FILL), hex"", FILL, taker, taker, address(0), hex"");
        _backRun();

        _assertMakerUntouched(liquidityBefore, bufferBefore);
        assertEq(midnight.debt(marketId, taker), 0, "a refused take created debt");
        assertEq(midnight.credit(marketId, maker), 0, "a refused take created credit");

        // And the attacker is out of pocket: they moved the pool, paid the round trip, and the
        // settlement they were positioning against never happened.
        int256 profit = _attackerProfit();
        emit log_named_int("attacker profit against a guarded callback (USDC)", profit);
        assertLt(profit, int256(0), "the sandwich still paid");
    }

    /// @dev **The quote is reference-relative too, and this is the test that says so.** D8 moved
    /// `sourcedFor` from valuing the residual at the route venue's spot to valuing it at
    /// `PRICE_REF`. On a quiet fork the two are within a basis point of each other, so nothing in
    /// the suite noticed the difference — a mutation swapping them back failed exactly one
    /// assertion, by 0.9%. This is the case where they genuinely disagree.
    ///
    /// @dev Front-run the route venue and read the bound *afterwards*. Valued at the reference, the
    /// residual is still worth what it was worth and the moved venue plainly cannot pay that, so the
    /// quote collapses — the callback tells a routing layer the truth about what it will settle.
    /// Valued at the moved venue's own spot, the manipulation prices itself in as if it were the
    /// market, the cost looks ordinary and the quote barely moves. That is the failure mode D7
    /// found in execution, and it lives in the quote as well.
    function test_theQuoteCollapsesWhenTheRouteVenueMovesAwayFromTheReference() public {
        uint256 before = routed.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        assertGt(before, 9_000e6, "the venue does not quote enough for this test to mean anything");

        _frontRun();

        uint256 after_ = routed.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        emit log_named_uint("bound before the front-run (USDC)", before);
        emit log_named_uint("bound after the front-run (USDC)", after_);

        // Measured at `FORK_BLOCK`: 9,817.764107 before, 3,872.312997 after — the quote gives up
        // 60.6% of its size the moment the venue it routes through stops being able to pay
        // reference value. More than halving is the assertion rather than the exact pair, because
        // what matters is that it is a collapse and not a trim; a quote that shrugged this off
        // would still be promising fills the guard refuses, which is the inconsistency D8 removes.
        assertLt(after_ * 2, before, "the quote barely moved when the route venue did");
    }

    /// @dev The other harm, and the cheaper one: the attacker never takes the offer at all, just
    /// moves the route venue. A quote read one block earlier is now unfillable, and the maker's
    /// offer is dead until someone arbitrages the pool back.
    ///
    /// @dev **Bisected at `FORK_BLOCK`: 3,000 USDT leaves the 9,838.85 bound fillable and 6,000
    /// does not.** The cost of holding it there is logged below — it is the round-trip fee and
    /// impact on the push, because the attacker's inventory comes back. That number is the honest
    /// price of censoring this maker's offer for a block.
    ///
    /// @dev The failure itself is clean — `InsufficientSourced`, nothing moved, no debt, no credit,
    /// the position intact. It is a denial of service on the offer rather than a theft from the
    /// position, and **D8 does not fix it**, because no bound computed at block N can promise
    /// anything about block N+1. It is here so the D8 claim stays honest about what it covers: a
    /// price reference stops the maker being *robbed* between quote and block, not being *stalled*.
    function test_aQuoteGoesStaleTheMomentTheRouteVenueMoves() public {
        uint256 bound = routed.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        assertGt(bound, FILL, "the thin venue does not quote enough for this test to mean anything");

        _collateralize(bound);
        uint128 liquidityBefore = _liquidity();

        PoolPusher censor = new PoolPusher();
        deal(USDT, address(censor), DENIAL_PUSH);
        deal(USDC, address(censor), ATTACKER_FLOAT);
        censor.sell(POOL_USDC_USDT_500, false, DENIAL_PUSH);

        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(taker);
        midnight.take(_offerFor(address(routed), bound), hex"", bound, taker, taker, address(0), hex"");

        censor.buy(POOL_USDC_USDT_500, true, DENIAL_PUSH);
        assertEq(IERC20Meta(USDT).balanceOf(address(censor)), DENIAL_PUSH, "censor did not unwind");
        int256 cost = int256(IERC20Meta(USDC).balanceOf(address(censor))) - int256(ATTACKER_FLOAT);

        emit log_named_uint("bound that went stale (USDC)", bound);
        emit log_named_int("cost of denying it for a block (USDC)", cost);

        assertLt(cost, int256(0), "censoring the offer was free or profitable");
        assertEq(_liquidity(), liquidityBefore, "a failed take moved the position");
        assertEq(midnight.debt(marketId, taker), 0, "a failed take created debt");
        assertEq(midnight.credit(marketId, maker), 0, "a failed take created credit");
    }

    /// @dev The same attack against a callback that routes through the deep 0.01% pool it is parked
    /// in. Moving a venue ~50x thicker costs the attacker more in fees and impact than the take is
    /// worth, so the sandwich loses money.
    ///
    /// @dev This is the finding a maker can act on. The exposure is not inherent to parking in
    /// Uniswap — it is a property of the route venue's depth relative to the fill, and `ROUTE_POOL`
    /// is an immutable the maker chooses at deployment.
    function test_theSandwichIsUneconomicOnTheDeepVenue() public {
        _collateralize(FILL);

        PoolPusher deepAttacker = new PoolPusher();
        deal(USDT, address(deepAttacker), FRONT_RUN);
        deal(USDC, address(deepAttacker), ATTACKER_FLOAT);

        // Approval is a single slot per `tokenId`, and `setUp` pointed it at `routed`.
        _approve(callback);

        deepAttacker.sell(POOL_USDC_USDT_100, false, FRONT_RUN);
        _take(FILL); // `callback`, from the shared fixture, routes through the parked 0.01% pool.
        deepAttacker.buy(POOL_USDC_USDT_100, true, FRONT_RUN);

        assertEq(IERC20Meta(USDT).balanceOf(address(deepAttacker)), FRONT_RUN, "attacker did not unwind");
        int256 profit = int256(IERC20Meta(USDC).balanceOf(address(deepAttacker))) - int256(ATTACKER_FLOAT);

        emit log_named_int("attacker profit on the deep venue (USDC)", profit);
        assertLt(profit, int256(0), "the sandwich paid on the deep venue too");
    }

    /// @dev **The measurement that chose D8's design**, kept as a standing test because it is the
    /// reason the guard is not where it would naturally have been put.
    ///
    /// @dev Spot and realised price disagree completely here. The front-run moves the route pool's
    /// spot by 7.70bp, comfortably inside the maker's 10bp budget — so a guard comparing `slot0`
    /// against the reference sees nothing wrong. The price the residual actually realises deviates
    /// by 61.34%, because the front-run ate the book the residual then had to walk and the residual
    /// was over-sized by the escalation. The guard reads the second number, so it refuses.
    function test_spotStaysInsideTheBudgetWhileTheRealisedPriceDoesNot() public {
        _collateralize(FILL);

        // Everything below is in the residual's own orientation — USDC received per USDT sold —
        // because that is the direction the callback trades and therefore the direction a slippage
        // budget has to be applied in. `slot0` speaks the other one, token1 per token0, so the
        // reference and the spot are both inverted here rather than the realised price being
        // flipped to meet them. Getting this backwards makes an honest fill look like a 22bp breach.
        uint256 refPrice = _priceOfResidual(POOL_USDC_USDT_100);

        uint256 snapshot = vm.snapshotState();
        uint256 honestRealised = _takeAndMeasureRealised(address(routed), FILL);
        vm.revertToState(snapshot);

        // The attacked realised price has to be measured against an *unguarded* callback, because
        // the guarded one refuses to produce it — which is the entire point of the day's work.
        // Approval is one slot per `tokenId`, so it has to move across.
        _approve(unguarded);
        _frontRun();
        uint256 spotAfterFrontRun = _priceOfResidual(POOL_USDC_USDT_500);
        uint256 attackedRealised = _takeAndMeasureRealised(address(unguarded), FILL);

        uint256 spotDeviation = FullMath.mulDiv(refPrice - spotAfterFrontRun, 1e18, refPrice);
        uint256 honestDeviation = FullMath.mulDiv(refPrice - honestRealised, 1e18, refPrice);
        uint256 attackedDeviation = FullMath.mulDiv(refPrice - attackedRealised, 1e18, refPrice);

        emit log_named_uint("reference, USDC per USDT (WAD)", refPrice);
        emit log_named_uint("displacement of spot alone (WAD)", spotDeviation);
        emit log_named_uint("realised deviation, honest (WAD)", honestDeviation);
        emit log_named_uint("realised deviation, attacked (WAD)", attackedDeviation);
        emit log_named_uint("budget (WAD)", BUDGET_WAD);

        // Spot alone would not have caught this: the front-run displaces the pool by less than the
        // maker's whole budget. A guard comparing `slot0` to the reference waves the attack through.
        assertLt(spotDeviation, BUDGET_WAD, "the front-run breached the budget on spot after all");

        // The realised price is two orders of magnitude past it.
        assertGt(attackedDeviation, BUDGET_WAD * 100, "the attacked fill did not breach the budget");

        // And the honest unwind's residual leg sits between them, which is why the budget has to be
        // applied over what the unwind sourced rather than over this leg alone — see
        // `SourcingMathLib.costWad`.
        assertLt(honestDeviation, attackedDeviation, "the honest fill realised worse than the attacked one");
    }
}
