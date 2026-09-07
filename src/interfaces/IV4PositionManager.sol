// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IV4PositionManager
/// @notice The slice of Uniswap v4's `PositionManager` this project uses.
///
/// @dev Hand-written because `v4-periphery` is not a dependency. Taking it would drag in a second
/// compiler profile — `PositionManager.sol` is pinned to `0.8.26` — for the sake of an interface
/// and two constants, which is exactly the trade this project declined for `PoolManager` on D1.
///
/// @dev The action bytes below are `v4-periphery`'s `Actions` library. They are consensus with a
/// deployed contract rather than a local choice, so they are asserted against the real deployment
/// in `test/UniswapV4NftBuyCallback.t.sol` rather than trusted.
interface IV4PositionManager {
    /// @notice Runs a batch of liquidity actions inside the position manager's own `unlock`.
    /// @param unlockData `abi.encode(bytes actions, bytes[] params)`.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice The pool a position sits in, plus its packed range.
    /// @return poolKey The pool.
    /// @return info Packed: `poolId` in the top 200 bits, `tickUpper` at bit 32, `tickLower` at
    /// bit 8, subscriber flag in the low byte. Decoded by `V4PositionInfo`.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    /// @notice Liquidity currently in the position.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
    function nextTokenId() external view returns (uint256);
}

/// @notice `v4-periphery`'s action opcodes, only the ones this project encodes.
library V4Actions {
    uint256 internal constant INCREASE_LIQUIDITY = 0x00;
    uint256 internal constant DECREASE_LIQUIDITY = 0x01;
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    uint256 internal constant TAKE_PAIR = 0x11;
}

/// @notice Unpacks the position manager's `PositionInfo` word.
/// @dev The ticks are `int24` stored inside a `uint256`, so each needs a sign extension after the
/// shift — masking alone would read a negative tick as a huge positive one, and every tick below
/// parity on a USDC-quoted pool is negative.
library V4PositionInfo {
    function tickLower(uint256 info) internal pure returns (int24) {
        return int24(int256(info >> 8));
    }

    function tickUpper(uint256 info) internal pure returns (int24) {
        return int24(int256(info >> 32));
    }
}
