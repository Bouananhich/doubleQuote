// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UniswapBuyCallbackFactoryBase} from "./UniswapBuyCallbackFactoryBase.sol";
import {UniswapV4BuyCallback} from "./UniswapV4BuyCallback.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";

/// @title UniswapV4BuyCallbackFactory
/// @notice CREATE2 factory for `UniswapV4BuyCallback`.
///
/// @dev `POOL_MANAGER` is a factory immutable for the same reason `POSITION_MANAGER` is on the v3
/// factory: canonical per chain, shared by every callback deployed here, so it does not belong in
/// the deployment key.
///
/// @dev What does vary is the envelope — owner, price reference, slippage budget, and here the
/// route venue's whole `PoolKey` rather than a pool address. A v4 pool is not a contract, so the
/// venue parameter is five fields; encoding the struct keeps the key shape identical to v3's. See
/// `UniswapBuyCallbackFactoryBase`.
contract UniswapV4BuyCallbackFactory is UniswapBuyCallbackFactoryBase {
    address public immutable POOL_MANAGER;

    constructor(address midnight, address poolManager) UniswapBuyCallbackFactoryBase(midnight) {
        POOL_MANAGER = poolManager;
    }

    /// @notice Deploys the callback for this envelope, or returns the one already at it.
    /// @dev Callable by anyone on any owner's behalf: the deployed callback answers only to
    /// `owner`, so there is nothing to gain by front-running the deployment. Matches v3 and Blue.
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
                new UniswapV4BuyCallback{salt: configSalt}(
                    owner, MIDNIGHT, priceRef, maxSlippageWad, POOL_MANAGER, route
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
        PoolKey memory route,
        bytes32 salt
    ) external pure returns (bytes32) {
        return _configSalt(owner, priceRef, maxSlippageWad, abi.encode(route), salt);
    }
}
