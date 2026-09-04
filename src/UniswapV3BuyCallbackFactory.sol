// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {UniswapBuyCallbackFactoryBase} from "./UniswapBuyCallbackFactoryBase.sol";
import {UniswapV3BuyCallback} from "./UniswapV3BuyCallback.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";

/// @title UniswapV3BuyCallbackFactory
/// @notice CREATE2 factory for `UniswapV3BuyCallback`.
///
/// @dev `POSITION_MANAGER` is a factory immutable rather than a per-callback one, for the same
/// reason `BlueBuyCallbackFactory` holds `BLUE`: it is canonical per chain and shared by every
/// callback this factory deploys, so it does not belong in the deployment key.
///
/// @dev The per-callback safety envelope — owner, price reference, slippage budget, routing pool —
/// does vary, and all of it is folded into the key. See `UniswapBuyCallbackFactoryBase`.
contract UniswapV3BuyCallbackFactory is UniswapBuyCallbackFactoryBase {
    address public immutable POSITION_MANAGER;

    constructor(address midnight, address positionManager) UniswapBuyCallbackFactoryBase(midnight) {
        POSITION_MANAGER = positionManager;
    }

    /// @notice Deploys the callback for this envelope, or returns the one already at it.
    /// @dev Deliberately callable by anyone on any owner's behalf: the deployed callback answers
    /// only to `owner`, so there is nothing to gain by front-running the deployment. Matches Blue.
    function createCallback(address owner, IPriceRef priceRef, uint256 maxSlippageWad, address routePool, bytes32 salt)
        external
        returns (address)
    {
        bytes32 configSalt = _configSalt(owner, priceRef, maxSlippageWad, abi.encode(routePool), salt);

        address callback = callbackOf[configSalt];
        if (callback == address(0)) {
            callback = address(
                new UniswapV3BuyCallback{salt: configSalt}(
                    owner, MIDNIGHT, priceRef, maxSlippageWad, POSITION_MANAGER, routePool
                )
            );
        }
        _register(owner, configSalt, callback);

        return callback;
    }

    /// @notice The deployment key for an envelope, and therefore the CREATE2 salt its callback
    /// lives at. Exposed so a taker or an indexer can verify an address commits to the envelope it
    /// claims.
    function computeConfigSalt(
        address owner,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address routePool,
        bytes32 salt
    ) external pure returns (bytes32) {
        return _configSalt(owner, priceRef, maxSlippageWad, abi.encode(routePool), salt);
    }
}
