// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {IUniswapV3BuyCallback} from "../src/interfaces/IUniswapV3BuyCallback.sol";

import {MidnightMarketBase} from "./MidnightMarketBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";
import {PoolPusher} from "./mocks/PoolPusher.sol";

/// @notice **D7 — the griefing test.** What an attacker extracts from a maker whose callback swaps
/// its residual with no price protection at all.
///
/// @dev The attack is an ordinary sandwich, and the thing being sandwiched is not a trade the maker
/// chose to make. It is the residual swap that every unwind drags behind it: the position pays out
/// in two tokens, only one of them settles the loan, and the other has to be sold. The maker does
/// not pick the moment, the size, or the venue of that sale — the taker picks the moment by taking,
/// the fill size picks the size, and `ROUTE_POOL` is fixed at deployment. That is a swap with a
/// publicly predictable trigger, which is the definition of a sandwichable one.
///
/// @dev **What D6 already took away from the attacker.** Before the tick walk it was possible to
/// attack the *quote*: the single-step bound assumed active liquidity continued past the ticks the
/// swap actually crossed, so a thin route venue produced a bound that over-promised by 25.33%.
/// `buyerAssetsBound` now walks the real book, so a quote read at block N is honest about block N.
/// What is left is the gap between block N and the block the take lands in — and nothing in an
/// `external view` can defend that, because the attacker moves the pool after the view returned.
/// That gap is what this suite measures, and it is the case `PRICE_REF` exists for at D8.
///
/// @dev **The route venue is the 0.05% pool, and that choice is the attack's whole economics.**
/// Park and route are independently chosen (invariant 5), so a maker can and does end up routing
/// somewhere thinner than where the capital sits. `test_theSandwichIsUneconomicOnTheDeepVenue`
/// runs the identical attack through the 0.01% pool the position is parked in and shows it loses
/// money — the vulnerability is not "v3 callbacks can be sandwiched", it is "a callback routing
/// through a venue an attacker can afford to move can be sandwiched", which is a statement about
/// the maker's configuration and therefore something a maker can be told.
///
/// @dev Every number in this file is measured at `FORK_BLOCK` against the deployed Midnight, and
/// pinned. D8 re-runs the same scenarios with `PRICE_REF` wired in; the assertions there are the
/// mirror image of the ones here.
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
    PoolPusher internal attacker;

    function setUp() public override {
        super.setUp();

        routed = _routedCallback(BUDGET_WAD, POOL_USDC_USDT_500, 7);
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

    /// @dev What the maker is left holding, valued in USDC at par.
    ///
    /// @dev Measured by *actually* unwinding: the maker burns whatever liquidity survived the fill
    /// and collects, and the callback's buffer is added because it is the maker's too. Par is the
    /// valuation, and it is the conservative direction — the parked pool sits at tick 7, so a USDT
    /// unit is worth 1.0007 USDC there and par understates the residual leg by 7bp. That is two
    /// orders of magnitude below the loss being measured, and it applies identically to both sides
    /// of the comparison.
    ///
    /// @dev The park venue is the 0.01% pool and the attack happens in the 0.05% pool, so the price
    /// this unwind pays out at is the same in both branches. The comparison isolates the swap.
    function _makerEstate(UniswapV3BuyCallback cb) internal returns (uint256) {
        uint128 remaining = _liquidity();

        vm.startPrank(maker);
        if (remaining > 0) {
            INonfungiblePositionManager(V3_POSITION_MANAGER)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId, liquidity: remaining, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                    })
                );
        }
        INonfungiblePositionManager(V3_POSITION_MANAGER)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: maker, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
        vm.stopPrank();

        return IERC20Meta(USDC).balanceOf(maker) + IERC20Meta(USDT).balanceOf(maker)
            + IERC20Meta(USDC).balanceOf(address(cb)) + IERC20Meta(USDT).balanceOf(address(cb));
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

    /// @dev **The griefing test.** Front-run the route venue, let the take settle into the price
    /// that manufactured, back-run it. The taker gets the same loan in both branches and Midnight's
    /// books are identical, so everything the attacker walks away with came out of the maker's
    /// position.
    ///
    /// @dev The mechanism is worth stating plainly, because it is not "the maker sold at a bad
    /// price and ate the difference". `onBuy` must deliver `shortfall` or revert, so a residual that
    /// fetches less USDC does not settle for less — it burns *more liquidity* until the loan is
    /// covered. The maker pays the attacker in LP position, at a size the maker never authorised,
    /// and the escalation ceiling is what stops that from being the whole position.
    function test_aSandwichAroundTheTakeIsPaidForOutOfThePosition() public {
        _collateralize(FILL);

        uint128 liquidityBefore = _liquidity();
        uint256 snapshot = vm.snapshotState();

        // Branch A: nobody attacks.
        _takeFor(address(routed), FILL);
        uint256 honestBurn = liquidityBefore - _liquidity();
        uint256 honestEstate = _makerEstate(routed);
        vm.revertToState(snapshot);

        // Branch B: the same take, sandwiched.
        _frontRun();
        _takeFor(address(routed), FILL);
        _backRun();
        uint256 attackedBurn = liquidityBefore - _liquidity();
        uint256 attackedEstate = _makerEstate(routed);

        // The taker is indifferent — this is not a cost passed on to them.
        assertEq(IERC20Meta(USDC).balanceOf(taker), FILL, "taker did not receive the same loan");
        assertEq(midnight.credit(marketId, maker), FILL, "maker's credit differs between branches");

        int256 profit = _attackerProfit();
        uint256 loss = honestEstate - attackedEstate;

        emit log_named_uint("honest burn (liquidity)", honestBurn);
        emit log_named_uint("attacked burn (liquidity)", attackedBurn);
        emit log_named_uint("maker estate, honest (USDC)", honestEstate);
        emit log_named_uint("maker estate, attacked (USDC)", attackedEstate);
        emit log_named_uint("maker loss (USDC)", loss);
        emit log_named_int("attacker profit (USDC)", profit);

        assertGt(attackedBurn, honestBurn, "the sandwich did not cost the maker any extra liquidity");
        assertLt(attackedEstate, honestEstate, "the maker was not worse off");
        assertGt(profit, int256(0), "the attack did not pay");
        assertLe(uint256(profit), loss, "the attacker extracted more than the maker lost");
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

    /// @dev **The acceptance criterion for D8.** Not the pool's displaced spot — the price the
    /// residual sale *actually realised*, measured off the route pool's own balances across the
    /// take, honest branch against attacked branch.
    ///
    /// @dev The distinction matters and it was not obvious. The front-run moves the 0.05% pool's
    /// spot by only ~7.7bp, comfortably *inside* the maker's 10bp budget — so a guard that compared
    /// spot against the reference would wave this attack through. The damage is not displacement,
    /// it is that the front-run **eats the book the residual then has to walk**, and the residual
    /// itself is twice as large as it should have been because the shortfall forced an escalation.
    /// The realised price is the only number that sees all three effects at once, which is why D8's
    /// check belongs on execution and not on spot.
    ///
    /// @dev D8 replaces the last two assertions with their inverse: this take must revert rather
    /// than settle, and the deviation logged below is what it has to notice.
    function test_theResidualSellsFarOutsideTheBudgetAndTheCallbackDoesItAnyway() public {
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

        _frontRun();
        uint256 spotAfterFrontRun = _priceOfResidual(POOL_USDC_USDT_500);
        uint256 attackedRealised = _takeAndMeasureRealised(address(routed), FILL);

        uint256 spotDeviation = FullMath.mulDiv(refPrice - spotAfterFrontRun, 1e18, refPrice);
        uint256 honestDeviation = FullMath.mulDiv(refPrice - honestRealised, 1e18, refPrice);
        uint256 attackedDeviation = FullMath.mulDiv(refPrice - attackedRealised, 1e18, refPrice);

        emit log_named_uint("reference, USDC per USDT (WAD)", refPrice);
        emit log_named_uint("route spot after the front-run (WAD)", spotAfterFrontRun);
        emit log_named_uint("displacement of spot alone (WAD)", spotDeviation);
        emit log_named_uint("realised residual price, honest (WAD)", honestRealised);
        emit log_named_uint("realised residual price, attacked (WAD)", attackedRealised);
        emit log_named_uint("realised deviation, honest (WAD)", honestDeviation);
        emit log_named_uint("realised deviation, attacked (WAD)", attackedDeviation);
        emit log_named_uint("budget (WAD)", BUDGET_WAD);

        // The honest unwind lives inside the budget it was quoted under. That is D6 working, and
        // it is close — 8.13bp against a 10bp budget, so D8's guard has under 2bp of slack to play
        // with before it starts refusing fills that were fine.
        assertLt(honestDeviation, BUDGET_WAD, "an unattacked fill already breaches the budget");

        // Spot alone would not have caught this: the front-run displaces the pool by less than the
        // maker's whole budget. A guard comparing `slot0` to the reference waves the attack through.
        assertLt(spotDeviation, BUDGET_WAD, "the front-run breached the budget on spot after all");

        // The realised price is three orders of magnitude past it.
        assertGt(attackedDeviation, BUDGET_WAD * 100, "the attacked fill did not breach the budget");

        // And the callback sources into it regardless. These are the lines D8 inverts.
        assertEq(IERC20Meta(USDC).balanceOf(taker), FILL, "the take did not settle");
        assertEq(address(routed.PRICE_REF()), address(priceRef), "the reference is configured but unread");
    }
}
