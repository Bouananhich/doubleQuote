// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";

import {IUniswapV3Pool, IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3.sol";

/// @notice Test-only: trades against a v3 pool and leaves it where the trade put it.
///
/// @dev Exists so a test can make the *route* venue disagree with the *park* venue. The two are
/// independently chosen by design, so nothing keeps their prices together, and the burn sizing
/// values the residual at the parked pool's spot while the swap executes at the route pool's. That
/// gap is the realistic way the sizing comes up short.
///
/// @dev The swap runs with no price protection — the point is to move the pool, so a limit would
/// only get in the way.
contract PoolPusher is IUniswapV3SwapCallback {
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @dev Sized by amount rather than by a price limit. These stable pools are concentrated
    /// enough that naming a price is unusable — 2% off is already past the whole band, and the
    /// pusher walks out of the pool with every last token on the far side.
    function sell(address pool, bool zeroForOne, uint256 amountIn) external {
        IUniswapV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1,
                abi.encode(pool)
            );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "not the pool");

        if (amount0Delta > 0) {
            SafeTransferLib.safeTransfer(IUniswapV3Pool(pool).token0(), pool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            SafeTransferLib.safeTransfer(IUniswapV3Pool(pool).token1(), pool, uint256(amount1Delta));
        }
    }
}
