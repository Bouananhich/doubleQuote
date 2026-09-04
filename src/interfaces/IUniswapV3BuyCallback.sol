// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.4;

import {IMidnightBuyCallback} from "./IMidnightBuyCallback.sol";

interface IUniswapV3BuyCallback is IMidnightBuyCallback {
    /// ERRORS ///
    /// @notice The parked position's pool holds neither side as the offer's loan token.
    /// @dev The analogue of Blue's `InconsistentLoanToken`. Blue enforces
    /// `marketParams.loanToken == market.loanToken`; the pool-shaped version of that one invariant
    /// is that one currency of the parked pool must be the loan token. Everything else about the
    /// parking venue is unrestricted, on purpose.
    error LoanTokenNotInPool();

    /// @notice `ROUTE_POOL` does not trade the residual against the loan token.
    error RoutePairMismatch();

    /// @notice The v3 swap callback was invoked by something other than `ROUTE_POOL`.
    error NotRoutePool();

    /// @notice Unwinding the position produced less loan token than the fill needed.
    error InsufficientSourced();

    /// STORAGE GETTERS ///

    function POSITION_MANAGER() external view returns (address);
    function FACTORY() external view returns (address);

    /// @notice The pool the residual is swapped through. Immutable, and deliberately independent
    /// of where the position is parked.
    function ROUTE_POOL() external view returns (address);
}
