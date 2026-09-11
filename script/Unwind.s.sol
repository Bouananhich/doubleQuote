// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {IMidnight, Market, CollateralParams} from "midnight/src/interfaces/IMidnight.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

/// @title Unwind
/// @notice Returns every position `Demo.s.sol` opened, and consolidates the proceeds as USDC on the
/// maker.
///
/// @dev **The order is forced.** The maker's credit is lent to the taker, so it cannot be withdrawn
/// until the taker repays: run `taker()` first, then `maker()`. Running them the other way round
/// fails on Midnight's liquidity check rather than doing half the job, which is the good outcome.
///
/// @dev Every amount is read from chain at execution time rather than passed in. A stale debt or
/// liquidity figure here would leave dust behind in a position nobody is watching any more.
contract Unwind is Script {
    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant V3_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant REAL_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant MATURITY = 1798210800;
    uint256 internal constant RCF_THRESHOLD = 3_000_000_000;
    bytes32 internal constant MARKET_ID = 0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da;

    /// STEP 1 — the taker repays and gets the collateral back ///

    function taker() external {
        address maker = vm.envAddress("DEMO_MAKER");
        vm.startBroadcast();
        address me = msg.sender;

        uint256 debt = IMidnight(MIDNIGHT).debt(MARKET_ID, me);
        uint256 collateral = IMidnight(MIDNIGHT).collateral(MARKET_ID, me, 0);
        console.log("debt       : %s", debt);
        console.log("collateral : %s", collateral);

        if (debt > 0) {
            IERC20(USDC).approve(MIDNIGHT, debt);
            IMidnight(MIDNIGHT).repay(_market(), debt, me, address(0), hex"");
        }
        if (collateral > 0) {
            IMidnight(MIDNIGHT).withdrawCollateral(_market(), 0, collateral, me, me);
        }

        // Everything the taker holds goes home as USDC.
        uint256 btc = IERC20(CBBTC).balanceOf(me);
        if (btc > 0) {
            IERC20(CBBTC).approve(ROUTER, btc);
            ISwapRouter02(ROUTER)
                .exactInputSingle(ISwapRouter02.ExactInputSingleParams(CBBTC, USDC, 500, maker, btc, 0, 0));
        }
        uint256 usdc = IERC20(USDC).balanceOf(me);
        if (usdc > 0) IERC20(USDC).transfer(maker, usdc);

        vm.stopBroadcast();
        console.log("cbBTC sold : %s", btc);
        console.log("USDC sent  : %s", usdc);
    }

    /// STEP 2 — the maker closes everything ///

    function maker() external {
        uint256 tokenId = vm.envUint("DEMO_TOKEN_ID");
        address callback = vm.envAddress("DEMO_CALLBACK");
        vm.startBroadcast();
        address me = msg.sender;

        // The lending leg. `withdraw` takes units; the credit is denominated in them.
        uint256 credit = IMidnight(MIDNIGHT).credit(MARKET_ID, me);
        console.log("credit     : %s", credit);
        if (credit > 0) IMidnight(MIDNIGHT).withdraw(_market(), credit, me, me);

        // The LP leg. Burn all of it, then collect principal and fees in one call.
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER).positions(tokenId);
        console.log("liquidity  : %s", liquidity);
        if (liquidity > 0) {
            INonfungiblePositionManager(V3_POSITION_MANAGER)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(
                        tokenId, liquidity, 0, 0, block.timestamp + 30 minutes
                    )
                );
        }
        INonfungiblePositionManager(V3_POSITION_MANAGER)
            .collect(INonfungiblePositionManager.CollectParams(tokenId, me, type(uint128).max, type(uint128).max));

        // The buffer the callback kept, and the USDT leg.
        if (IERC20(USDC).balanceOf(callback) > 0) UniswapV3BuyCallback(callback).skim(USDC);
        if (IERC20(USDT).balanceOf(callback) > 0) UniswapV3BuyCallback(callback).skim(USDT);

        uint256 usdt = IERC20(USDT).balanceOf(me);
        if (usdt > 0) {
            IERC20(USDT).approve(ROUTER, usdt);
            ISwapRouter02(ROUTER)
                .exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDT, USDC, 100, me, usdt, 0, 0));
        }

        vm.stopBroadcast();
        console.log("USDT sold  : %s", usdt);
        console.log("final USDC : %s", IERC20(USDC).balanceOf(me));
    }

    function _market() internal pure returns (Market memory market) {
        market.chainId = 8453;
        market.midnight = MIDNIGHT;
        market.loanToken = USDC;
        market.maturity = MATURITY;
        market.rcfThreshold = RCF_THRESHOLD;
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] =
            CollateralParams({token: CBBTC, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: REAL_ORACLE});
    }
}
