// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice Test-only: trades against a v4 pool and leaves it where the trade put it. The v4
/// counterpart of `PoolPusher`.
///
/// @dev Exists so a test can make the *route* venue disagree with the *park* venue. The two are
/// independently chosen by design, so nothing holds their prices together, and the burn sizing
/// values the residual at the parked pool's spot while the swap executes at the route pool's. That
/// gap is the realistic way the sizing comes up short.
///
/// @dev Sized by amount rather than by a price limit, for the reason recorded in `FRICTION.log`:
/// a concentrated pool has no "slightly dislocated" state, so naming a price walks through the
/// whole band and empties the far side. Sweep amounts instead.
contract V4PoolPusher is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable MANAGER;

    constructor(address manager) {
        MANAGER = IPoolManager(manager);
    }

    function sell(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        MANAGER.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "not the manager");

        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));

        MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency paid, Currency received) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        MANAGER.sync(paid);
        SafeTransferLib.safeTransfer(Currency.unwrap(paid), address(MANAGER), amountIn);
        MANAGER.settle();

        int256 owed = MANAGER.currencyDelta(address(this), received);
        if (owed > 0) MANAGER.take(received, address(this), uint256(owed));

        return "";
    }
}
