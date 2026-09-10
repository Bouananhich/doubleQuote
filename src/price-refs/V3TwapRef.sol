// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPriceRef} from "../interfaces/IPriceRef.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";

/// @title V3TwapRef
/// @notice The production `IPriceRef`: an arithmetic-mean-tick TWAP read from a Uniswap **v3**
/// pool's built-in oracle.
///
/// @dev **Why v3 carries the reference for a project that ships both.** v3 accumulates tick
/// observations inside the pool and exposes them through `observe()`, so a manipulation-resistant
/// price is one `external view` away with no extra contract, no keeper and no push feed. v4 core
/// has no equivalent — its oracle is a hook, which is precisely what invariant 4 forbids reading
/// from when the hook sits on the venue the maker parked in. That asymmetry is why the build order
/// is v3-first and why v4 adapters at D10 point their `PRICE_REF` at a v3 pool too.
///
/// @dev **One pair, fixed at deployment, no admin.** The pool is an immutable and there is no
/// setter, no owner and no upgrade path. A price reference with a privileged writer is a push
/// oracle wearing a different hat, and the whole point of `buyerAssetsBound` measuring against this
/// is that nobody — the maker included — can move it between the quote and the settlement. A maker
/// who wants a different reference deploys a different one and points a new callback at it.
///
/// @dev **The window is the security parameter.** Manipulating an arithmetic-mean tick over
/// `WINDOW` seconds costs an attacker the price impact of holding the pool away from its true
/// price for that long, against arbitrageurs pulling it back every block. Single-block
/// manipulation — the D7 attack — moves it by roughly `blockTime / WINDOW` of the displacement,
/// which for a 30-minute window on a 2-second chain is under a tenth of a percent of it. Short
/// windows are cheap to move; long windows lag a real repricing and will refuse honest fills after
/// a genuine market move. This contract takes no position on the right value and stores whatever
/// the maker chose.
///
/// @dev **The reference venue is a third independent choice.** Nothing here assumes this pool is
/// the one the position is parked in or the one the residual routes through, and a maker should
/// prefer the deepest pool for the pair regardless of where they park — depth is what makes the
/// TWAP expensive to move, and it is unrelated to where the maker wants to earn fees.
contract V3TwapRef is IPriceRef {
    /// @notice Thrown when the pool cannot serve `WINDOW` seconds of history.
    /// @dev Checked at deployment rather than discovered at settlement. A v3 pool's
    /// `observationCardinality` starts at 1 and only ever grows, so a pool that can serve the
    /// window now can still serve it later — which makes the constructor the honest place to fail.
    error InsufficientObservationHistory(address pool, uint32 window);

    /// @notice Thrown when the window is zero, which would divide by zero.
    error ZeroWindow();

    /// @notice Thrown when the pool address is zero.
    error ZeroPool();

    /// @notice The v3 pool whose oracle backs this reference.
    address public immutable POOL;
    /// @notice The pair this reference serves, in Uniswap's canonical order.
    address public immutable TOKEN0;
    address public immutable TOKEN1;
    /// @notice TWAP window, in seconds.
    uint32 public immutable WINDOW;

    constructor(address pool, uint32 window) {
        require(pool != address(0), ZeroPool());
        require(window > 0, ZeroWindow());

        POOL = pool;
        TOKEN0 = IUniswapV3Pool(pool).token0();
        TOKEN1 = IUniswapV3Pool(pool).token1();
        WINDOW = window;

        // Prove the oracle can answer before anyone signs an offer against it. Without this, a
        // pool with too few observations deploys fine, quotes fine — `buyerAssetsBound` reverts,
        // which a routing layer reads as "no bound" — and then reverts every settlement, which the
        // taker eats. `observe` reverts with the string `OLD`; this restates it as a typed error
        // naming the pool and the window, at the only moment anyone can act on it.
        try IUniswapV3Pool(pool).observe(_secondsAgos(window)) returns (int56[] memory, uint160[] memory) {}
        catch {
            revert InsufficientObservationHistory(pool, window);
        }
    }

    /// @inheritdoc IPriceRef
    function refSqrtPriceX96(address token0, address token1) external view returns (uint160) {
        if (token0 != TOKEN0 || token1 != TOKEN1) revert PairNotSupported(token0, token1);

        return TickMath.getSqrtPriceAtTick(meanTick());
    }

    /// @notice The arithmetic mean tick over `WINDOW`, as `observe()` reports it.
    /// @dev Public because it is the number a maker actually wants to look at when choosing a
    /// window, and because a test asserting the sqrt-price conversion needs the tick it came from.
    function meanTick() public view returns (int24) {
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(POOL).observe(_secondsAgos(WINDOW));

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 mean = int24(delta / int56(uint56(WINDOW)));

        // Solidity truncates integer division toward zero; the mean tick has to round *down*, the
        // way `OracleLibrary.consult` does. Without this a negative cumulative delta that does not
        // divide evenly rounds up, biasing the reference in one direction only — which on a pair
        // whose price sits just below tick zero is a systematic tilt rather than a rounding wobble.
        if (delta < 0 && delta % int56(uint56(WINDOW)) != 0) --mean;

        return mean;
    }

    function _secondsAgos(uint32 window) private pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
    }
}
