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

    function test_buyerAssetsBoundReflectsTheParkedPosition() public view {
        uint256 bound = callback.buyerAssetsBound(bytes32(0), market, maker, _callbackData());

        assertGt(bound, 3_500e6, "bound does not reflect a ~4k position");
        assertLt(bound, 4_100e6, "bound exceeds what was parked");
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
