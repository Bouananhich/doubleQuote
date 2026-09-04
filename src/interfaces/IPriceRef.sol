// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.4;

/// @title IPriceRef
/// @notice A manipulation-resistant price the callback measures its own execution against.
///
/// @dev The callback never trusts the pool it is about to trade in to tell it what a fair price is
/// — that is the sandwich. It reads a reference from here instead, and refuses to source more than
/// `MAX_SLIPPAGE_WAD` away from it.
///
/// @dev Implementations are chosen by the maker and fixed at deployment as an immutable on the
/// callback. They are deliberately *not* reachable through `callbackData`, which is maker-signed at
/// offer creation: a maker who can be talked into signing one offer could be talked into signing
/// one that names a null oracle.
///
/// @dev Two rules constrain implementations, both from `JOURNAL.md`:
///   1. Never read the reference from a hook attached to the pool the position is parked in. A hook
///      owner can backdoor the feed and is precisely the party that profits from breaking it.
///   2. Park, route and reference are three independently chosen venues. An implementation must not
///      assume the reference pool is either of the other two.
///
/// @dev Because `buyerAssetsBound` is an `external view` executing in the EVM, a reference must be
/// readable on-chain. An indexed off-chain feed cannot back this interface — bridging one in would
/// add exactly the push-oracle trust assumption the project exists to attack.
interface IPriceRef {
    /// @notice Thrown when the implementation has no reference configured for this pair.
    error PairNotSupported(address token0, address token1);

    /// @notice Reference price of the `token0`/`token1` pair as a Q64.96 square root, in the same
    /// orientation Uniswap uses: the price of `token0` denominated in `token1`.
    /// @dev `token0` and `token1` are passed in Uniswap's canonical order, `token0 < token1`.
    /// Implementations should revert with `PairNotSupported` rather than return a guess.
    /// @dev Reverting here reverts `buyerAssetsBound`, which a routing layer must read as "no
    /// bound available", not as "zero".
    function refSqrtPriceX96(address token0, address token1) external view returns (uint160);
}
