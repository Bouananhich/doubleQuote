// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

import {Market} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {UniswapV3BuyCallbackFactory} from "../src/UniswapV3BuyCallbackFactory.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {IUniswapV3BuyCallback} from "../src/interfaces/IUniswapV3BuyCallback.sol";

import {ForkBase} from "./ForkBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";
import {StubPriceRef} from "./mocks/StubPriceRef.sol";

/// @notice D2: the v3 happy path, against a real position minted in the real USDC/USDT 0.01% pool
/// on a Base fork.
///
/// @dev The maker keeps the NFT throughout and only `approve`s the callback — every test here
/// would fail if custody were required, which is what settles the D1 leaning.
contract UniswapV3BuyCallbackTest is ForkBase {
    /// @dev 1 bp. Held but not yet read by the adapter; see the note on `UniswapV3BuyCallback`.
    uint256 internal constant MAX_SLIPPAGE_WAD = 0.0001e18;

    /// @dev `DecreaseLiquidity(uint256,uint128,uint256,uint256)` on the position manager. Counting
    /// these is how a test tells one burn from two.
    bytes32 internal constant DECREASE_LIQUIDITY_TOPIC =
        0x26f6a048ee9138f2c0ce266f322cb99228e8d619ae2bff30c67f8dcf9d2377b4;

    /// @dev USDC (`0x8335…`) sorts below native USDT (`0xfde4…`), so the loan token is token0 and
    /// the residual is token1.
    uint256 internal constant PARKED_USDC = 10_000e6;
    uint256 internal constant PARKED_USDT = 10_000e6;

    address internal maker = makeAddr("maker");
    StubPriceRef internal priceRef;
    UniswapV3BuyCallbackFactory internal factory;
    UniswapV3BuyCallback internal callback;
    Market internal market;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();

        priceRef = new StubPriceRef(1 << 96);
        factory = new UniswapV3BuyCallbackFactory(MIDNIGHT, V3_POSITION_MANAGER);
        callback = UniswapV3BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(0))
        );

        market.chainId = block.chainid;
        market.midnight = MIDNIGHT;
        market.loanToken = USDC;

        tokenId = _mintPosition();

        // The whole custody story: the maker keeps the NFT and approves the callback for it.
        vm.prank(maker);
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(address(callback), tokenId);
    }

    /// @dev Mints a real position tightly around the live tick, which is where a stable-pair LP
    /// actually earns and therefore the configuration the bound has to cope with.
    function _mintPosition() internal returns (uint256 id) {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();
        int24 spacing = IUniswapV3Pool(POOL_USDC_USDT_100).tickSpacing();
        int24 lower = ((tick - 50) / spacing) * spacing;
        int24 upper = ((tick + 50) / spacing) * spacing;

        deal(USDC, maker, PARKED_USDC);
        deal(USDT, maker, PARKED_USDT);

        vm.startPrank(maker);
        IERC20Meta(USDC).approve(V3_POSITION_MANAGER, PARKED_USDC);
        IERC20Meta(USDT).approve(V3_POSITION_MANAGER, PARKED_USDT);
        (id,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER)
            .mint(
                INonfungiblePositionManager.MintParams({
                    token0: USDC,
                    token1: USDT,
                    fee: 100,
                    tickLower: lower,
                    tickUpper: upper,
                    amount0Desired: PARKED_USDC,
                    amount1Desired: PARKED_USDT,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: maker,
                    deadline: block.timestamp
                })
            );
        vm.stopPrank();
    }

    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(tokenId);
    }

    function _liquidity() internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER).positions(tokenId);
    }

    /// SETUP SANITY ///

    function test_positionIsParkedAndMakerKeepsCustody() public view {
        assertGt(_liquidity(), 0, "no liquidity parked");
        assertEq(INonfungiblePositionManager(V3_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
        assertEq(
            INonfungiblePositionManager(V3_POSITION_MANAGER).getApproved(tokenId),
            address(callback),
            "callback not approved"
        );
    }

    /// THE D2 DELIVERABLE ///

    /// @dev Park → take → atomic unwind + settle. `decreaseLiquidity`, `collect`, swap the residual
    /// USDT into USDC, approve Midnight, return `CALLBACK_SUCCESS`.
    function test_onBuySourcesFromTheParkedPosition() public {
        uint256 buyerAssets = 5_000e6;
        uint128 liquidityBefore = _liquidity();

        vm.prank(MIDNIGHT);
        bytes32 result = callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS, "callback did not succeed");
        assertGe(IERC20Meta(USDC).balanceOf(address(callback)), buyerAssets, "not enough loan token sourced");
        assertEq(IERC20Meta(USDC).allowance(address(callback), MIDNIGHT), buyerAssets, "Midnight not approved");

        // Only the fill's share is burnt. A 5k fill against a ~19.9k position should leave roughly
        // three quarters of the liquidity still earning.
        uint128 remaining = _liquidity();
        assertGt(remaining, (liquidityBefore * 70) / 100, "burnt far more than the fill needed");
        assertLt(remaining, liquidityBefore, "nothing was burnt");

        // The residual is swapped in its entirety, so no non-loan-token dust is left behind.
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "residual dust left on the callback");

        // Still non-custodial after a full unwind.
        assertEq(INonfungiblePositionManager(V3_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
    }

    /// @dev The surplus from a full unwind is not lost — it lands in the buffer, which is where the
    /// next fill is served from.
    function test_onBuyLeavesTheSurplusAsBuffer() public {
        uint256 buyerAssets = 1_000e6;

        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, maker, _callbackData());

        uint256 buffer = IERC20Meta(USDC).balanceOf(address(callback));
        assertGt(buffer, buyerAssets, "no surplus buffered");

        // Second fill is served entirely from the buffer: the position is already empty, so it
        // could not be served any other way.
        vm.prank(MIDNIGHT);
        bytes32 result = callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS);
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), buffer, "buffer should not have moved");
    }

    /// @dev A fill close to the position's capacity draws nearly all of it, and both sides come
    /// back as loan token — a stable pair round-trips near 1:1, so 10k+10k surfaces roughly 20k
    /// USDC. Loose bounds: this checks the residual actually got swapped, it does not price it.
    /// @dev Deliberately not asserting the position lands at exactly zero. The sizing is
    /// proportional, so a fill below capacity leaves a sliver behind by design; the
    /// burn-everything branch is pinned exactly in `SourcingMathLib.t.sol`, where it does not
    /// depend on the fork's live price.
    function test_aLargeFillUnwindsNearlyAllOfThePosition() public {
        uint128 liquidityBefore = _liquidity();

        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 19_500e6, 0, 0, maker, _callbackData());

        assertLt(_liquidity(), liquidityBefore / 20, "should have drawn nearly the whole position");

        uint256 recovered = IERC20Meta(USDC).balanceOf(address(callback));
        assertGt(recovered, 19_500e6, "residual does not look swapped");
        assertLt(recovered, 20_100e6, "recovered more than was parked");
    }

    /// PARTIAL UNWIND ///

    /// @dev The point of D3. A small fill should cost the maker a small slice of the position, not
    /// the whole thing — the position keeps earning, and the residual swap that follows is small
    /// enough to be cheap.
    function test_burnIsProportionalToTheFill() public {
        uint128 liquidityBefore = _liquidity();

        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 2_000e6, 0, 0, maker, _callbackData());

        // ~2k of a ~19.9k position is ~10%, plus the impact margin.
        uint256 burnt = liquidityBefore - _liquidity();
        assertGt(burnt, (uint256(liquidityBefore) * 9) / 100, "burnt less than the fill needed");
        assertLt(burnt, (uint256(liquidityBefore) * 12) / 100, "burnt much more than the fill needed");
    }

    /// @dev A bigger fill burns more. Guards against the sizing collapsing to a constant, which is
    /// how a "partial" unwind quietly becomes a full one again.
    function test_biggerFillBurnsMoreLiquidity() public {
        uint128 liquidityBefore = _liquidity();

        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 2_000e6, 0, 0, maker, _callbackData());
        uint256 smallBurn = liquidityBefore - _liquidity();

        vm.revertToState(snapshot);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 8_000e6, 0, 0, maker, _callbackData());
        uint256 largeBurn = liquidityBefore - _liquidity();

        assertGt(largeBurn, smallBurn * 3, "burn does not scale with fill size");
    }

    /// @dev The sizing must land in one round on the product venue. Two rounds means a second
    /// `decreaseLiquidity` plus a second swap on the taker's gas, which is what the impact margin
    /// exists to avoid — and a regression here is silent, since the fallback still returns the
    /// right amount.
    function test_theCommonCaseNeedsOnlyOneBurn() public {
        vm.prank(MIDNIGHT);
        vm.recordLogs();
        callback.onBuy(bytes32(0), market, 5_000e6, 0, 0, maker, _callbackData());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns;
        for (uint256 i; i < logs.length; ++i) {
            // IncreaseLiquidity/DecreaseLiquidity on the position manager.
            if (logs[i].emitter == V3_POSITION_MANAGER && logs[i].topics[0] == DECREASE_LIQUIDITY_TOPIC) ++burns;
        }

        assertEq(burns, 1, "fell back to a second burn on the product venue");
    }

    /// @dev The attack the escalation ceiling exists to stop. A fill of one wei sizes to a burn
    /// that yields nothing once amounts round down, so it can never cover itself. Before the
    /// ceiling, the fallback answered that by unwinding the whole position — a maker's entire LP
    /// destroyed for a millionth of a dollar, in one transaction, with no capital at risk for the
    /// attacker. It has to fail closed instead.
    function test_aDustFillCannotUnwindThePosition() public {
        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "a dust fill moved the position");
    }

    /// @dev The ceiling must not fire on honest fills. Sweeps sizes across four orders of
    /// magnitude, each against a fresh position, asserting every one settles and none of them burns
    /// disproportionately.
    function test_honestFillsOfEverySizeStillSettle() public {
        uint256[5] memory sizes = [uint256(1e6), 100e6, 1_000e6, 5_000e6, 15_000e6];

        for (uint256 i; i < sizes.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint128 liquidityBefore = _liquidity();

            vm.prank(MIDNIGHT);
            bytes32 result = callback.onBuy(bytes32(0), market, sizes[i], 0, 0, maker, _callbackData());

            assertEq(result, CALLBACK_SUCCESS, "honest fill refused");
            assertGe(IERC20Meta(USDC).balanceOf(address(callback)), sizes[i], "under-sourced");

            // Burnt liquidity stays tied to the fill: never more than double the fill's share.
            uint256 burnt = liquidityBefore - _liquidity();
            uint256 fairShare = (uint256(liquidityBefore) * sizes[i]) / 19_800e6;
            assertLe(burnt, fairShare * 2 + 1e6, "burnt disproportionately to the fill");

            vm.revertToState(snapshot);
        }
    }

    /// @dev The dust-take defence, end to end. With a funded buffer, repeated small takes never
    /// reach the position at all — no burn, no swap, nothing to bleed.
    function test_repeatedDustTakesNeverTouchAFundedPosition() public {
        deal(USDC, address(callback), 1_000e6);
        uint128 liquidityBefore = _liquidity();

        for (uint256 i; i < 20; ++i) {
            vm.prank(MIDNIGHT);
            callback.onBuy(bytes32(0), market, 1e6, 0, 0, maker, _callbackData());
        }

        assertEq(_liquidity(), liquidityBefore, "dust takes reached the position");
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), 1_000e6, "buffer was spent");
    }

    /// QUOTING ///

    function test_buyerAssetsBoundReflectsTheParkedPosition() public view {
        uint256 bound = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        // Naive, so it over-promises slightly against what a real unwind returns — that gap is the
        // subject of D5/D6. It should still be in the neighbourhood of both sides at spot.
        assertGt(bound, 19_000e6, "bound far below the position");
        assertLt(bound, 20_100e6, "bound above what was parked");
    }

    function test_buyerAssetsBoundIncludesTheBuffer() public {
        uint256 before = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        deal(USDC, address(callback), 1_000e6);

        assertEq(
            callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData()),
            before + 1_000e6,
            "buffer not added to the bound"
        );
    }

    function test_buyerAssetsBoundIsZeroForAnyBuyerButOwner() public view {
        assertEq(callback.buyerAssetsBound(bytes32(0), market, address(0xdead), _callbackData()), 0);
    }

    /// GUARDS ///

    /// @dev The analogue of Blue's `InconsistentLoanToken`, and the one invariant on the parking
    /// venue: a pool that does not hold the loan token cannot source it.
    function test_onBuyRevertsIfLoanTokenIsNotInThePool() public {
        market.loanToken = CBBTC;

        vm.expectRevert(IUniswapV3BuyCallback.LoanTokenNotInPool.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1e8, 0, 0, maker, _callbackData());
    }

    function test_buyerAssetsBoundRevertsIfLoanTokenIsNotInThePool() public {
        market.loanToken = CBBTC;

        vm.expectRevert(IUniswapV3BuyCallback.LoanTokenNotInPool.selector);
        callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
    }

    /// @dev The swap callback is the one function an external contract calls back into, so it is
    /// the one place funds could be pulled out. `ROUTE_POOL` is immutable, so the guard is total.
    /// @dev Concrete callers rather than a fuzzed address: the guard is a single equality, so
    /// fuzzing it adds no coverage over the near-misses that could plausibly be whitelisted by a
    /// sloppier implementation — a real pool, the position manager, the owner.
    function test_swapCallbackRevertsForEveryCallerButTheRoutePool() public {
        address[4] memory callers = [makeAddr("attacker"), POOL_CBBTC_USDC_500, V3_POSITION_MANAGER, maker];

        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(IUniswapV3BuyCallback.NotRoutePool.selector);
            vm.prank(callers[i]);
            callback.uniswapV3SwapCallback(1e6, -1e6, "");
        }
    }

    /// @dev Park and route are independent venues, so the pool the position is parked in has no
    /// special standing with the callback. Here the position is parked in USDC/USDT while the
    /// residual routes through cbBTC/USDC, and the parked pool cannot drive the swap callback.
    function test_swapCallbackRejectsTheParkedPoolWhenItIsNotTheRoute() public {
        UniswapV3BuyCallback routedElsewhere = UniswapV3BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_CBBTC_USDC_500, bytes32(uint256(1)))
        );
        assertEq(routedElsewhere.ROUTE_POOL(), POOL_CBBTC_USDC_500, "route venue not independent");

        vm.expectRevert(IUniswapV3BuyCallback.NotRoutePool.selector);
        vm.prank(POOL_USDC_USDT_100);
        routedElsewhere.uniswapV3SwapCallback(1e6, -1e6, "");
    }

    function test_onBuyRevertsIfCallerIsNotMidnight() public {
        vm.expectRevert(IMidnightBuyCallback.NotMidnight.selector);
        callback.onBuy(bytes32(0), market, 1e6, 0, 0, maker, _callbackData());
    }

    function test_onBuyRevertsIfBuyerIsNotOwner() public {
        vm.expectRevert(IMidnightBuyCallback.NotOwnerBuyer.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1e6, 0, 0, address(0xdead), _callbackData());
    }

    /// FAIL-CLOSED ///

    /// @dev A take larger than the position can source must revert, not settle badly. This is the
    /// scenario `buyerAssetsBound` exists to stop a taker walking into: the routing layer is
    /// asynchronous, so a taker can size a fill against stale state and ask for more than the maker
    /// can actually produce. The bound says no first; `InsufficientSourced` is what catches it when
    /// the taker ignores the bound.
    function test_onBuyRevertsWhenTheWholePositionCannotCoverTheFill() public {
        uint256 buyerAssets = 100_000e6;

        // The bound is the taker's warning, and it is well below the ask.
        assertLt(
            callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData()),
            buyerAssets,
            "bound should already refuse this size"
        );

        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, maker, _callbackData());
    }

    /// @dev Guards against a *future* tolerant implementation rather than against the EVM. A revert
    /// rolls state back on its own, so this passes trivially today; it starts earning its place the
    /// moment someone is tempted to make `_sourceLoanToken` source what it can and approve less,
    /// which would half-settle a take and strand the difference on the callback.
    function test_failedFillLeavesThePositionIntact() public {
        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(IUniswapV3BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 100_000e6, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "position was drained by a failed take");
        assertEq(IERC20Meta(USDC).allowance(address(callback), MIDNIGHT), 0, "Midnight left approved");
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), 0, "loan token stranded on the callback");
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "residual stranded on the callback");
    }

    /// @dev A maker can sign an offer whose routing pool does not trade the residual against the
    /// loan token — here a USDC/USDT position routed through cbBTC/USDC, where the USDT residual
    /// has no counterparty. Since the route venue is immutable this is a deployment-time mistake,
    /// and it must revert on a name rather than attempt the swap.
    function test_onBuyRevertsIfTheRouteVenueCannotTradeTheResidual() public {
        UniswapV3BuyCallback misrouted = UniswapV3BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_CBBTC_USDC_500, bytes32(uint256(2)))
        );

        // cbBTC/USDC holds the loan token but not the residual, so the mismatch is specifically
        // about the residual having nowhere to go.
        assertEq(IUniswapV3Pool(POOL_CBBTC_USDC_500).token0(), USDC, "route pool token0");
        assertEq(IUniswapV3Pool(POOL_CBBTC_USDC_500).token1(), CBBTC, "route pool token1");

        vm.prank(maker);
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(address(misrouted), tokenId);

        vm.expectRevert(IUniswapV3BuyCallback.RoutePairMismatch.selector);
        vm.prank(MIDNIGHT);
        misrouted.onBuy(bytes32(0), market, 5_000e6, 0, 0, maker, _callbackData());
    }

    /// @dev Approval is the maker's to revoke, and revoking it under a live offer breaks their own
    /// offer rather than anyone else's. It fails closed.
    function test_onBuyRevertsIfApprovalIsRevoked() public {
        vm.prank(maker);
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(address(0), tokenId);

        vm.expectRevert();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 5_000e6, 0, 0, maker, _callbackData());
    }

    /// ENVELOPE ///

    function test_constructorWiresTheVenue() public view {
        assertEq(callback.POSITION_MANAGER(), V3_POSITION_MANAGER);
        assertEq(callback.FACTORY(), V3_FACTORY);
        assertEq(callback.ROUTE_POOL(), POOL_USDC_USDT_100);
        assertEq(callback.OWNER(), maker);
        assertEq(callback.MIDNIGHT(), MIDNIGHT);
        assertEq(address(callback.PRICE_REF()), address(priceRef));
        assertEq(callback.MAX_SLIPPAGE_WAD(), MAX_SLIPPAGE_WAD);
    }

    function test_factoryIndexesTheCallback() public view {
        bytes32 configSalt =
            factory.computeConfigSalt(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(0));

        assertEq(factory.callbackOf(configSalt), address(callback));
        assertTrue(factory.isUniswapBuyCallback(address(callback)));
        assertEq(factory.POSITION_MANAGER(), V3_POSITION_MANAGER);
    }
}
