// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UniswapV4BuyCallback} from "../src/UniswapV4BuyCallback.sol";
import {UniswapV4BuyCallbackFactory} from "../src/UniswapV4BuyCallbackFactory.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {IUniswapV4BuyCallback} from "../src/interfaces/IUniswapV4BuyCallback.sol";

import {V4ParkedBase} from "./V4ParkedBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";

/// @notice D4: the v4 happy path, against the real USDC/USDT 0.01% v4 pool on a Base fork.
///
/// @dev Custody differs from v3 by necessity — `modifyLiquidity` keys positions by `msg.sender`,
/// so the callback owns this one. `test_onlyTheMakerCanMoveTheParkedCapital` and
/// `test_unparkAlwaysPaysTheMaker` are what stands in for v3's "the maker keeps the NFT".
contract UniswapV4BuyCallbackTest is V4ParkedBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    UniswapV4BuyCallbackFactory internal factory;
    UniswapV4BuyCallback internal callback;
    UniswapV4BuyCallback.Parked internal parked;

    function setUp() public override {
        super.setUp();

        factory = new UniswapV4BuyCallbackFactory(MIDNIGHT, V4_POOL_MANAGER);
        callback = UniswapV4BuyCallback(factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, poolKey, bytes32(0)));

        parked =
            UniswapV4BuyCallback.Parked({key: poolKey, tickLower: tickLower, tickUpper: tickUpper, salt: bytes32(0)});

        // Parking here is a call on the callback, not a mint: the position it burns has to be one
        // it owns. Plain ERC-20 approvals, since the tokens go to the pool manager directly rather
        // than through Permit2.
        vm.startPrank(maker);
        IERC20Meta(USDC).approve(address(callback), type(uint256).max);
        IERC20Meta(USDT).approve(address(callback), type(uint256).max);
        callback.park(parked, _liquidityFor(PARKED_USDC, PARKED_USDT));
        vm.stopPrank();
    }

    /// HELPERS ///

    function _parkedLiquidity() internal view returns (uint128) {
        return _parkedLiquidityOf(address(callback));
    }

    /// @dev Positions are keyed by owner, so reading one means naming the callback that owns it.
    function _parkedLiquidityOf(address owner) internal view returns (uint128) {
        return IPoolManager(V4_POOL_MANAGER)
            .getPositionLiquidity(
                poolKey.toId(), keccak256(abi.encodePacked(owner, parked.tickLower, parked.tickUpper, parked.salt))
            );
    }

    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(parked);
    }

    /// SETUP SANITY ///

    function test_theParkedPositionIsOwnedByTheCallback() public view {
        assertGt(_parkedLiquidity(), 0, "nothing parked");
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), 0, "callback should hold no idle USDC");
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "callback should hold no idle USDT");
    }

    /// THE D4 DELIVERABLE ///

    /// @dev The whole unwind inside one `unlock()`. What makes it different from v3 is not the
    /// result but the plumbing: the residual is created as a delta by the burn and consumed as a
    /// delta by the swap, so it is sold without ever being transferred.
    function test_onBuySourcesFromTheParkedPosition() public {
        uint128 liquidityBefore = _parkedLiquidity();

        vm.prank(MIDNIGHT);
        bytes32 result = callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS);
        assertGe(IERC20Meta(USDC).balanceOf(address(callback)), 500e6, "under-sourced");
        assertLt(_parkedLiquidity(), liquidityBefore, "position was not drawn on");
        assertGt(_parkedLiquidity(), 0, "a 500 fill took the whole position");
    }

    /// @dev The netting claim, asserted rather than described: the residual token never lands on
    /// this contract. In v3 the same settlement leaves USDT here between `collect` and `swap`.
    function test_theResidualIsNeverHeld() public {
        vm.recordLogs();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        // Not "ends up with none of it" — never touches it. The burn credits a residual delta and
        // the swap consumes the same delta, so no ERC-20 transfer of it ever happens. The NFT
        // adapter's equivalent test asserts two.
        assertEq(_residualTransfersTouching(address(callback)), 0, "residual moved as tokens, not as a delta");
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "residual was held, not netted");
    }

    /// @dev Proportional, like v3. Guards against the sizing collapsing to a constant, which is how
    /// a partial unwind quietly becomes a full one.
    function test_biggerFillBurnsMoreLiquidity() public {
        uint128 liquidityBefore = _parkedLiquidity();

        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 200e6, 0, 0, maker, _callbackData());
        uint256 smallBurn = liquidityBefore - _parkedLiquidity();

        vm.revertToState(snapshot);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 800e6, 0, 0, maker, _callbackData());
        uint256 largeBurn = liquidityBefore - _parkedLiquidity();

        assertGt(largeBurn, smallBurn * 3, "burn does not scale with fill size");
    }

    /// @dev The buffer works identically on both adapters, because it lives in the base.
    function test_aFillCoveredByTheBufferNeverTouchesThePosition() public {
        deal(USDC, address(callback), 1_000e6);
        uint128 liquidityBefore = _parkedLiquidity();

        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 500e6, 0, 0, maker, _callbackData());

        assertEq(_parkedLiquidity(), liquidityBefore, "buffered fill reached the position");
    }

    /// @dev The other side of the ceiling: when the first burn genuinely does come up short, the
    /// escalation has to *finish the fill*, not merely be capped. The v3 suite has this; without it
    /// here, the v4 escalation branch is only ever exercised on its way to a revert.
    ///
    /// @dev Triggered the same way, through the gap that actually exists between the park venue and
    /// the route venue: route through the thinner 0.05% v4 pool and take most of its USDC out
    /// first, and the residual fetches far less than the sizing assumed.
    ///
    /// @dev The burn lands on exactly the ceiling. Escalation does not re-derive a size, it goes
    /// straight to twice what the fill justified — the same code path, in `SourcingMathLib`, that
    /// makes a dust fill revert.
    function test_escalationFinishesAFillTheFirstBurnFellShortOf() public {
        UniswapV4BuyCallback drifted = UniswapV4BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), bytes32(uint256(7)))
        );

        // The custodial adapter can only burn a position it owns, so this one has to park for
        // itself. Half the fixture's size, since the pool has to hold both.
        deal(USDC, maker, PARKED_USDC);
        deal(USDT, maker, PARKED_USDT);
        vm.startPrank(maker);
        IERC20Meta(USDC).approve(address(drifted), type(uint256).max);
        IERC20Meta(USDT).approve(address(drifted), type(uint256).max);
        drifted.park(parked, _liquidityFor(PARKED_USDC, PARKED_USDT));
        vm.stopPrank();

        uint128 liquidityBefore = _parkedLiquidityOf(address(drifted));

        // Baseline, with the venues still agreeing: this is the size the ceiling is a multiple of.
        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        drifted.onBuy(bytes32(0), market, 400e6, 0, 0, maker, _callbackData());
        uint256 sized = liquidityBefore - _parkedLiquidityOf(address(drifted));
        assertGt(sized, 0, "baseline burnt nothing, so the ceiling assertion below would be vacuous");
        vm.revertToState(snapshot);

        _drainRouteVenue(ROUTE_DRAIN);

        vm.prank(MIDNIGHT);
        bytes32 result = drifted.onBuy(bytes32(0), market, 400e6, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS, "escalation failed to finish the fill");
        assertGe(IERC20Meta(USDC).balanceOf(address(drifted)), 400e6, "under-sourced after escalating");

        uint256 burnt = liquidityBefore - _parkedLiquidityOf(address(drifted));
        assertGt(burnt, sized, "the sized burn should have come up short");
        assertEq(burnt, sized * 2, "escalation should burn exactly the ceiling");
        assertGt(_parkedLiquidityOf(address(drifted)), 0, "escalation took the whole position");
    }

    /// @dev Same ceiling as v3, and it has to hold here too: a fill too small to source its own
    /// rounding must revert rather than unwind the maker's whole position.
    function test_aDustFillCannotUnwindThePosition() public {
        uint128 liquidityBefore = _parkedLiquidity();

        vm.expectRevert(IUniswapV4BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1, 0, 0, maker, _callbackData());

        assertEq(_parkedLiquidity(), liquidityBefore, "a dust fill moved the position");
    }

    function test_onBuyRevertsWhenTheWholePositionCannotCoverTheFill() public {
        uint128 liquidityBefore = _parkedLiquidity();

        vm.expectRevert(IUniswapV4BuyCallback.InsufficientSourced.selector);
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 50_000e6, 0, 0, maker, _callbackData());

        assertEq(_parkedLiquidity(), liquidityBefore, "a failed fill moved the position");
    }

    /// QUOTING ///

    /// @dev **Where v4's thinness turns into a smaller quote.** Same maker, same pair, same fee
    /// tier: on v3 the bound is the whole position, because that position is 1% of the book. Here
    /// the parked 2k+2k is **59% of the pool's active liquidity**, and two separate things cut the
    /// quote down. `SourcingMathLib.MAX_ACTIVE_SHARE_WAD` refuses to consider burning past half the
    /// book at all — finding B, without which the bisection would be searching a function that no
    /// longer rises. Inside that cap, the 1bp budget reaches about **245 USDC**, roughly 6% of the
    /// position's paper value.
    ///
    /// @dev That is the bound working, not failing. A maker who *is* most of the venue cannot sell
    /// most of the venue into itself at spot, and a quote that said otherwise would hand the taker
    /// either a reverted transaction or a fill priced by the maker's own unwind. The naive bound
    /// said ~3,950 here; that number was never reachable.
    function test_theBoundIsCutDownByHowMuchOfTheVenueTheMakerIs() public view {
        uint128 active = _activeLiquidity();
        uint128 parked = _liquidityFor(PARKED_USDC, PARKED_USDT);
        assertGt(uint256(parked) * 2, active, "the maker is no longer past the active-share cap");

        uint256 bound = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        assertGt(bound, 100e6, "bound collapsed to nothing on a venue that can still trade");
        assertLt(bound, 500e6, "bound ignores the depth of the venue it has to sell into");
    }

    function test_buyerAssetsBoundIncludesTheBuffer() public {
        uint256 before = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());
        deal(USDC, address(callback), 1_000e6);

        assertEq(
            callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData()),
            before + 1_000e6,
            "buffer not counted"
        );
    }

    function test_buyerAssetsBoundIsZeroForAnyBuyerButOwner() public view {
        assertEq(callback.buyerAssetsBound(bytes32(0), market, address(0xdead), _callbackData()), 0);
    }

    /// CUSTODY ///

    /// @dev What stands in for v3's "the maker keeps the NFT". The capital is held by the contract,
    /// so the guarantee has to be that only the maker can move it.
    function test_onlyTheMakerCanMoveTheParkedCapital() public {
        // Read the liquidity first: `expectRevert` arms against the *next* call, and an argument
        // evaluated after it would be a staticcall to the pool manager.
        uint128 liquidity = _parkedLiquidity();

        vm.expectRevert(IMidnightBuyCallback.NotOwner.selector);
        vm.prank(address(0xdead));
        callback.unpark(parked, liquidity);

        vm.expectRevert(IMidnightBuyCallback.NotOwner.selector);
        vm.prank(address(0xdead));
        callback.park(parked, 1);
    }

    /// @dev And that the only destination is the maker. `unpark` takes no recipient, which is the
    /// property rather than an omission.
    function test_unparkAlwaysPaysTheMaker() public {
        uint128 liquidity = _parkedLiquidity();

        vm.prank(maker);
        callback.unpark(parked, liquidity);

        assertEq(_parkedLiquidity(), 0, "position not unwound");
        assertGt(IERC20Meta(USDC).balanceOf(maker), 1_900e6, "maker did not get their USDC back");
        assertGt(IERC20Meta(USDT).balanceOf(maker), 1_900e6, "maker did not get their USDT back");
        assertEq(IERC20Meta(USDC).balanceOf(address(callback)), 0, "callback kept USDC");
        assertEq(IERC20Meta(USDT).balanceOf(address(callback)), 0, "callback kept USDT");
    }

    /// GUARDS ///

    /// @dev The unlock callback is the one function the pool manager calls back into, so it is the
    /// one an attacker would drive directly.
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
        assertEq(callback.OWNER(), maker);
        assertEq(callback.MIDNIGHT(), MIDNIGHT);

        PoolKey memory route = callback.routeKey();
        assertEq(Currency.unwrap(route.currency0), USDC);
        assertEq(Currency.unwrap(route.currency1), USDT);
        assertEq(route.fee, V4_USDC_USDT_FEE);
    }

    /// @dev The route venue is part of the safety envelope, so the address has to commit to it.
    function test_theRouteVenueIsPartOfTheDeploymentKey() public {
        PoolKey memory otherRoute = usdcUsdtKey();
        otherRoute.fee = 500;
        otherRoute.tickSpacing = 10;

        address other = factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, otherRoute, bytes32(0));

        assertTrue(other != address(callback), "route venue did not change the address");
        assertTrue(factory.isUniswapBuyCallback(other), "not indexed");
    }
}
