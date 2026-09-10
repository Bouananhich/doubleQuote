// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPriceRef} from "../src/interfaces/IPriceRef.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {V3TwapRef} from "../src/price-refs/V3TwapRef.sol";

import {ForkBase} from "./ForkBase.sol";
import {MockObservePool} from "./mocks/MockObservePool.sol";
import {PoolPusher} from "./mocks/PoolPusher.sol";

/// @notice D8: the production price reference, and the property that makes it worth having.
///
/// @dev The security claim is not "a TWAP is manipulation-resistant" in the abstract — it is that
/// **the specific attack D7 measured moves this number by almost nothing**, while moving spot by
/// enough to take 61.86% of a fill. `test_aSingleBlockPushBarelyMovesTheReference` is that claim
/// with a ratio attached, and it is the reason `onBuy` can measure execution against this and
/// refuse the fill.
contract V3TwapRefTest is ForkBase {
    /// @dev 30 minutes. Long enough that a single block is ~0.1% of the window on Base's 2s
    /// blocks, short enough to track a genuine repricing within the hour.
    uint32 internal constant WINDOW = 1800;

    V3TwapRef internal ref;

    function setUp() public override {
        super.setUp();
        ref = new V3TwapRef(POOL_USDC_USDT_100, WINDOW);
    }

    /// WIRING ///

    function test_constructorReadsThePairFromThePool() public view {
        assertEq(ref.POOL(), POOL_USDC_USDT_100, "pool");
        assertEq(ref.TOKEN0(), USDC, "token0");
        assertEq(ref.TOKEN1(), USDT, "token1");
        assertEq(ref.WINDOW(), WINDOW, "window");
    }

    /// @dev The pair is checked in canonical order and nothing else is served — including the same
    /// pair passed the wrong way round, which is a caller bug worth failing on rather than
    /// silently inverting.
    function test_refRevertsForAnyPairButItsOwn() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceRef.PairNotSupported.selector, USDC, CBBTC));
        ref.refSqrtPriceX96(USDC, CBBTC);

        vm.expectRevert(abi.encodeWithSelector(IPriceRef.PairNotSupported.selector, USDT, USDC));
        ref.refSqrtPriceX96(USDT, USDC);
    }

    /// @dev The reference tracks the pool it reads. Both are near par for this pair, and the TWAP
    /// sits within a few ticks of spot on an unmanipulated venue.
    function test_theReferenceAgreesWithSpotOnAQuietPool() public view {
        (uint160 spotSqrtPriceX96, int24 spotTick,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();

        int24 mean = ref.meanTick();
        assertApproxEqAbs(int256(mean), int256(spotTick), 5, "TWAP is far from spot on a quiet pool");

        uint160 refSqrt = ref.refSqrtPriceX96(USDC, USDT);
        assertEq(refSqrt, TickMath.getSqrtPriceAtTick(mean), "sqrt price does not match the mean tick");
        assertApproxEqRel(uint256(refSqrt), uint256(spotSqrtPriceX96), 0.001e18, "reference is far from spot");
    }

    /// THE SECURITY PROPERTY ///

    /// @dev **This is why D8 works.** A front-run moves spot as far as the attacker cares to pay
    /// for; it moves an arithmetic-mean tick over 30 minutes by nothing at all in the block it
    /// lands in, because that block contributes zero elapsed seconds to the mean.
    ///
    /// @dev The push here is aimed at the pool the reference *itself* reads, which is the hardest
    /// case — a maker referencing a different venue from the one under attack is not moved at all.
    /// 100,000 USDT drags spot from tick 7 to 18,819, a ~7x price move, and the reference stays on
    /// 7 exactly. That is the entire security argument for D8 in one assertion.
    ///
    /// @dev Worth noting what the probe also showed: this "deep" pool is deep only in a narrow
    /// band. Its concentrated liquidity is exhausted within a few thousand USDT and price then
    /// runs away — the same shape D6 found on the 0.05% pool, where the whole book above spot was
    /// eight ticks. Depth on a stable pair is a statement about a band, not about a pool.
    function test_aSingleBlockPushBarelyMovesTheReference() public {
        int24 meanBefore = ref.meanTick();
        (, int24 spotBefore,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();

        PoolPusher pusher = new PoolPusher();
        deal(USDT, address(pusher), 100_000e6);
        pusher.sell(POOL_USDC_USDT_100, false, 100_000e6);

        (, int24 spotAfter,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();
        int24 meanSameBlock = ref.meanTick();

        // And one Base block later, so the "blockTime / WINDOW" claim is a number rather than a
        // story: 2 seconds of an 1800-second window.
        vm.warp(block.timestamp + 2);
        int24 meanOneBlockLater = ref.meanTick();

        emit log_named_int("spot tick before", spotBefore);
        emit log_named_int("spot tick after", spotAfter);
        emit log_named_int("mean tick before", meanBefore);
        emit log_named_int("mean tick, same block", meanSameBlock);
        emit log_named_int("mean tick, one block later", meanOneBlockLater);

        assertGt(spotAfter, spotBefore + 10_000, "the push did not move spot far");
        assertEq(meanSameBlock, meanBefore, "a same-block push moved the TWAP");

        // A block of exposure moves the reference by well under 1% of the displacement it would
        // have to absorb to let the attack through.
        int256 displacement = int256(spotAfter) - int256(spotBefore);
        int256 drift = int256(meanOneBlockLater) - int256(meanBefore);
        assertGt(drift, int256(0), "the TWAP should register something after a block");
        assertLt(drift * 100, displacement, "one block moved the TWAP more than 1% of the push");
    }

    /// @dev And the reference does follow a *sustained* move, which is the other half of being
    /// usable: a window that never moves would refuse every fill after a genuine repricing. Held
    /// for the whole window, the mean converges on the new spot exactly.
    function test_theReferenceFollowsASustainedMove() public {
        int24 meanBefore = ref.meanTick();

        PoolPusher pusher = new PoolPusher();
        deal(USDT, address(pusher), 100_000e6);
        pusher.sell(POOL_USDC_USDT_100, false, 100_000e6);
        (, int24 spotAfter,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();

        // Hold the pool there for the whole window instead of for one block.
        vm.warp(block.timestamp + WINDOW);

        int24 meanAfter = ref.meanTick();
        emit log_named_int("mean tick after holding for the window", meanAfter);

        assertGt(meanAfter, meanBefore, "the TWAP never caught up with a sustained move");
        assertEq(meanAfter, spotAfter, "a full window of exposure should converge on spot");
    }

    /// ORACLE ARITHMETIC ///

    /// @dev The mean tick has to round *down*, not toward zero. Solidity's `/` truncates toward
    /// zero, so a negative cumulative delta that does not divide evenly would round up and tilt
    /// the reference in one direction — a systematic bias on any pair sitting just below tick
    /// zero, which is most stable pairs quoted the other way round.
    function test_theMeanTickRoundsDownRatherThanTowardZero() public {
        MockObservePool pool = new MockObservePool(USDC, USDT);
        pool.setCumulatives(0, 0);
        V3TwapRef mocked = new V3TwapRef(address(pool), 100);

        // Divides evenly: -500 / 100 = -5, no correction.
        pool.setCumulatives(0, -500);
        assertEq(mocked.meanTick(), int24(-5), "even negative division");

        // Does not divide evenly: -550 / 100 truncates to -5, and the mean is -6.
        pool.setCumulatives(0, -550);
        assertEq(mocked.meanTick(), int24(-6), "negative division did not round down");

        // Positive is unaffected — truncation toward zero is already rounding down.
        pool.setCumulatives(0, 550);
        assertEq(mocked.meanTick(), int24(5), "positive division should not be corrected");

        // The accumulators are differences, so a non-zero starting point changes nothing.
        pool.setCumulatives(1_000_000, 999_450);
        assertEq(mocked.meanTick(), int24(-6), "mean should depend only on the delta");
    }

    /// @dev A pool too young to serve the window fails at deployment, naming the pool and the
    /// window, rather than reverting `OLD` at every settlement afterwards.
    function test_constructorRejectsAPoolThatCannotServeTheWindow() public {
        MockObservePool pool = new MockObservePool(USDC, USDT);
        pool.setReverts(true);

        vm.expectRevert(
            abi.encodeWithSelector(V3TwapRef.InsufficientObservationHistory.selector, address(pool), WINDOW)
        );
        new V3TwapRef(address(pool), WINDOW);
    }

    function test_constructorRejectsAZeroWindowAndAZeroPool() public {
        vm.expectRevert(V3TwapRef.ZeroWindow.selector);
        new V3TwapRef(POOL_USDC_USDT_100, 0);

        vm.expectRevert(V3TwapRef.ZeroPool.selector);
        new V3TwapRef(address(0), WINDOW);
    }
}
