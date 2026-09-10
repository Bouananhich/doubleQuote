// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IMidnight, Market, Offer, CollateralParams} from "midnight/src/interfaces/IMidnight.sol";
import {MAX_TICK} from "midnight/src/libraries/TickLib.sol";
import {DummyRatifier} from "midnight/test/helpers/DummyRatifier.sol";
import {Oracle} from "midnight/test/helpers/Oracle.sol";

import {ParkedPositionBase} from "./ParkedPositionBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice A real market on the **deployed Midnight on Base**, over the parked v3 position, with a
/// taker funded and authorised to fill the maker's offer.
///
/// @dev Split out of `MidnightIntegration.t.sol` on D7, when the griefing suite needed the same
/// harness. The two suites ask different questions of one setup — does a take settle at all, and
/// what does a take cost the maker when someone moves the route venue first — so the setup belongs
/// here rather than being copied into the second one.
///
/// @dev What the fork dictates, all verified at `FORK_BLOCK` rather than assumed, and asserted in
/// `MidnightIntegrationTest`:
///   - **Tick spacing is not settable.** `tickSpacingSetter` is `address(0)`, so the market keeps
///     `DEFAULT_TICK_SPACING` (4) and the offer's tick must divide by it. `MAX_TICK` (6744) does.
///   - **USDC carries no fees**, so `buyerAssets == sellerAssets` and a take moves exactly the loan.
///   - **LLTV `0.77e18` and liquidation cursor `0.3e18` are enabled**; `0.5e18` and `1e18` are not.
abstract contract MidnightMarketBase is ParkedPositionBase {
    /// @dev Both enabled at `FORK_BLOCK`, asserted in `MidnightIntegrationTest`.
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    /// @dev cbBTC has 8 decimals against USDC's 6, so one cbBTC unit is 1e-8 BTC. Priced at
    /// $100k/BTC that is 1e3 USDC units, and Morpho-style oracles scale by `ORACLE_PRICE_SCALE`
    /// (1e36) — hence 1e39. A stub, because the collateral leg is not what these suites test.
    uint256 internal constant CBBTC_PRICE = 1e39;

    address internal taker = makeAddr("taker");

    IMidnight internal midnight = IMidnight(MIDNIGHT);
    DummyRatifier internal ratifier;
    Oracle internal oracle;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public virtual override {
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

    /// @dev The maker's offer. Buy side, so the maker is the lender and the callback sources the
    /// loan; `tick = MAX_TICK` prices units at par, which keeps the arithmetic legible.
    /// @dev `_offerFor` exists because a suite may run more than one callback over the same parked
    /// position — the griefing suite routes one through a venue an attacker can afford to move.
    function _offer(uint256 maxUnits) internal view returns (Offer memory offer) {
        return _offerFor(address(callback), maxUnits);
    }

    function _offerFor(address callbackAddress, uint256 maxUnits) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = maker;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = MAX_TICK;
        offer.callback = callbackAddress;
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

    function _takeFor(address callbackAddress, uint256 units) internal returns (uint256, uint256) {
        vm.prank(taker);
        return midnight.take(_offerFor(callbackAddress, units), hex"", units, taker, taker, address(0), hex"");
    }
}
