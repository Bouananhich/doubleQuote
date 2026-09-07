// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IMidnight, Market, Offer, CollateralParams} from "midnight/src/interfaces/IMidnight.sol";
import {MAX_TICK} from "midnight/src/libraries/TickLib.sol";
import {DummyRatifier} from "midnight/test/helpers/DummyRatifier.sol";
import {Oracle} from "midnight/test/helpers/Oracle.sol";

import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";
import {IUniswapV3BuyCallback} from "../src/interfaces/IUniswapV3BuyCallback.sol";

import {ParkedPositionBase} from "./ParkedPositionBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice The whole thesis in one transaction: a maker's capital sits in a Uniswap v3 LP position,
/// a taker fills a fixed-rate offer against **the real Midnight deployment on Base**, and the
/// position unwinds just far enough to settle it — atomically, on the taker's gas.
///
/// @dev This is the suite deferred from D1. Everything before it drove `onBuy` by pranking
/// `MIDNIGHT`, which proves the callback does the right thing when called correctly but proves
/// nothing about whether Midnight calls it that way, or whether what it hands back satisfies the
/// protocol. `take()` pulls `buyerAssets` out of the callback by `transferFrom` after `onBuy`
/// returns, so an approval that is short by one wei fails here and nowhere else.
///
/// @dev Forked in spirit from `BlueBuyCallbackIntegrationTest` in `morpho-org/midnight`, but not
/// in mechanism. Upstream deploys its own Midnight and its own Blue with `deployCode`; this binds
/// the deployed one at `FORK_BLOCK` through `IMidnight` and has to live with whatever the
/// configurator has actually enabled — which is the point of testing against it.
///
/// @dev What the fork dictates, all verified at `FORK_BLOCK` rather than assumed:
///   - **Tick spacing is not settable.** `tickSpacingSetter` is `address(0)`, so nothing can call
///     `setMarketTickSpacing`, and the market keeps `DEFAULT_TICK_SPACING` (4). `MAX_TICK` (6744)
///     is a multiple of 4, so the offer's tick is reachable — upstream's `setMarketTickSpacing(id,
///     1)` has no equivalent here and no need for one.
///   - **USDC carries no fees.** Every `defaultSettlementFeeCbp` and the `defaultContinuousFee`
///     read zero, so `buyerAssets == sellerAssets` and a take moves exactly the loan. Asserted
///     below rather than assumed, since a governance action could change it under a later fork
///     block.
///   - **LLTV `0.77e18` and liquidation cursor `0.3e18` are enabled**; `0.5e18` and `1e18` cursors
///     are not. The market has to be built from what is enabled, not from what is convenient.
contract MidnightIntegrationTest is ParkedPositionBase {
    /// @dev Both enabled at `FORK_BLOCK`, and asserted so in `test_theMarketUsesEnabledParameters`.
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    /// @dev cbBTC has 8 decimals against USDC's 6, so one cbBTC unit is 1e-8 BTC. Priced at
    /// $100k/BTC that is 1e3 USDC units, and Morpho-style oracles scale by `ORACLE_PRICE_SCALE`
    /// (1e36) — hence 1e39. A stub, because the collateral leg is not what this suite is testing.
    uint256 internal constant CBBTC_PRICE = 1e39;

    address internal taker = makeAddr("taker");

    IMidnight internal midnight = IMidnight(MIDNIGHT);
    DummyRatifier internal ratifier;
    Oracle internal oracle;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public override {
        super.setUp();

        ratifier = new DummyRatifier();
        oracle = new Oracle();
        oracle.setPrice(CBBTC_PRICE);

        market.chainId = block.chainid;
        market.midnight = MIDNIGHT;
        market.loanToken = USDC;
        market.maturity = block.timestamp + 30 days;
        market.collateralParams
            .push(
                CollateralParams({
                    token: CBBTC, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
                })
            );
        marketId = midnight.touchMarket(market);

        // The maker's one on-chain act besides approving the NFT: letting the ratifier speak for
        // them. Everything else about the offer is signed, not stored.
        vm.prank(maker);
        midnight.setIsAuthorized(address(ratifier), true, maker);
    }

    /// HELPERS ///

    /// @dev The maker's offer. Buy side, so the maker is the lender and the callback sources the
    /// loan; `tick = MAX_TICK` prices units at par, which keeps the arithmetic legible.
    function _offer(uint256 maxUnits) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = maker;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = MAX_TICK;
        offer.callback = address(callback);
        offer.callbackData = _callbackData();
        offer.ratifier = address(ratifier);
        offer.maxUnits = uint128(maxUnits);
        offer.continuousFeeCap = type(uint256).max;
    }

    /// @dev Collateralises the taker at twice what the LLTV strictly demands, so the health check
    /// at the end of `take` is never the thing under test.
    function _collateralize(uint256 debt) internal {
        uint256 required = (debt * 1e18 / LLTV) * 1e36 / CBBTC_PRICE;
        uint256 collateral = required * 2;

        deal(CBBTC, taker, collateral);
        vm.startPrank(taker);
        IERC20Meta(CBBTC).approve(MIDNIGHT, collateral);
        midnight.supplyCollateral(market, 0, collateral, taker);
        vm.stopPrank();
    }

    function _take(uint256 units) internal returns (uint256 buyerAssets, uint256 sellerAssets) {
        vm.prank(taker);
        return midnight.take(_offer(units), hex"", units, taker, taker, address(0), hex"");
    }

    /// THE DELIVERABLE ///

    /// @dev Park, offer, take, settle. The maker never moves the capital out of Uniswap to make
    /// the offer and never touches the transaction that fills it.
    function test_aTakeSourcesTheLoanFromTheParkedPosition() public {
        uint256 units = 5_000e6;
        _collateralize(units);

        uint128 liquidityBefore = _liquidity();
        assertEq(IERC20Meta(USDC).balanceOf(taker), 0, "taker starts with no loan token");

        (uint256 buyerAssets, uint256 sellerAssets) = _take(units);

        // Par pricing, and USDC carries no settlement fee at this block, so the whole thing moves.
        assertEq(buyerAssets, units, "buyer assets should be at par");
        assertEq(sellerAssets, units, "a fee appeared between buyer and seller");
        assertEq(IERC20Meta(USDC).balanceOf(taker), units, "taker did not receive the loan");

        // Midnight's own books.
        assertEq(midnight.credit(marketId, maker), units, "maker has no credit");
        assertEq(midnight.debt(marketId, taker), units, "taker has no debt");

        // And the Uniswap side: a slice of the position, not the position.
        assertLt(_liquidity(), liquidityBefore, "position was not drawn on");
        assertGt(_liquidity(), (uint256(liquidityBefore) * 6) / 10, "a 25% fill took more than 40%");
        assertEq(INonfungiblePositionManager(V3_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
    }

    /// @dev The surplus from an over-sized burn does not go back to the maker or sit as residual —
    /// it stays on the callback as loan token, which is exactly the buffer the next fill spends
    /// before it touches the LP again.
    function test_theSurplusFromSettlementBecomesBuffer() public {
        uint256 units = 5_000e6;
        _collateralize(units);

        _take(units);

        assertGt(IERC20Meta(USDC).balanceOf(address(callback)), 0, "no buffer left behind");
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "residual was not swapped out");
    }

    /// @dev Two takes against the same offer. The second is small enough to come out of the buffer
    /// the first one left, so it never reaches Uniswap — the dust-take defence, but driven through
    /// Midnight rather than by calling `onBuy` directly.
    function test_aSecondTakeIsServedFromTheBuffer() public {
        _collateralize(5_500e6);

        vm.prank(taker);
        midnight.take(_offer(5_500e6), hex"", 5_000e6, taker, taker, address(0), hex"");

        uint128 liquidityAfterFirst = _liquidity();
        uint256 buffer = IERC20Meta(USDC).balanceOf(address(callback));
        assertGt(buffer, 10e6, "first take left too little buffer for this test to mean anything");

        vm.prank(taker);
        midnight.take(_offer(5_500e6), hex"", 10e6, taker, taker, address(0), hex"");

        assertEq(_liquidity(), liquidityAfterFirst, "second take reached the position");
        assertEq(IERC20Meta(USDC).balanceOf(taker), 5_010e6, "taker did not receive both loans");
        assertEq(midnight.debt(marketId, taker), 5_010e6, "debt does not cover both takes");
    }

    /// @dev Fails closed through the whole stack. `InsufficientSourced` surfaces out of `take`
    /// rather than being swallowed into a partial settlement, and nothing moves: no debt, no
    /// credit, no liquidity.
    function test_aTakeBeyondThePositionRevertsAndChangesNothing() public {
        uint256 units = 50_000e6; // The position is worth ~19.9k.
        _collateralize(units);

        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(taker);
        midnight.take(_offer(units), hex"", units, taker, taker, address(0), hex"");

        assertEq(_liquidity(), liquidityBefore, "a failed take moved the position");
        assertEq(midnight.debt(marketId, taker), 0, "a failed take created debt");
        assertEq(midnight.credit(marketId, maker), 0, "a failed take created credit");
    }

    /// @dev What a taker's routing layer reads before deciding what to take, measured against what
    /// the offer will actually honour. The bound is naive today — position amounts at spot, no
    /// impact, no swap fee — so it over-promises, and this pins both the direction of the error and
    /// its size.
    ///
    /// @dev At `FORK_BLOCK` the bound reads 19,872.71 USDC against 19,871.46 the position can
    /// really source: **1.25 USDC, or 0.63bp**. Small, and small is the point — the naive bound is
    /// already close enough on a stable venue that D5's single-step version has very little to win
    /// here, and the case for it has to be made on the volatile venue instead. It is also the wrong
    /// side of correct: a taker who believes the bound gets a reverted transaction, not a bad fill.
    function test_theBoundOverPromisesAgainstWhatActuallySettles() public {
        uint256 bound = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        assertGt(bound, 19_000e6, "bound does not reflect a ~19.9k position");

        _collateralize(bound);

        // The bound itself cannot be filled. Fail closed rather than fill badly.
        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(taker);
        midnight.take(_offer(bound), hex"", bound, taker, taker, address(0), hex"");

        // One basis point under it does fill, which caps the over-promise at 1bp.
        uint256 achievable = (bound * 9999) / 10_000;
        vm.prank(taker);
        midnight.take(_offer(achievable), hex"", achievable, taker, taker, address(0), hex"");

        assertEq(IERC20Meta(USDC).balanceOf(taker), achievable, "taker did not receive the loan");
        assertEq(midnight.credit(marketId, maker), achievable, "maker has no credit");
    }

    /// FORK ASSUMPTIONS ///

    /// @dev The market is built out of what the configurator has actually enabled, and the offer's
    /// tick has to be reachable at the spacing the market was created with. Both are properties of
    /// the deployment, not of this repo, so they are asserted rather than assumed.
    function test_theMarketUsesEnabledParameters() public view {
        assertTrue(midnight.isLltvEnabled(LLTV), "LLTV not enabled");
        assertTrue(midnight.isLiquidationCursorEnabled(LIQUIDATION_CURSOR), "liquidation cursor not enabled");

        uint8 spacing = midnight.tickSpacing(marketId);
        assertGt(spacing, 0, "market was not created");
        assertEq(MAX_TICK % spacing, 0, "the offer's tick is not reachable at this spacing");
        assertEq(midnight.tickSpacingSetter(), address(0), "tick spacing is settable, so this market may drift");
    }

    /// @dev USDC carries no settlement or continuous fee at this block, which is why the take
    /// assertions can be exact equalities. If governance ever sets one, this fails first and says
    /// why, instead of the arithmetic failing somewhere less obvious.
    function test_usdcCarriesNoFeesAtThisBlock() public view {
        for (uint256 i; i < 7; ++i) {
            assertEq(midnight.defaultSettlementFeeCbp(USDC, i), 0, "a settlement fee is configured");
        }
        assertEq(midnight.defaultContinuousFee(USDC), 0, "a continuous fee is configured");
    }
}
