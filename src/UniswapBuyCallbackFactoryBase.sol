// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {IUniswapBuyCallbackFactory} from "./interfaces/IUniswapBuyCallbackFactory.sol";

/// @title UniswapBuyCallbackFactoryBase
/// @notice Registry and CREATE2 keying shared by the per-version callback factories.
///
/// @dev Forked in shape from `BlueBuyCallbackFactory` (GPL-2.0-or-later), with one substantive
/// change forced by the design.
///
/// @dev Blue's factory keys its registry on `(owner, salt)`, which is sound *there* because the
/// callback's constructor takes exactly `(owner, MIDNIGHT, BLUE)` and the last two are factory
/// immutables — so `(owner, salt)` already determines the CREATE2 address completely.
///
/// @dev That does not hold here. A doubleQuote callback's constructor also takes its safety
/// envelope: the price reference, the slippage budget, and whatever routing venue the adapter
/// pins. Those vary per deployment. Under Blue's key shape, one owner deploying the same salt with
/// a tighter slippage budget would land at a *different* CREATE2 address while overwriting the
/// registry entry of the first — leaving a live callback the factory no longer indexes, and a
/// `callbackOf` that silently reports the wrong envelope. So the key is the hash of the whole
/// envelope, and the user-supplied salt is one more input to it rather than the key itself.
///
/// @dev The derived key doubles as the CREATE2 salt, which makes the address itself a commitment
/// to the envelope: two callbacks at the same address cannot disagree about their price reference.
abstract contract UniswapBuyCallbackFactoryBase is IUniswapBuyCallbackFactory {
    /// @inheritdoc IUniswapBuyCallbackFactory
    address public immutable MIDNIGHT;

    /// @inheritdoc IUniswapBuyCallbackFactory
    mapping(bytes32 configSalt => address) public callbackOf;
    /// @inheritdoc IUniswapBuyCallbackFactory
    mapping(address callback => bool) public isUniswapBuyCallback;

    constructor(address midnight) {
        MIDNIGHT = midnight;
    }

    /// @dev Deployment key: every constructor argument, plus the caller's salt.
    /// @param venueParams The adapter's own constructor arguments, ABI-encoded. Opaque here.
    function _configSalt(
        address owner,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        bytes memory venueParams,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, priceRef, maxSlippageWad, venueParams, salt));
    }

    /// @dev Records a deployment and announces it. Idempotent: safe to call again for a callback
    /// that already exists, which is what a repeated `create...` does.
    function _register(address owner, bytes32 configSalt, address callback) internal {
        callbackOf[configSalt] = callback;
        isUniswapBuyCallback[callback] = true;

        emit CreateUniswapBuyCallback(msg.sender, owner, configSalt, callback);
    }
}
