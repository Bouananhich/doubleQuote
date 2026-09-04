// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

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

        vm.prank(MIDNIGHT);
        bytes32 result = callback.onBuy(bytes32(0), market, buyerAssets, 0, 0, maker, _callbackData());

        assertEq(result, CALLBACK_SUCCESS, "callback did not succeed");
        assertGe(IERC20Meta(USDC).balanceOf(address(callback)), buyerAssets, "not enough loan token sourced");
        assertEq(IERC20Meta(USDC).allowance(address(callback), MIDNIGHT), buyerAssets, "Midnight not approved");

        // D2 unwinds in full; D3 makes this partial.
        assertEq(_liquidity(), 0, "position not unwound");

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

    /// @dev A stable pair round-trips near 1:1, so a full unwind of 10k+10k should surface roughly
    /// 20k USDC. Loose bounds — this is checking the residual actually got swapped, not pricing it.
    function test_fullUnwindRecoversBothSidesAsLoanToken() public {
        vm.prank(MIDNIGHT);
        callback.onBuy(bytes32(0), market, 1e6, 0, 0, maker, _callbackData());

        uint256 recovered = IERC20Meta(USDC).balanceOf(address(callback));
        assertGt(recovered, 19_000e6, "residual does not look swapped");
        assertLt(recovered, 20_100e6, "recovered more than was parked");
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
