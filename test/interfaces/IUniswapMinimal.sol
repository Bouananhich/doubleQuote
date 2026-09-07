// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

/// @dev Test-only Uniswap interfaces. The v3 ones the contracts themselves need now live in
/// `src/interfaces/IUniswapV3.sol` and are imported from there rather than redeclared here — two
/// copies of the same ABI is exactly how a fork test ends up passing against an interface the
/// production code does not use.
///
/// What remains here is what only the tests touch: v4 (until the D4 adapter lands) and ERC-20
/// metadata.

interface IPoolManagerV4 {
    function unlock(bytes calldata data) external returns (bytes memory);
}

interface IPositionManagerV4 {
    function poolManager() external view returns (address);
    function nextTokenId() external view returns (uint256);
}

/// @dev v4's `PositionManager` pulls payment through Permit2 rather than a plain `transferFrom`,
/// so minting a v4 position needs a two-step approval: the ERC-20 approves Permit2, then Permit2
/// approves the position manager. Only the test fixture needs this — the adapters never pay *into*
/// the position manager, they only decrease.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
