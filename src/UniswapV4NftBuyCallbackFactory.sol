// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UniswapBuyCallbackFactoryBase} from "./UniswapBuyCallbackFactoryBase.sol";
import {UniswapV4NftBuyCallback} from "./UniswapV4NftBuyCallback.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";

/// @title UniswapV4NftBuyCallbackFactory
/// @notice CREATE2 factory for `UniswapV4NftBuyCallback`.
///
/// @dev Both v4 managers are factory immutables: canonical per chain, shared by every callback
/// deployed here, so neither belongs in the deployment key. The key covers the envelope that
/// varies — owner, price reference, slippage budget, route venue.
contract UniswapV4NftBuyCallbackFactory is UniswapBuyCallbackFactoryBase {
    address public immutable POOL_MANAGER;
    address public immutable POSITION_MANAGER;

    constructor(address midnight, address poolManager, address positionManager)
        UniswapBuyCallbackFactoryBase(midnight)
    {
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
    }

    /// @notice Deploys the callback for this envelope, or returns the one already at it.
    function createCallback(
        address owner,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        PoolKey memory route,
        bytes32 salt
    ) external returns (address) {
        bytes32 configSalt = _configSalt(owner, priceRef, maxSlippageWad, abi.encode(route), salt);

        address callback = callbackOf[configSalt];
        if (callback == address(0)) {
            callback = address(
                new UniswapV4NftBuyCallback{salt: configSalt}(
                    owner, MIDNIGHT, priceRef, maxSlippageWad, POOL_MANAGER, POSITION_MANAGER, route
                )
            );
        }
        _register(owner, configSalt, callback);

        return callback;
    }
}
