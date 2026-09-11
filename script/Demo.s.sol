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

import {OfferDigest} from "./OfferDigest.sol";

import {Signature} from "midnight/src/ratifiers/interfaces/IEcrecoverRatifier.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IOraclePrice {
    function price() external view returns (uint256);
}

/// @dev `script/OfferDigest.sol`, reached through an interface on purpose: importing `HashLib` here
/// would put it in the same compilation unit as `forge-std`, which does not compile. See its natspec.
interface IOfferDigest {
    function rootAndDigest(Offer memory offer) external view returns (bytes32 root, bytes32 digest);
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
/// @dev **What each step costs.** Deployment measured $0.217 on Base — 7,728,429 gas at 0.0111
/// gwei, against a padded `forge` estimate of 10,295,824. The capital is ~$20
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

    /// @dev Morpho's canonical signature ratifier, live on Base. The maker signs offers for it;
    /// nothing bespoke is deployed for authorisation.
    address internal constant ECRECOVER_RATIFIER = 0xd6e70365C8E8DDa9a4ca662C07bbE663b017755E;

    /// @dev **The real market**: USDC against cbBTC at 86% LLTV, the deployed oracle, maturing
    /// 25 December 2026. Its id is asserted at every step rather than trusted.
    address internal constant REAL_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant MATURITY = 1798210800;
    uint256 internal constant RCF_THRESHOLD = 3_000_000_000;
    bytes32 internal constant MARKET_ID = 0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da;

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

        OfferDigest offerDigest = new OfferDigest(ECRECOVER_RATIFIER);
        V3TwapRef priceRef = new V3TwapRef(POOL_USDC_USDT_100, REF_WINDOW);
        UniswapV3BuyCallbackFactory factory = new UniswapV3BuyCallbackFactory(MIDNIGHT, V3_POSITION_MANAGER);
        address callback = factory.createCallback(
            maker, IPriceRef(address(priceRef)), MAX_SLIPPAGE_WAD, POOL_USDC_USDT_100, bytes32(0)
        );

        // Lets Morpho's ratifier speak for this maker. The offer itself is authorised by a
        // signature, checked inside `EcrecoverRatifier`.
        IMidnight(MIDNIGHT).setIsAuthorized(ECRECOVER_RATIFIER, true, maker);

        vm.stopBroadcast();

        console.log("DEMO_OFFER_DIGEST=%s", address(offerDigest));
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

        _touchAndAssertMarket();

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

    /// STEP 4 — the maker signs the offer ///

    /// @dev Prints the EIP-712 digest and nothing else, so the key never reaches this process:
    /// sign it with `cast wallet sign --account maker --no-hash <digest>`.
    /// @dev The scheme signs a Merkle root of offers; a single offer is the degenerate tree, so the
    /// root is the offer hash and the proof is empty.
    function digest() external view {
        Offer memory offer = _offer(vm.envAddress("DEMO_MAKER"), vm.envOr("DEMO_FILL", uint256(10e6)));
        (bytes32 root, bytes32 toSign) = IOfferDigest(vm.envAddress("DEMO_OFFER_DIGEST")).rootAndDigest(offer);

        console.log("offer root : %s", vm.toString(root));
        console.log("sign this  : %s", vm.toString(toSign));
    }

    /// STEP 5 — the taker fills it ///

    function take() external {
        address maker = vm.envAddress("DEMO_MAKER");
        uint256 units = vm.envOr("DEMO_FILL", uint256(10e6));

        Offer memory offer = _offer(maker, units);
        bytes memory ratifierData = _ratifierData(offer);

        // Sized off the live cbBTC oracle, doubled so the health check is never what fails in front
        // of an audience.
        uint256 collateral = ((units * 1e18 / LLTV) * 1e36 / IOraclePrice(REAL_ORACLE).price()) * 2;

        vm.startBroadcast();
        address taker = msg.sender;

        _touchAndAssertMarket();

        IERC20(CBBTC).approve(MIDNIGHT, collateral);
        IMidnight(MIDNIGHT).supplyCollateral(_market(), 0, collateral, taker);

        (uint256 buyerAssets,) = IMidnight(MIDNIGHT).take(offer, ratifierData, units, taker, taker, address(0), hex"");

        vm.stopBroadcast();

        console.log("filled: %s USDC (6dp)", buyerAssets);
        console.log("Maker's Midnight position: https://app.morpho.org/base/address/%s", maker);
    }

    /// SHARED ///

    /// @dev `touchMarket` is idempotent and costs ~12.8k gas against a market that already exists,
    /// which is what makes it a cheap assertion rather than a creation. If this ever reverts the
    /// script is pointed at a market that is not the one pinned above, and nothing else it prints
    /// can be trusted.
    function _touchAndAssertMarket() internal {
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(_market());
        require(id == MARKET_ID, "market id is not the pinned live market");
    }

    /// @dev The offer. This struct *is* the publication — there is nothing else to post anywhere.
    function _offer(address maker, uint256 maxUnits) internal view returns (Offer memory offer) {
        offer.market = _market();
        offer.buy = true;
        offer.maker = maker;
        // **Required, never defaulted.** A `block.timestamp`-derived expiry differs between the
        // `digest()` call and the `take()` that follows it, which changes the offer hash and
        // invalidates the signature — the demo would fail at the last step, live. Set it once and
        // keep it for every step, exactly as with the market.
        offer.expiry = vm.envUint("DEMO_EXPIRY");
        offer.tick = MAX_TICK;
        offer.callback = vm.envAddress("DEMO_CALLBACK");
        offer.callbackData = abi.encode(vm.envUint("DEMO_TOKEN_ID"));
        offer.ratifier = ECRECOVER_RATIFIER;
        offer.maxUnits = uint128(maxUnits);
        offer.continuousFeeCap = type(uint256).max;
    }

    /// @dev `DEMO_SIGNATURE` is the 65-byte output of `cast wallet sign`.
    function _ratifierData(Offer memory offer) internal view returns (bytes memory) {
        bytes memory sig = vm.envBytes("DEMO_SIGNATURE");
        require(sig.length == 65, "DEMO_SIGNATURE must be 65 bytes");

        bytes32 r;
        bytes32 vs;
        assembly {
            r := mload(add(sig, 32))
            vs := mload(add(sig, 64))
        }
        uint8 v = uint8(sig[64]);

        (bytes32 root,) = IOfferDigest(vm.envAddress("DEMO_OFFER_DIGEST")).rootAndDigest(offer);
        return abi.encode(Signature({v: v, r: r, s: vs}), root, uint256(0), new bytes32[](0));
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
