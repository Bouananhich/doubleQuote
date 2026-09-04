// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.4;

/// @title IUniswapBuyCallbackFactory
/// @notice Shared surface of the per-adapter CREATE2 factories.
/// @dev Each Uniswap version gets its own factory, because each deploys a different bytecode. What
/// they share — the registry, and how a deployment key is derived — lives in
/// `UniswapBuyCallbackFactoryBase`.
interface IUniswapBuyCallbackFactory {
    /// @notice Emitted on every call to a `create...` function, including the ones that return an
    /// already-deployed callback.
    event CreateUniswapBuyCallback(
        address indexed caller, address indexed owner, bytes32 indexed configSalt, address callback
    );

    /// @notice The Midnight deployment every callback from this factory is bound to.
    function MIDNIGHT() external view returns (address);

    /// @notice The callback deployed under a given configuration key, or zero.
    /// @dev Keyed by the derived `configSalt`, not by `(owner, salt)`. See
    /// `UniswapBuyCallbackFactoryBase._configSalt`.
    function callbackOf(bytes32 configSalt) external view returns (address);

    /// @notice Whether this factory deployed `callback`.
    function isUniswapBuyCallback(address callback) external view returns (bool);
}
