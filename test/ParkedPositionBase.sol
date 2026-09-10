// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {UniswapV3BuyCallbackFactory} from "../src/UniswapV3BuyCallbackFactory.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

import {ForkBase} from "./ForkBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";
import {StubPriceRef} from "./mocks/StubPriceRef.sol";

/// @notice The scenario every v3 test starts from: a maker with a real position in the real
/// USDC/USDT 0.01% pool, and a callback approved to unwind it.
///
/// @dev One fixture, three suites — `UniswapV3BuyCallback.t.sol` drives `onBuy` directly, while
/// `MidnightIntegration.t.sol` and `SandwichV3.t.sol` drive it through a real `take()` on top of
/// `MidnightMarketBase`. They ask different questions of the same setup, so the setup belongs here
/// rather than in any one of them.
///
/// @dev What is deliberately *not* here is the `Market`. The suites need genuinely different ones —
/// a bare struct that is never touched on-chain versus a real market with collateral params,
/// created against the deployed Midnight — and collapsing them would mean the unit suite silently
/// depending on Midnight's market rules. The real one lives in `MidnightMarketBase`.
abstract contract ParkedPositionBase is ForkBase {
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
    uint256 internal tokenId;

    function setUp() public virtual override {
        super.setUp();

        priceRef = new StubPriceRef(1 << 96);
        factory = new UniswapV3BuyCallbackFactory(MIDNIGHT, V3_POSITION_MANAGER);
        callback = UniswapV3BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(0))
        );

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

    /// @dev A second callback over the same parked position, differing only in budget and route.
    /// @dev Shared rather than per-suite: the quoting tests point one at a thinner venue to prove
    /// park and route are independent, and the griefing suite points one at a venue an attacker can
    /// actually afford to move.
    function _routedCallback(uint256 budgetWad, address routePool, uint256 salt)
        internal
        returns (UniswapV3BuyCallback routed)
    {
        routed = UniswapV3BuyCallback(factory.createCallback(maker, priceRef, budgetWad, routePool, bytes32(salt)));
    }

    /// @dev ERC-721 approval is a single slot per `tokenId`, so approving one callback revokes the
    /// last. Every use site approves at the point of use; approving inside `_routedCallback` would
    /// silently disarm whichever callback was built first, and an `onBuy` that reverts on approval
    /// satisfies any assertion about what it sourced by never running.
    function _approve(UniswapV3BuyCallback routed) internal {
        vm.prank(maker);
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(address(routed), tokenId);
    }

    /// @dev What the maker's offer carries: the `tokenId` and nothing else. Everything else about
    /// the position is read from the position manager at execution time.
    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(tokenId);
    }

    function _liquidity() internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER).positions(tokenId);
    }
}
