// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UniswapV4NftBuyCallback} from "../src/UniswapV4NftBuyCallback.sol";
import {UniswapV4NftBuyCallbackFactory} from "../src/UniswapV4NftBuyCallbackFactory.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {IUniswapV4BuyCallback} from "../src/interfaces/IUniswapV4BuyCallback.sol";
import {IV4PositionManager, V4Actions, V4PositionInfo} from "../src/interfaces/IV4PositionManager.sol";

import {StubPriceRef} from "./mocks/StubPriceRef.sol";
import {V4ParkedBase} from "./V4ParkedBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice D4, second half: the **non-custodial** v4 adapter, against a real `PositionManager` NFT
/// minted in the real USDC/USDT 0.01% v4 pool on a Base fork.
///
/// @dev Custody is v3's, exactly: the maker keeps the NFT and only approves the callback, and
/// `ownerOf` is asserted unchanged after a settlement. What it gives up is the netting — the
/// decrease opens the position manager's unlock, so the residual swap needs a second one, and the
/// residual is really held in between. `test_theResidualIsHeldBetweenTheTwoUnlocks` pins that as a
/// measured difference rather than leaving it as a claim.
contract UniswapV4NftBuyCallbackTest is V4ParkedBase {
    UniswapV4NftBuyCallbackFactory internal factory;
    UniswapV4NftBuyCallback internal callback;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();

        factory = new UniswapV4NftBuyCallbackFactory(MIDNIGHT, V4_POOL_MANAGER, V4_POSITION_MANAGER);
        callback =
            UniswapV4NftBuyCallback(factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, poolKey, bytes32(0)));

        tokenId = _mintPosition();

        // The custody story, and it is v3's: the maker keeps the NFT and approves the callback.
        vm.prank(maker);
        IV4PositionManager(V4_POSITION_MANAGER).approve(address(callback), tokenId);
    }

    /// HELPERS ///

    function _mintPosition() internal returns (uint256 id) {
        id = IV4PositionManager(V4_POSITION_MANAGER).nextTokenId();

        bytes memory actions = abi.encodePacked(uint8(V4Actions.MINT_POSITION), uint8(V4Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(_liquidityFor(PARKED_USDC, PARKED_USDT)),
            uint128(PARKED_USDC),
            uint128(PARKED_USDT),
            maker,
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        vm.startPrank(maker);
        _approveThroughPermit2(V4_POSITION_MANAGER);
        IV4PositionManager(V4_POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        vm.stopPrank();
    }

    function _liquidity() internal view returns (uint128) {
        return IV4PositionManager(V4_POSITION_MANAGER).getPositionLiquidity(tokenId);
    }

    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(tokenId);
    }

    /// SETUP SANITY ///

    function test_theMakerKeepsTheNft() public view {
        assertGt(_liquidity(), 0, "nothing parked");
        assertEq(IV4PositionManager(V4_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
        assertEq(
            IV4PositionManager(V4_POSITION_MANAGER).getApproved(tokenId), address(callback), "callback not approved"
        );
    }

    /// @dev The hand-written interface is consensus with a deployed contract, not a local choice.
    /// If `v4-periphery` ever renumbers an action or repacks `PositionInfo`, this is what says so —
    /// rather than a settlement failing somewhere less legible.
    function test_theHandWrittenPositionManagerInterfaceMatchesTheDeployment() public view {
        (PoolKey memory key, uint256 info) = IV4PositionManager(V4_POSITION_MANAGER).getPoolAndPositionInfo(tokenId);

        assertEq(Currency.unwrap(key.currency0), USDC, "pool key currency0 mismatch");
        assertEq(Currency.unwrap(key.currency1), USDT, "pool key currency1 mismatch");
        assertEq(key.fee, poolKey.fee, "pool key fee mismatch");
        assertEq(key.tickSpacing, poolKey.tickSpacing, "pool key tick spacing mismatch");
        assertEq(V4PositionInfo.tickLower(info), tickLower, "tickLower decoded wrong");
        assertEq(V4PositionInfo.tickUpper(info), tickUpper, "tickUpper decoded wrong");
    }

    /// THE DELIVERABLE ///

    function test_onBuySourcesFromTheParkedPosition() public {
        uint128 liquidityBefore = _liquidity();

        vm.prank(MIDNIGHT);
        bytes32 result = callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS);
        assertGe(IERC20Meta(USDC).balanceOf(address(callback)), 500e6, "under-sourced");
        assertLt(_liquidity(), liquidityBefore, "position was not drawn on");
        assertGt(_liquidity(), 0, "a 500 fill took the whole position");
        assertEq(IV4PositionManager(V4_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
    }

    /// @dev The cost of staying non-custodial, measured. The position manager's `TAKE_PAIR` hands
    /// the residual over as real tokens, and only the second unlock can sell it — so between the
    /// two, this contract is holding USDT. The custodial adapter never does; that is the whole
    /// difference between them.
    function test_theResidualIsHeldBetweenTheTwoUnlocks() public {
        vm.recordLogs();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        // Out and back: `TAKE_PAIR` hands it over, the second unlock pays it in. The custodial
        // adapter's equivalent test asserts zero.
        assertEq(_residualTransfersTouching(address(callback)), 2, "residual did not move out and back");

        // It does not survive the settlement, though — the second unlock sells all of it.
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "residual left stranded");
    }

    function test_biggerFillBurnsMoreLiquidity() public {
        uint128 liquidityBefore = _liquidity();

        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 200e6, 0, 0, maker, _callbackData());
        uint256 smallBurn = liquidityBefore - _liquidity();

        vm.revertToState(snapshot);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 800e6, 0, 0, maker, _callbackData());
        uint256 largeBurn = liquidityBefore - _liquidity();

        assertGt(largeBurn, smallBurn * 3, "burn does not scale with fill size");
    }

    function test_aFillCoveredByTheBufferNeverTouchesThePosition() public {
        deal(USDC, address(callback), 1_000e6);
        uint128 liquidityBefore = _liquidity();

        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "buffered fill reached the position");
    }

    /// @dev The escalation branch finishing a fill rather than being capped — the counterpart of
    /// `test_aDustFillCannotUnwindThePosition`, and of the same test on the other two adapters.
    /// Both halves of the branch have to be covered on every adapter that has one.
    ///
    /// @dev Here the escalation costs a second full round-trip through the position manager, not
    /// just a second burn: two decreases, two unlocks of our own, four residual transfers. That is
    /// the non-custodial path's worst case, and it is worth seeing settle.
    /// @dev **The reference is neutralised here**, as on the other two adapters since D8: the drift
    /// that makes the sized burn fall short is the drift the cost guard refuses, so the mechanism
    /// can only be exercised with the guard held open. See `UniswapV3BuyCallback.t.sol`.
    function test_escalationFinishesAFillTheFirstBurnFellShortOf() public {
        StubPriceRef permissive = new StubPriceRef(158_456_325_028_528_675_187_087_900_672);
        UniswapV4NftBuyCallback drifted = UniswapV4NftBuyCallback(
            factory.createCallback(maker, permissive, MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), bytes32(uint256(7)))
        );
        vm.prank(maker);
        IV4PositionManager(V4_POSITION_MANAGER).approve(address(drifted), tokenId);

        uint128 liquidityBefore = _liquidity();

        // Baseline, venues still agreeing: the size the ceiling is a multiple of.
        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        drifted.onBuy(bytes32(0), market, 400e6, 0, 0, maker, _callbackData());
        uint256 sized = liquidityBefore - _liquidity();
        assertGt(sized, 0, "baseline burnt nothing, so the ceiling assertion below would be vacuous");
        vm.revertToState(snapshot);

        _drainRouteVenue(ROUTE_DRAIN);

        vm.recordLogs();
        vm.prank(MIDNIGHT);
        bytes32 result = drifted.onBuy(bytes32(0), market, 400e6, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS, "escalation failed to finish the fill");
        assertGe(IERC20Meta(USDC).balanceOf(address(drifted)), 400e6, "under-sourced after escalating");

        uint256 burnt = liquidityBefore - _liquidity();
        assertGt(burnt, sized, "the sized burn should have come up short");
        assertEq(burnt, sized * 2, "escalation should burn exactly the ceiling");
        assertGt(_liquidity(), 0, "escalation took the whole position");

        // Two rounds, and each one moves the residual out and back. The custodial adapter's
        // equivalent escalation moves it zero times either way.
        assertEq(_residualTransfersTouching(address(drifted)), 4, "escalation should have cost two round-trips");
        assertEq(IV4PositionManager(V4_POSITION_MANAGER).ownerOf(tokenId), maker, "maker lost the NFT");
    }

    function test_aDustFillCannotUnwindThePosition() public {
        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(IUniswapV4BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "a dust fill moved the position");
    }

    function test_onBuyRevertsWhenTheWholePositionCannotCoverTheFill() public {
        uint128 liquidityBefore = _liquidity();

        vm.expectRevert(IUniswapV4BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 50_000e6, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "a failed fill moved the position");
    }

    /// @dev Approval is the maker's to revoke, and revoking it under a live offer breaks their own
    /// offer rather than anyone else's. Fails closed — same property as v3.
    function test_onBuyRevertsIfApprovalIsRevoked() public {
        vm.prank(maker);
        IV4PositionManager(V4_POSITION_MANAGER).approve(address(0), tokenId);

        vm.expectRevert();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());
    }

    /// QUOTING ///

    /// @dev **Where v4's thinness turns into a smaller quote.** Same maker, same pair, same fee
    /// tier: on v3 the bound is the whole position, because that position is 1% of the book. Here
    /// the parked 2k+2k is **59% of the pool's active liquidity**, and three separate things cut the
    /// quote down. `SourcingMathLib.MAX_ACTIVE_SHARE_WAD` refuses to consider burning past half the
    /// book at all — finding B, without which the bisection would be searching a function that no
    /// longer rises. Inside that cap, the 1bp budget binds. And inside *that*, the walk crosses:
    /// this pool's first initialized tick is one tick from spot, so a residual of any size leaves
    /// the active range immediately.
    ///
    /// @dev **Pinned exactly, because a range would not notice the walk going away.** The
    /// single-step model quotes **245.214731** here against the walk's **214.661289** — 14.23%
    /// more. Both settle, so unlike v3 this is not a bound failing open; it is a bound spending
    /// more of the maker's price than they signed for. The 1bp budget is the promise, and the
    /// single step reaches that extra 30.55 USDC of size only by mispricing what the residual costs
    /// once it crosses. Different failure from v3's, same cause, and the reason the number is
    /// asserted rather than bracketed: replacing `multiStepOut` with `singleStepOut` used to leave
    /// every test in both v4 suites green.
    ///
    /// @dev That is the bound working, not failing. A maker who *is* most of the venue cannot sell
    /// most of the venue into itself at spot, and a quote that said otherwise would hand the taker
    /// either a reverted transaction or a fill priced by the maker's own unwind. The naive bound
    /// said ~3,950 here; that number was never reachable.
    ///
    /// @dev **D8 re-pinned this from 214.661289 to 214.128351.** Nothing about v4 changed — v4 still
    /// values the residual at route spot until D10 wires its reference — **D10 has now wired it**,
    /// and the pin below moved with the fixture's budget and reference. What changed at D8 is that the
    /// bisection now searches over fill size and sizes each candidate burn through
    /// `liquidityForTarget`, the way `onBuy` does, so the 25bp impact margin is priced instead of
    /// assumed away. 0.25% of the quote, which is the margin exactly.
    function test_theBoundIsCutDownByHowMuchOfTheVenueTheMakerIs() public view {
        uint128 active = _activeLiquidity();
        uint128 parked = _liquidityFor(PARKED_USDC, PARKED_USDT);
        assertGt(uint256(parked) * 2, active, "the maker is no longer past the active-share cap");

        // Re-pinned D10 for the same reason as the custodial twin: a real `V3TwapRef` and a 10bp
        // budget, because the ported cost guard charges the 0.75bp basis between the route venue
        // and the pool the reference reads. See `JOURNAL.md`.
        assertEq(
            callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData()),
            3_142_708391,
            "the v4 bound moved; check the walk and the reference basis before re-pinning"
        );
    }

    /// @dev **The v4 bound is measured against `PRICE_REF`, not against the venue it is about to
    /// trade in** — D8's central change, ported D10. Two callbacks over the *same NFT* and the same
    /// route venue, differing only in the reference they carry: if the bound read route spot, as it
    /// did until today, both would answer the same number.
    ///
    /// @dev It lives on this adapter and not the custodial one for a concrete reason. v4 keys a
    /// position by `owner: msg.sender`, so a second custodial callback owns nothing and its bound
    /// is zero whatever the reference says — a version of this test written there passed under the
    /// mutation it was supposed to catch, because the two bounds differed for the wrong reason.
    /// Sharing one NFT is what makes the reference the only variable.
    function test_theBoundIsMeasuredAgainstTheReferenceNotTheRouteVenue() public {
        UniswapV4NftBuyCallback atTwap = _routedCallback(MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), 12);

        // A reference that prices the residual well away from what the route venue pays. Nothing
        // about the venue changes between the two calls, so any movement came from the reference.
        StubPriceRef cheap = new StubPriceRef(112_045_541_949_572_287_496_682_733_568);
        UniswapV4NftBuyCallback atStub = UniswapV4NftBuyCallback(
            factory.createCallback(maker, cheap, MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), bytes32(uint256(13)))
        );

        uint256 atReference = atTwap.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        uint256 atOther = atStub.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        assertGt(atReference, 0, "the reference-priced bound is zero, so the comparison is vacuous");
        assertTrue(atReference != atOther, "the bound ignored the price reference");
    }

    /// @dev **The sandwich, on the non-custodial adapter.** `SandwichV4` drives the custodial one;
    /// this is the same attack against the path that holds the residual between two unlocks, and it
    /// exists because deleting only *this* adapter's cost guard left the whole suite green. The two
    /// adapters carry the check separately, so they have to be attacked separately.
    function test_theSandwichFailsClosedOnTheNonCustodialPathToo() public {
        UniswapV4NftBuyCallback routed = _routedCallback(MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), 11);
        vm.prank(maker);
        IV4PositionManager(V4_POSITION_MANAGER).approve(address(routed), tokenId);

        uint128 liquidityBefore = _liquidity();

        _drainRouteVenue(ROUTE_DRAIN);

        vm.expectPartialRevert(IMidnightBuyCallback.SourcingCostAboveBudget.selector);
        vm.prank(MIDNIGHT);
        routed.onBuy(bytes32(0), market, 400e6, 0, 0, maker, _callbackData());

        assertEq(_liquidity(), liquidityBefore, "the attacked settlement moved the position");
        assertEq(IERC20Meta(USDT).balanceOf(address(routed)), 0, "residual stranded on the callback");
    }

    /// @dev A second callback over the same NFT, differing only in budget and route venue. Possible
    /// here and not on the custodial adapter, where a position belongs to whichever callback parked
    /// it — which is why this branch is covered on this side. `_boundFor` and the
    /// `routeIsParkVenue` derivation both live in `UniswapV4BuyCallbackBase` and are shared verbatim
    /// with `UniswapV4BuyCallback`, so what is exercised here is the quoting path of both.
    function _routedCallback(uint256 budgetWad, PoolKey memory route, uint256 salt)
        internal
        returns (UniswapV4NftBuyCallback routed)
    {
        routed = UniswapV4NftBuyCallback(factory.createCallback(maker, priceRef, budgetWad, route, bytes32(salt)));
    }

    /// @dev **`routeIsParkVenue == false`, through the adapter — and here the flag flips the
    /// *ordering*, not just the number.** Everywhere else the route venue is the parked venue, so
    /// the flag is only ever `true` and the adapter's own derivation of it is never exercised.
    ///
    /// @dev At a budget wide enough that capacity binds, the same-venue callback quotes **less**
    /// than the one routing elsewhere — the opposite of the v3 comparison, and for a reason worth
    /// stating. Routing into its own pool means burning thins the book, so
    /// `MAX_ACTIVE_SHARE_WAD` caps the burn at half the pool's active liquidity: 665.88e9 against a
    /// position of 788.96e9, or 84.4% of it. Routing elsewhere thins nothing there, so no cap
    /// applies and the whole position is reachable.
    ///
    /// @dev The quotes come out in that ratio to within a couple of percent rather than exactly,
    /// and the wedge arrived with D6. Under a single step at constant `L` both quotes were linear
    /// in the burn, so the ratio *was* the cap; the walk prices two different books across two
    /// different sets of crossed ticks, and those do not cancel. Tolerance widened to 3% and the
    /// claim narrowed to match — the cap is what explains the gap, not the last basis point of it.
    ///
    /// @dev A flag stuck `true` would cap both and lose the gap; stuck `false` would cap neither.
    function test_theActiveShareCapAppliesOnlyWhenTheRouteIsTheParkedVenue() public {
        uint256 capped =
            _routedCallback(0.05e18, poolKey, 30).buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        uint256 uncapped = _routedCallback(0.05e18, usdcUsdtRouteKey(), 31)
            .buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        assertLt(capped, uncapped, "the active-share cap did not bind on the same-venue route");

        // The gap is the cap and nothing else: half the pool's active liquidity over the whole
        // position. Derived from live state rather than hard-coded, so it stays true if the fork
        // block moves.
        uint256 capRatio = (uint256(_activeLiquidity() / 2) * 1e18) / _liquidityFor(PARKED_USDC, PARKED_USDT);
        assertApproxEqRel((capped * 1e18) / uncapped, capRatio, 0.03e18, "the gap is not the active-share cap");
    }

    /// @dev The other side of the same flag. Once the budget binds instead of capacity, the ordering
    /// reverses: routing through the thinner, five-times-dearer 0.05% pool quotes **less**, because
    /// now what limits the fill is what the residual costs to sell rather than how much of the book
    /// the maker may burn. Same two callbacks, same position, opposite answer.
    function test_aThinnerRouteVenueQuotesLessOnceTheBudgetBinds() public {
        uint256 here =
            _routedCallback(0.001e18, poolKey, 32).buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        uint256 there = _routedCallback(0.001e18, usdcUsdtRouteKey(), 33)
            .buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        assertLt(there, here, "a thinner, dearer route venue did not cost the maker size");
        assertGt(there, 0, "the thinner venue quoted nothing at all");
    }

    function test_buyerAssetsBoundIsZeroForAnyBuyerButOwner() public view {
        assertEq(callback.buyerAssetsBound(bytes32(0), market, address(0xdead), _callbackData()), 0);
    }

    /// GUARDS ///

    function test_unlockCallbackRevertsForEveryCallerButThePoolManager() public {
        vm.expectRevert(IUniswapV4BuyCallback.NotPoolManager.selector);
        vm.prank(address(0xdead));
        callback.unlockCallback("");
    }

    function test_onBuyRevertsIfCallerIsNotMidnight() public {
        vm.expectRevert(IMidnightBuyCallback.NotMidnight.selector);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());
    }

    function test_onBuyRevertsIfBuyerIsNotOwner() public {
        vm.expectRevert(IMidnightBuyCallback.NotOwnerBuyer.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, address(0xdead), _callbackData());
    }

    function test_onBuyRevertsIfLoanTokenIsNotInThePool() public {
        market.loanToken = CBBTC;

        vm.expectRevert(IUniswapV4BuyCallback.LoanCurrencyNotInPool.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());
    }

    /// ENVELOPE ///

    function test_constructorWiresTheVenue() public view {
        assertEq(callback.POOL_MANAGER(), V4_POOL_MANAGER);
        assertEq(callback.POSITION_MANAGER(), V4_POSITION_MANAGER);
        assertEq(callback.OWNER(), maker);
        assertEq(callback.MIDNIGHT(), MIDNIGHT);
    }
}
