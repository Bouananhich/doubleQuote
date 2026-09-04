// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

/// @dev Shared Base-fork setup. Every address below was verified on-chain at `FORK_BLOCK`
/// (see `test/ForkSanity.t.sol`, which is the check that they still resolve).
abstract contract ForkBase is Test {
    /// @dev Pinned so tick data, pool liquidity and the bound math cross-check are reproducible.
    uint256 internal constant FORK_BLOCK = 50_875_000;

    string internal constant DEFAULT_BASE_RPC = "https://mainnet.base.org";

    // --- Midnight ---

    /// @dev Verified: responds to configurator()/feeSetter()/feeClaimer()/tickSpacingSetter().
    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;

    // --- Uniswap v3 ---

    address internal constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant V3_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    // --- Uniswap v4 ---

    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;

    // --- Tokens ---

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    // --- Pools ---

    /// @dev The stress venue. Parking USDC here is unpriced short gamma on BTC; it exists so the
    /// sandwich demo has somewhere the attack is actually economic.
    address internal constant POOL_CBBTC_USDC_500 = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    /// @dev The product venue. ~50x the liquidity of the 0.05% USDC/USDT pool at FORK_BLOCK.
    address internal constant POOL_USDC_USDT_100 = 0xD56da2B74bA826f19015E6B7Dd9Dae1903E85DA1;

    function setUp() public virtual {
        vm.createSelectFork(_baseRpcUrl(), FORK_BLOCK);
    }

    /// @dev Falls back to the public endpoint when `BASE_RPC_URL` is unset *or empty*. The empty
    /// case is not hypothetical: GitHub Actions expands a missing secret to an empty string, which
    /// `vm.envOr` treats as set, so a plain `envOr` would hand `createSelectFork` an empty URL.
    function _baseRpcUrl() internal view returns (string memory url) {
        url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) url = DEFAULT_BASE_RPC;
    }
}
