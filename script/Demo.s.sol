// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {IMidnight, Market, Offer, CollateralParams} from "midnight/src/interfaces/IMidnight.sol";
import {MAX_TICK} from "midnight/src/libraries/TickLib.sol";

import {UniswapV3BuyCallback} from "../src/UniswapV3BuyCallback.sol";
import {UniswapV3BuyCallbackFactory} from "../src/UniswapV3BuyCallbackFactory.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {IPriceRef} from "../src/interfaces/IPriceRef.sol";
import {V3TwapRef} from "../src/price-refs/V3TwapRef.sol";

import {DemoRatifier} from "./DemoRatifier.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev A fixed cbBTC price, so the demo's collateral leg is inert and honest about it. The
/// collateral exists only to let the taker borrow; nothing in this project depends on its price.
contract DemoOracle {
    uint256 public constant price = 1e39;
}

/// @title Demo
/// @notice The mainnet demo, one transaction per step, so each one can be shown as it lands.
///
/// @dev **The story.** Ten dollars of USDC and ten of USDT go into a real Uniswap v3 position, where
/// they earn fees. The same capital simultaneously quotes a fixed-rate loan on Midnight. A taker
/// fills the loan; in a single transaction the position unwinds just enough to cover it, the
/// residual is sold, and the loan settles. What is left keeps earning.
///
/// @dev **Sizing is pre-flighted**, not guessed — see `test/DemoPreflight.t.sol`, which runs this
/// exact configuration against a Base fork. At ten dollars a side the bound is **19.871711 USDC**
/// and a round **10 USDC fill burns exactly half the position**, which is the number worth showing:
/// half the LP settles the loan, half stays in the pool earning.
///
/// @dev **What each step costs.** Deployment is ~$0.17 at Base's current gas. The capital is ~$20
/// for the position and ~$26 of cbBTC for the taker's collateral, and both come back.
///
/// @dev Run with `--sig`, one step at a time. See `DEMO.md`.
contract Demo is Script {
    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant V3_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant POOL_USDC_USDT_100 = 0xD56da2B74bA826f19015E6B7Dd9Dae1903E85DA1;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /// @dev Both enabled on the deployed Midnight; asserted in `MidnightIntegrationTest`.
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    /// @dev 1bp, and safe here only because the route venue *is* the reference venue — see D10 in
    /// `JOURNAL.md` for why a maker routing elsewhere needs a wider budget.
    uint256 internal constant MAX_SLIPPAGE_WAD = 0.0001e18;
    uint32 internal constant REF_WINDOW = 1800;

    uint256 internal constant DEMO_USDC = 10e6;
    uint256 internal constant DEMO_USDT = 10e6;

    /// STEP 1 — the maker deploys ///

    function deploy() external {
        address maker = msg.sender;
        vm.startBroadcast();

        DemoOracle oracle = new DemoOracle();
        DemoRatifier ratifier = new DemoRatifier(maker);
        V3TwapRef priceRef = new V3TwapRef(POOL_USDC_USDT_100, REF_WINDOW);
        UniswapV3BuyCallbackFactory factory = new UniswapV3BuyCallbackFactory(MIDNIGHT, V3_POSITION_MANAGER);
        address callback = factory.createCallback(
            maker, IPriceRef(address(priceRef)), MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(0)
        );

        // The maker's consent, and the only authorisation Midnight asks for: `take` carries no
        // signature, so this is what makes the offer fillable.
        IMidnight(MIDNIGHT).setIsAuthorized(address(ratifier), true, maker);

        vm.stopBroadcast();

        console.log("DEMO_ORACLE=%s", address(oracle));
        console.log("DEMO_RATIFIER=%s", address(ratifier));
        console.log("DEMO_PRICE_REF=%s", address(priceRef));
        console.log("DEMO_FACTORY=%s", address(factory));
        console.log("DEMO_CALLBACK=%s", callback);
    }

    /// STEP 2 — the maker parks ten dollars a side ///

    function park() external {
        address maker = msg.sender;
        address callback = vm.envAddress("DEMO_CALLBACK");

        (, int24 tick,,,,,) = IUniswapV3Pool(POOL_USDC_USDT_100).slot0();
        int24 spacing = IUniswapV3Pool(POOL_USDC_USDT_100).tickSpacing();

        vm.startBroadcast();

        IERC20(USDC).approve(V3_POSITION_MANAGER, DEMO_USDC);
        IERC20(USDT).approve(V3_POSITION_MANAGER, DEMO_USDT);

        (uint256 tokenId,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER)
            .mint(
                INonfungiblePositionManager.MintParams({
                    token0: USDC,
                    token1: USDT,
                    fee: 100,
                    tickLower: ((tick - 50) / spacing) * spacing,
                    tickUpper: ((tick + 50) / spacing) * spacing,
                    amount0Desired: DEMO_USDC,
                    amount1Desired: DEMO_USDT,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: maker,
                    deadline: block.timestamp + 30 minutes
                })
            );

        // The whole custody story: the maker keeps the NFT and approves the callback for it.
        INonfungiblePositionManager(V3_POSITION_MANAGER).approve(callback, tokenId);

        IMidnight(MIDNIGHT).touchMarket(_market());

        vm.stopBroadcast();

        console.log("DEMO_TOKEN_ID=%s", tokenId);
        console.log("Position: https://app.uniswap.org/positions/v3/base/%s", tokenId);
    }

    /// STEP 3 — what the maker is quoting, read for free ///

    function quote() external view {
        address maker = vm.envAddress("DEMO_MAKER");
        address callback = vm.envAddress("DEMO_CALLBACK");
        uint256 tokenId = vm.envUint("DEMO_TOKEN_ID");

        uint256 bound =
            UniswapV3BuyCallback(callback).buyerAssetsBound(bytes32(0), _market(), maker, abi.encode(tokenId));

        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(V3_POSITION_MANAGER).positions(tokenId);

        console.log("position liquidity : %s", liquidity);
        console.log("buyerAssetsBound   : %s USDC (6dp)", bound);
    }

    /// STEP 4 — the taker fills it ///

    function take() external {
        address maker = vm.envAddress("DEMO_MAKER");
        uint256 units = vm.envOr("DEMO_FILL", uint256(10e6));

        // Enough cbBTC to be comfortably healthy at 77% LLTV, doubled so the health check is never
        // the thing that fails in front of an audience.
        uint256 collateral = ((units * 1e18 / LLTV) * 1e36 / 1e39) * 2;

        vm.startBroadcast();
        address taker = msg.sender;

        IERC20(CBBTC).approve(MIDNIGHT, collateral);
        IMidnight(MIDNIGHT).supplyCollateral(_market(), 0, collateral, taker);

        (uint256 buyerAssets,) =
            IMidnight(MIDNIGHT).take(_offer(maker, units), hex"", units, taker, taker, address(0), hex"");

        vm.stopBroadcast();

        console.log("filled: %s USDC (6dp)", buyerAssets);
        console.log("Maker's Midnight position: https://app.morpho.org/base/address/%s", maker);
    }

    /// SHARED ///

    /// @dev The offer. This struct *is* the publication — there is nothing else to post anywhere.
    function _offer(address maker, uint256 maxUnits) internal view returns (Offer memory offer) {
        offer.market = _market();
        offer.buy = true;
        offer.maker = maker;
        offer.expiry = vm.envOr("DEMO_EXPIRY", block.timestamp + 7 days);
        offer.tick = MAX_TICK;
        offer.callback = vm.envAddress("DEMO_CALLBACK");
        offer.callbackData = abi.encode(vm.envUint("DEMO_TOKEN_ID"));
        offer.ratifier = vm.envAddress("DEMO_RATIFIER");
        offer.maxUnits = uint128(maxUnits);
        offer.continuousFeeCap = type(uint256).max;
    }

    function _market() internal view returns (Market memory market) {
        market.chainId = block.chainid;
        market.midnight = MIDNIGHT;
        market.loanToken = USDC;
        market.maturity = vm.envUint("DEMO_MATURITY");
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] = CollateralParams({
            token: CBBTC, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: vm.envAddress("DEMO_ORACLE")
        });
    }
}
