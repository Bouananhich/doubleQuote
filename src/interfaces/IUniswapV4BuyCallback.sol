// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IUniswapV4BuyCallback
/// @notice Errors and getters for the Uniswap v4 adapters.
interface IUniswapV4BuyCallback {
    /// @notice The loan token is not one of the parked pool's two currencies.
    error LoanCurrencyNotInPool();

    /// @notice The route venue cannot trade the residual for the loan token.
    error RoutePairMismatch();

    /// @notice `unlockCallback` was called by something other than the pool manager.
    error NotPoolManager();

    /// @notice The unwind did not raise the shortfall. Fail closed rather than fill badly.
    error InsufficientSourced();

    /// @notice A currency in the parked or route pool is the native asset.
    /// @dev Settling native value needs a payable path and a receive hook, which this adapter
    /// deliberately does not have. See the note on `UniswapV4BuyCallback`.
    error NativeCurrencyUnsupported();

    /// @notice The pool manager, and the only address `unlockCallback` accepts.
    function POOL_MANAGER() external view returns (address);

    /// @notice The venue the residual swap executes on. Immutable: part of the safety envelope.
    function routeKey() external view returns (PoolKey memory);
}
