// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {Market} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";
import {ERC20} from "midnight/test/erc20s/ERC20.sol";

import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";
import {IPriceRef} from "../src/interfaces/IPriceRef.sol";
import {MockParkedPosition, MockUniswapBuyCallback} from "./mocks/MockUniswapBuyCallback.sol";

/// @notice Forked from Morpho's `BlueBuyCallbackTest` (GPL-2.0-or-later), which is the closest
/// thing to a conformance suite for a Midnight buy callback.
///
/// @dev Three groups of tests were dropped and one was added:
///   - Blue's eleven `setAuthorization` / `setAuthorizationWithSig` cases have no analogue. They
///     authorise accounts to act on the callback's *Blue* position; the maker keeps custody of the
///     Uniswap position and manages it directly.
///   - `testOnBuyRevertsIfLoanTokenIsInconsistent` belongs to the adapters. Blue's invariant is
///     `marketParams.loanToken == market.loanToken`; the analogue here is that one currency of the
///     parked pool must equal the loan token, which only an adapter can check.
///   - The buffer cases are new, because Blue's callback has no buffer.
///
/// @dev No fork. This exercises only what the base owns, which is venue-independent; the adapters
/// bring their own fork tests.
contract UniswapBuyCallbackBaseTest is Test {
    address internal owner = makeAddr("owner");
    address internal midnight = makeAddr("midnight");
    address internal routePool = makeAddr("routePool");
    IPriceRef internal priceRef = IPriceRef(makeAddr("priceRef"));
    uint256 internal constant MAX_SLIPPAGE_WAD = 0.003e18;

    ERC20 internal loanToken;
    ERC20 internal otherToken;
    MockParkedPosition internal position;
    MockUniswapBuyCallback internal callback;
    Market internal market;

    function setUp() public {
        loanToken = new ERC20("loan", "LOAN");
        otherToken = new ERC20("other", "OTHER");
        position = new MockParkedPosition();
        callback = new MockUniswapBuyCallback(owner, midnight, priceRef, MAX_SLIPPAGE_WAD, routePool);

        market.chainId = block.chainid;
        market.midnight = midnight;
        market.loanToken = address(loanToken);
    }

    /// @dev The maker-signed `callbackData`, which here names the parked position and nothing else.
    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(address(position));
    }

    function _park(uint256 assets) internal {
        deal(address(loanToken), address(position), assets);
    }

    function _fillBuffer(uint256 assets) internal {
        deal(address(loanToken), address(callback), assets);
    }

    /// CONSTRUCTOR ///

    function testConstructorSetsTheSafetyEnvelope() public view {
        assertEq(callback.OWNER(), owner);
        assertEq(callback.MIDNIGHT(), midnight);
        assertEq(address(callback.PRICE_REF()), address(priceRef));
        assertEq(callback.MAX_SLIPPAGE_WAD(), MAX_SLIPPAGE_WAD);
    }

    function testConstructorRevertsIfOwnerIsZero() public {
        vm.expectRevert(IMidnightBuyCallback.ZeroAddress.selector);
        new MockUniswapBuyCallback(address(0), midnight, priceRef, MAX_SLIPPAGE_WAD, routePool);
    }

    function testConstructorRevertsIfMidnightIsZero() public {
        vm.expectRevert(IMidnightBuyCallback.ZeroAddress.selector);
        new MockUniswapBuyCallback(owner, address(0), priceRef, MAX_SLIPPAGE_WAD, routePool);
    }

    /// @dev A null price reference is the socially-engineered-envelope case: it would make every
    /// bound unconstrained, which is the one thing the envelope exists to prevent.
    function testConstructorRevertsIfPriceRefIsZero() public {
        vm.expectRevert(IMidnightBuyCallback.ZeroAddress.selector);
        new MockUniswapBuyCallback(owner, midnight, IPriceRef(address(0)), MAX_SLIPPAGE_WAD, routePool);
    }

    function testConstructorRevertsIfSlippageBudgetExceedsCeiling(uint256 maxSlippageWad) public {
        maxSlippageWad = bound(maxSlippageWad, 0.1e18 + 1, type(uint256).max);

        vm.expectRevert(IMidnightBuyCallback.SlippageBudgetTooLarge.selector);
        new MockUniswapBuyCallback(owner, midnight, priceRef, maxSlippageWad, routePool);
    }

    function testConstructorAcceptsSlippageBudgetAtCeiling() public {
        MockUniswapBuyCallback atCeiling = new MockUniswapBuyCallback(owner, midnight, priceRef, 0.1e18, routePool);

        assertEq(atCeiling.MAX_SLIPPAGE_WAD(), 0.1e18);
    }

    /// ON BUY ///

    function testOnBuySourcesShortfallAndApproves(uint256 buyerAssets) public {
        buyerAssets = bound(buyerAssets, 0, 1e30);
        _park(buyerAssets);

        vm.prank(midnight);
        bytes32 result = callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, owner, _callbackData());

        assertEq(result, CALLBACK_SUCCESS);
        assertEq(loanToken.balanceOf(address(callback)), buyerAssets);
        assertEq(loanToken.balanceOf(address(position)), 0);
        assertEq(loanToken.allowance(address(callback), midnight), buyerAssets);
    }

    function testOnBuySourcesShortfallAndApprovesZeroAssets() public {
        testOnBuySourcesShortfallAndApproves(0);
    }

    /// @dev The dust-take defence. A fill the buffer already covers must not reach the position at
    /// all — no unwind, no residual swap, nothing for a repeated dust take to bleed.
    function testOnBuyServedFromBufferDoesNotTouchThePosition(uint256 buffered, uint256 buyerAssets) public {
        buffered = bound(buffered, 0, 1e30);
        buyerAssets = bound(buyerAssets, 0, buffered);
        _fillBuffer(buffered);
        _park(1e30);

        vm.prank(midnight);
        callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, owner, _callbackData());

        assertEq(callback.sourceCalls(), 0, "position was touched");
        assertEq(loanToken.balanceOf(address(callback)), buffered, "buffer moved");
        assertEq(loanToken.allowance(address(callback), midnight), buyerAssets);
    }

    function testOnBuySourcesOnlyTheShortfall(uint256 buffered, uint256 buyerAssets) public {
        buffered = bound(buffered, 0, 1e30);
        buyerAssets = bound(buyerAssets, buffered + 1, 2e30);
        _fillBuffer(buffered);
        _park(buyerAssets - buffered);

        vm.prank(midnight);
        callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, owner, _callbackData());

        assertEq(callback.sourceCalls(), 1);
        assertEq(callback.lastShortfall(), buyerAssets - buffered, "over-sourced");
        assertEq(loanToken.balanceOf(address(callback)), buyerAssets);
        assertEq(loanToken.allowance(address(callback), midnight), buyerAssets);
    }

    function testOnBuyRevertsIfCallerIsNotMidnight(address caller) public {
        vm.assume(caller != midnight);

        vm.expectRevert(IMidnightBuyCallback.NotMidnight.selector);
        vm.prank(caller);
        callback.onBuy(bytes32(0), market, 0, 0, 0, owner, _callbackData());
    }

    function testOnBuyRevertsIfBuyerIsNotOwner(address buyer) public {
        vm.assume(buyer != owner);

        vm.expectRevert(IMidnightBuyCallback.NotOwnerBuyer.selector);
        vm.prank(midnight);
        callback.onBuy(bytes32(0), market, 0, 0, 0, buyer, _callbackData());
    }

    /// BUYER ASSETS BOUND ///

    function testBuyerAssetsBoundIsBufferPlusSourceable(uint256 buffered, uint256 parked) public {
        buffered = bound(buffered, 0, 1e30);
        parked = bound(parked, 0, 1e30);
        _fillBuffer(buffered);
        _park(parked);

        uint256 result = callback.buyerAssetsBound(bytes32(0), market, owner, _callbackData());

        assertEq(result, buffered + parked);
    }

    /// @dev The case the whole project is about: the position holds more than the bound reports,
    /// because sourcing the rest would cost more slippage than the envelope allows.
    function testBuyerAssetsBoundIsCappedBySlippageBudget(uint256 parked, uint256 cap) public {
        parked = bound(parked, 1, 1e30);
        cap = bound(cap, 0, parked - 1);
        _park(parked);
        callback.setSourceableCap(cap);

        uint256 result = callback.buyerAssetsBound(bytes32(0), market, owner, _callbackData());

        assertEq(result, cap);
        assertLt(result, parked, "bound should be below the parked balance");
    }

    /// @dev Diverges from Blue, which documents that it ignores the wrong-buyer case and leaves it
    /// to the routing layer.
    function testBuyerAssetsBoundIsZeroForAnyBuyerButOwner(address buyer) public {
        vm.assume(buyer != owner);
        _fillBuffer(1e18);
        _park(1e18);

        assertEq(callback.buyerAssetsBound(bytes32(0), market, buyer, _callbackData()), 0);
    }

    /// SKIM ///

    function testSkim(uint256 assets) public {
        assets = bound(assets, 0, 1e30);
        deal(address(otherToken), address(callback), assets);

        vm.expectEmit(address(callback));
        emit IMidnightBuyCallback.Skim(owner, address(otherToken), assets);
        vm.prank(owner);
        callback.skim(address(otherToken));

        assertEq(otherToken.balanceOf(address(callback)), 0);
        assertEq(otherToken.balanceOf(owner), assets);
    }

    /// @dev Blue's `skim` is permissionless because Blue's callback holds no buffer. Ours does, and
    /// emptying it immediately before a take forces the LP unwind path — the exact bleed the buffer
    /// exists to stop, at the cost of one call to anyone who wants it.
    function testSkimRevertsIfCallerIsNotOwner(address caller) public {
        vm.assume(caller != owner);

        vm.expectRevert(IMidnightBuyCallback.NotOwner.selector);
        vm.prank(caller);
        callback.skim(address(otherToken));
    }

    function testSkimCanEmptyTheBuffer(uint256 buffered) public {
        buffered = bound(buffered, 0, 1e30);
        _fillBuffer(buffered);

        vm.prank(owner);
        callback.skim(address(loanToken));

        assertEq(loanToken.balanceOf(address(callback)), 0);
        assertEq(loanToken.balanceOf(owner), buffered);
    }
}
