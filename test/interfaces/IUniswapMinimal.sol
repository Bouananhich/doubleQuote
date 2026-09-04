// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

/// @dev Minimal Uniswap interfaces, declared locally rather than imported.
///
/// Uniswap's own sources cannot be compiled in this project's profile: v3 implementations are
/// hard-pinned to `=0.7.6`, and v4's `PoolManager.sol` / `PositionManager.sol` to exactly
/// `0.8.26`, while this project follows Midnight at `0.8.34`. Binding the already-deployed Base
/// contracts through hand-written interfaces keeps the build to a single compiler profile.
///
/// Only the members actually used are declared. Extend as the adapters need more.

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    /// @dev The v3 price reference this project relies on. v4 has no equivalent in core.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface INonfungiblePositionManager {
    function factory() external view returns (address);
}

interface IPoolManagerV4 {
    function unlock(bytes calldata data) external returns (bytes memory);
}

interface IPositionManagerV4 {
    function poolManager() external view returns (address);
    function nextTokenId() external view returns (uint256);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}
