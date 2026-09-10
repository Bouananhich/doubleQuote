// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {UniswapV4BuyCallback} from "../src/UniswapV4BuyCallback.sol";
import {UniswapV4BuyCallbackFactory} from "../src/UniswapV4BuyCallbackFactory.sol";
import {IMidnightBuyCallback} from "../src/interfaces/IMidnightBuyCallback.sol";

import {V4ParkedBase} from "./V4ParkedBase.sol";
import {IERC20Meta} from "./interfaces/IUniswapMinimal.sol";
import {StubPriceRef} from "./mocks/StubPriceRef.sol";
import {V4PoolPusher} from "./mocks/V4PoolPusher.sol";

/// @notice **D7's attack on v4, and D10's port of D8's fix.** The same sandwich, the same shape,
/// the same answer — the residual swap every unwind drags behind it is sandwichable on any venue,
/// and the defence is the same reference-relative cost guard.
///
/// @dev This file exists because porting the *fix* without porting the *attack* left the guard
/// untested: deleting `require(cost <= MAX_SLIPPAGE_WAD, ...)` from both v4 adapters kept the whole
/// suite green. A guard nothing exercises is a guard nobody knows works.
///
/// @dev **Driven through `onBuy` directly**, not through a real `take()` as `SandwichV3` is. The v4
/// suites bind a bare `Market` rather than creating one on the deployed Midnight, and what is under
/// test here is the callback's own refusal, which `onBuy` reaches without a market at all. The v3
/// file already proves the refusal survives the trip through Midnight.
contract SandwichV4Test is V4ParkedBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Comfortably inside the honest bound on the route venue, so the baseline settles in one
    /// burn and the comparison is against a clean unwind.
    uint256 internal constant FILL = 400e6;

    /// @dev What the attacker pushes through the route venue ahead of the fill.
    uint256 internal constant FRONT_RUN = 3_000e6;

    uint256 internal constant ATTACKER_FLOAT = 100_000e6;

    UniswapV4BuyCallbackFactory internal factory;
    UniswapV4BuyCallback internal guarded;
    UniswapV4BuyCallback internal unguarded;
    UniswapV4BuyCallback.Parked internal parked;
    V4PoolPusher internal attacker;

    function setUp() public override {
        super.setUp();

        factory = new UniswapV4BuyCallbackFactory(MIDNIGHT, V4_POOL_MANAGER);
        parked =
            UniswapV4BuyCallback.Parked({key: poolKey, tickLower: tickLower, tickUpper: tickUpper, salt: bytes32(0)});

        guarded = UniswapV4BuyCallback(
            factory.createCallback(maker, priceRef, MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), bytes32(uint256(1)))
        );

        // The twin that still runs what D7 attacked. `2 * 2^96` is the square root of a price of
        // four, so the modelled cost of any sale is zero and the guard can never fire — which is
        // what makes the attacked settlement observable rather than merely refused.
        StubPriceRef neutralised = new StubPriceRef(158_456_325_028_528_675_187_087_900_672);
        unguarded = UniswapV4BuyCallback(
            factory.createCallback(maker, neutralised, MAX_SLIPPAGE_WAD, usdcUsdtRouteKey(), bytes32(uint256(2)))
        );

        _park(guarded);
        _park(unguarded);

        attacker = new V4PoolPusher(V4_POOL_MANAGER);
        deal(USDT, address(attacker), ATTACKER_FLOAT);
        deal(USDC, address(attacker), ATTACKER_FLOAT);
    }

    /// HELPERS ///

    /// @dev The custodial adapter burns only positions it owns, so each callback parks for itself.
    function _park(UniswapV4BuyCallback cb) internal {
        deal(USDC, maker, PARKED_USDC);
        deal(USDT, maker, PARKED_USDT);
        vm.startPrank(maker);
        IERC20Meta(USDC).approve(address(cb), type(uint256).max);
        IERC20Meta(USDT).approve(address(cb), type(uint256).max);
        cb.park(parked, _liquidityFor(PARKED_USDC, PARKED_USDT));
        vm.stopPrank();
    }

    function _callbackData() internal view returns (bytes memory) {
        return abi.encode(parked);
    }

    function _frontRun() internal {
        attacker.sell(usdcUsdtRouteKey(), false, FRONT_RUN);
    }

    function _liquidityOf(UniswapV4BuyCallback cb) internal view returns (uint128 liquidity) {
        (liquidity,,) = IPoolManager(V4_POOL_MANAGER)
            .getPositionInfo(poolKey.toId(), address(cb), tickLower, tickUpper, bytes32(0));
    }

    /// THE ATTACK ///

    /// @dev **What the guard is for.** Front-run the route venue, then fire the settlement the
    /// maker cannot decline. Unguarded, `onBuy` must deliver or revert, so a residual that fetches
    /// less does not settle for less — it burns more of the position until the loan is covered.
    /// Guarded, it refuses, and the position is exactly where it started.
    function test_theSandwichFailsClosedAndTheMakerKeepsEverything() public {
        uint128 liquidityBefore = _liquidityOf(guarded);
        uint256 bufferBefore = IERC20Meta(USDC).balanceOf(address(guarded));

        _frontRun();

        vm.expectPartialRevert(IMidnightBuyCallback.SourcingCostAboveBudget.selector);
        vm.prank(MIDNIGHT);
        guarded.onBuy(bytes32(0), market, FILL, 0, 0, maker, _callbackData());

        assertEq(_liquidityOf(guarded), liquidityBefore, "the attacked settlement moved the position");
        assertEq(IERC20Meta(USDC).balanceOf(address(guarded)), bufferBefore, "the attacked settlement spent buffer");
        assertEq(IERC20Meta(USDT).balanceOf(address(guarded)), 0, "residual stranded on the callback");
    }

    /// @dev The same attack against the unguarded twin, so the harm has a number rather than only a
    /// refusal. This is D7's measurement, reproduced on v4.
    function test_whatTheSandwichTakesWhenNothingRefusesIt() public {
        uint128 liquidityBefore = _liquidityOf(unguarded);

        uint256 snapshot = vm.snapshotState();
        vm.prank(MIDNIGHT);
        unguarded.onBuy(bytes32(0), market, FILL, 0, 0, maker, _callbackData());
        uint256 honestBurn = liquidityBefore - _liquidityOf(unguarded);
        vm.revertToState(snapshot);

        _frontRun();
        vm.prank(MIDNIGHT);
        unguarded.onBuy(bytes32(0), market, FILL, 0, 0, maker, _callbackData());
        uint256 attackedBurn = liquidityBefore - _liquidityOf(unguarded);

        emit log_named_uint("liquidity burnt, honest  ", honestBurn);
        emit log_named_uint("liquidity burnt, attacked", attackedBurn);
        emit log_named_uint("the maker pays this multiple of the honest burn", attackedBurn * 100 / honestBurn);

        // The maker pays in liquidity, not in price — the fill is delivered either way.
        assertGt(attackedBurn, honestBurn, "the attack cost the maker nothing");
    }
}
