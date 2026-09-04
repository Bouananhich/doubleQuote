// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.4;

import {IBuyCallback} from "midnight/src/interfaces/ICallbacks.sol";
import {Market} from "midnight/src/interfaces/IMidnight.sol";

import {IPriceRef} from "./IPriceRef.sol";

/// @title IMidnightBuyCallback
/// @notice The surface every doubleQuote buy callback shares, regardless of which Uniswap version
/// the capital is parked in.
///
/// @dev Forked in shape from Morpho's `IBlueBuyCallback` (GPL-2.0-or-later). Two deliberate
/// divergences, both recorded in `JOURNAL.md`:
///   - No `setAuthorization` / `setAuthorizationWithSig`. Those exist so an account can act on the
///     callback's *Blue* position; there is no analogue here, because the maker keeps custody of
///     the Uniswap position and can manage it directly through the position manager.
///   - `skim` is owner-only rather than permissionless. Blue's callback has no buffer, so sweeping
///     it to the owner cannot hurt anyone. Ours does, and sweeping the buffer immediately before a
///     take forces the LP unwind path — which is the dust-take bleed the buffer exists to stop.
interface IMidnightBuyCallback is IBuyCallback {
    /// ERRORS ///
    /// @notice `onBuy` was not called by Midnight.
    error NotMidnight();
    /// @notice A permissioned function was not called by `OWNER`.
    error NotOwner();
    /// @notice `onBuy` was called for an offer whose buyer is not `OWNER`.
    error NotOwnerBuyer();
    /// @notice A constructor argument that must be set was zero.
    error ZeroAddress();
    /// @notice The slippage budget exceeds `MAX_SLIPPAGE_CEILING_WAD`.
    error SlippageBudgetTooLarge();

    /// EVENTS ///

    event Skim(address indexed caller, address indexed token, uint256 assets);

    /// STORAGE GETTERS ///

    /// @notice The maker. The only account that may be the buyer of an offer this callback serves.
    function OWNER() external view returns (address);
    /// @notice The Midnight deployment allowed to call `onBuy`.
    function MIDNIGHT() external view returns (address);
    /// @notice The reference price sourcing is measured against. See `IPriceRef`.
    function PRICE_REF() external view returns (IPriceRef);
    /// @notice How far from `PRICE_REF` this callback will source, as a WAD fraction.
    function MAX_SLIPPAGE_WAD() external view returns (uint256);

    /// FUNCTIONS ///

    /// @notice Largest `buyerAssets` this callback can source for `buyer`.
    function buyerAssetsBound(bytes32 id, Market memory market, address buyer, bytes memory data)
        external
        view
        returns (uint256);

    /// @notice Sends this contract's whole balance of `token` to `OWNER`.
    function skim(address token) external;
}
