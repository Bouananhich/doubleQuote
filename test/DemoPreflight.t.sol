// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";

import {Offer} from "midnight/src/interfaces/IMidnight.sol";

import {MidnightMarketBase} from "./MidnightMarketBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice **Pre-flight for the mainnet demo.** Every other suite parks 10,000 USDC + 10,000 USDT.
/// The demo parks **ten dollars a side**, and that is a different regime: the same rounding, the
/// same 25bp impact margin and the same dust floor now sit against a position three orders of
/// magnitude smaller.
///
/// @dev The point is to find out on a fork, for free, whether the demo works — before it is run on
/// mainnet with real money and a real counterparty. A demo that reverts in front of an audience
/// because nobody checked the small-size regime is an avoidable way to fail.
contract DemoPreflightTest is MidnightMarketBase {
    /// @dev What the demo actually funds. Ten dollars a side.
    uint256 internal constant DEMO_USDC = 10e6;
    uint256 internal constant DEMO_USDT = 10e6;

    UniswapV3BuyCallback internal demo;
    uint256 internal demoTokenId;

    function setUp() public override {
        super.setUp();

        demo = UniswapV3BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(uint256(99)))
        );

        demoTokenId = _mintSmallPosition();
        vm.prank(maker);
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(address(demo), demoTokenId);
    }

    function _mintSmallPosition() internal returns (uint256 id) {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();
        int24 spacing = IUniswapV3Pool(POOL_USDC_USDT_100).tickSpacing();

        deal(USDC, maker, DEMO_USDC);
        deal(USDT, maker, DEMO_USDT);

        vm.startPrank(maker);
        IERC20Meta(USDC).approve(V3_POSITION_MANAGER, DEMO_USDC);
        IERC20Meta(USDT).approve(V3_POSITION_MANAGER, DEMO_USDT);
        (id,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER)
            .mint(
                INonfungiblePositionManager.MintParams({
                    token0: USDC,
                    token1: USDT,
                    fee: 100,
                    tickLower: ((tick - 50) / spacing) * spacing,
                    tickUpper: ((tick + 50) / spacing) * spacing,
                    amount0Desired: DEMO_USDC,
                    amount1Desired: DEMO_USDT,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: maker,
                    deadline: block.timestamp
                })
            );
        vm.stopPrank();
    }

    function _demoData() internal view returns (bytes memory) {
        return abi.encode(demoTokenId);
    }

    /// @dev The base's `_offerFor` carries the *fixture's* `callbackData`, which names the 10k
    /// position. This one names the demo's.
    function _demoOffer(uint256 maxUnits) internal view returns (Offer memory offer) {
        offer = _offerFor(address(demo), maxUnits);
        offer.callbackData = _demoData();
    }

    function _demoLiquidity() internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER).positions(demoTokenId);
    }

    /// @dev The whole demo, end to end, at demo scale: quote it, then take exactly what was quoted
    /// through the deployed Midnight and watch it settle.
    function test_theDemoSettlesAtTenDollarsASide() public {
        uint256 bound = demo.buyerAssetsBound(bytes32(0), market, maker, _demoData());
        emit log_named_uint("bound at demo scale (USDC)", bound);
        assertGt(bound, 1e6, "the bound is under a dollar; the demo has nothing to show");

        _collateralize(bound);
        uint128 liquidityBefore = _demoLiquidity();

        vm.prank(taker);
        (uint256 buyerAssets,) = midnight.take(_demoOffer(bound), hex"", bound, taker, taker, address(0), hex"");

        emit log_named_uint("settled (USDC)", buyerAssets);
        emit log_named_uint("liquidity burnt", liquidityBefore - _demoLiquidity());
        emit log_named_uint("taker received (USDC)", IERC20Meta(USDC).balanceOf(taker));
        emit log_named_uint("maker credit on Midnight", midnight.credit(marketId, maker));
        emit log_named_uint("buffer left on the callback", IERC20Meta(USDC).balanceOf(address(demo)));

        assertEq(buyerAssets, bound, "the demo take did not settle the quoted size");
        assertEq(IERC20Meta(USDT).balanceOf(address(demo)), 0, "residual stranded");
    }

    /// @dev What the demo should actually fill: a round number a viewer can follow, not the bound.
    function test_aRoundTenDollarFillSettles() public {
        _collateralize(10e6);
        uint128 liquidityBefore = _demoLiquidity();

        vm.prank(taker);
        midnight.take(_demoOffer(10e6), hex"", 10e6, taker, taker, address(0), hex"");

        uint256 burnt = liquidityBefore - _demoLiquidity();
        emit log_named_uint("liquidity before", liquidityBefore);
        emit log_named_uint("liquidity burnt for a 10 USDC fill", burnt);
        emit log_named_uint("percent of the position burnt", burnt * 100 / liquidityBefore);

        assertGt(_demoLiquidity(), 0, "a 10 USDC fill consumed the whole position");
    }

    /// @dev **Can one address play both sides?** It decides whether the demo needs a second funded
    /// wallet holding cbBTC, or just one. `onBuy` requires `buyer == OWNER`, and the buyer Midnight
    /// passes is the offer's maker — so the taker being the same address is not obviously refused.
    function test_canTheMakerTakeTheirOwnOffer() public {
        _collateralizeFor(maker, 10e6);

        // `SelfTake()`. The demo needs two funded addresses, and the taker is the one that has to
        // hold cbBTC collateral.
        vm.expectRevert(bytes4(0x116e7ef2));
        vm.prank(maker);
        midnight.take(_demoOffer(10e6), hex"", 10e6, maker, maker, address(0), hex"");
    }

    /// @dev **Is a ratifier required?** The fixture deploys a `DummyRatifier`. If `address(0)` is
    /// accepted, the demo deploys one contract fewer on mainnet.
    function test_isARatifierRequired() public {
        _collateralize(10e6);

        Offer memory offer = _demoOffer(10e6);
        offer.ratifier = address(0);

        // `RatifierUnauthorized()` — the named ratifier must be authorised by the maker, and the
        // maker never authorised `address(0)`.
        vm.expectRevert(bytes4(0xa8d9c8bf));
        vm.prank(taker);
        midnight.take(offer, hex"", 10e6, taker, taker, address(0), hex"");
    }

    /// @dev **Can the maker be their own ratifier?** If an EOA works, the demo deploys one contract
    /// fewer — no `DummyRatifier` on mainnet, just a self-authorisation the maker already has to
    /// send anyway.
    function test_canTheMakerRatifyForThemselves() public {
        _collateralize(10e6);

        vm.prank(maker);
        midnight.setIsAuthorized(maker, true, maker);

        Offer memory offer = _demoOffer(10e6);
        offer.ratifier = maker;

        vm.prank(taker);
        try midnight.take(offer, hex"", 10e6, taker, taker, address(0), hex"") {
            emit log("maker-as-ratifier ACCEPTED: no ratifier contract needed on mainnet");
        } catch (bytes memory err) {
            emit log_named_bytes("maker-as-ratifier refused", err);
        }
    }

    function _collateralizeFor(address who, uint256 debt) internal {
        uint256 collateral = ((debt * 1e18 / LLTV) * 1e36 / CBBTC_PRICE) * 2;
        deal(CBBTC, who, collateral);
        vm.startPrank(who);
        IERC20Meta(CBBTC).approve(MIDNIGHT, collateral);
        midnight.supplyCollateral(market, 0, collateral, who);
        vm.stopPrank();
    }
}
