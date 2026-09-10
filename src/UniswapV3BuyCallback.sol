// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IERC20Extended} from "midnight/src/periphery/blue-buy-callback/interfaces/IERC20Extended.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {UniswapBuyCallbackBase} from "./UniswapBuyCallbackBase.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3SwapCallback
} from "./interfaces/IUniswapV3.sol";
import {IUniswapV3BuyCallback} from "./interfaces/IUniswapV3BuyCallback.sol";
import {SourcingMathLib} from "./libraries/SourcingMathLib.sol";
import {TickBookLib} from "./libraries/TickBookLib.sol";

/// @title UniswapV3BuyCallback
/// @notice Parks a Midnight maker's capital in a Uniswap **v3** position and unwinds it to settle.
///
/// @dev **Non-custodial.** The maker keeps the position NFT and merely `approve`s this contract for
/// the `tokenId`. That works because `decreaseLiquidity` only requires
/// `_isApprovedOrOwner(msg.sender, tokenId)`, and `collect` takes an arbitrary recipient — so the
/// whole unwind runs without this contract ever holding the NFT. Custody would buy nothing and cost
/// an escape hatch, a rescue path and an ERC-721 receiver.
///
/// @dev It is also the strongest reading of the thesis. Parking is meant to be permissionless
/// because a maker forced to migrate liquidity into a blessed pool is no longer an existing LP;
/// non-custodial parking goes one better, in that the maker does not have to move the position at
/// all. The exposure — the maker can revoke approval or transfer the NFT out from under a live
/// offer — is self-harm of the same class as pointing an offer at a bad pool, and it fails closed:
/// the take reverts when the loan tokens do not arrive.
///
/// @dev `callbackData` is `abi.encode(uint256 tokenId)`. Everything else about the parked position
/// — both tokens, the fee tier, the tick range, the liquidity — is read from the position manager
/// at execution time rather than trusted from the maker's signature, per the rule that every
/// execution-time decision derives from on-chain state.
///
/// @dev **Sourcing is buffer first, then a sized partial burn.** Idle loan token serves the fill
/// outright; only the shortfall reaches the position, and only as much liquidity as that shortfall
/// needs. Both halves matter for the same reason: every unwind drags a residual swap behind it, and
/// every residual swap costs the maker fee plus impact at a price the taker chose the moment for.
/// Repeated dust takes are extractive precisely because they force that swap over and over, so the
/// defence is to not swap at all when the buffer covers it, and to swap as little as possible when
/// it does not.
///
/// @dev **The residual swap is guarded against the maker's own reference.** `PRICE_REF` prices the
/// residual, `MAX_SLIPPAGE_WAD` says how far below that the maker will accept, and the check is on
/// the amount actually received — not on the route pool's spot price, and not through a sqrt-price
/// limit. D7 established why: an attack that displaced route spot by only 7.70bp, inside a 10bp
/// budget, realised 61.34% below reference and took 61.86% of the fill out of the maker's position.
///
/// @dev **The two halves are modelled differently, on purpose.** `buyerAssetsBound` simulates the
/// whole unwind and bisects for the largest honest fill — it is a `view`, so it can. The burn
/// sizing inside `onBuy` runs on the taker's gas and settles for the fee plus a flat 25bp impact
/// margin, with a bounded escalation when that comes up short. Model in the view, execute in the
/// callback.
contract UniswapV3BuyCallback is UniswapBuyCallbackBase, IUniswapV3BuyCallback, IUniswapV3SwapCallback {
    using SafeCast for uint256;

    /// @dev Everything about the parked position that either half of the callback needs, read in
    /// one call. `positions` returns twelve values and only these seven are used.
    struct PositionState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    /// @dev Running totals for the residual sales one settlement makes: what they were worth at
    /// `PRICE_REF`, and what the route venue paid. Carried as a memory struct so the sized burn's
    /// swap and the escalation's both report into one place, and the budget is then checked over
    /// the settlement rather than over whichever swap happened last.
    struct Sale {
        uint256 referenceValue;
        uint256 proceeds;
    }

    /// @inheritdoc IUniswapV3BuyCallback
    address public immutable POSITION_MANAGER;
    /// @inheritdoc IUniswapV3BuyCallback
    address public immutable FACTORY;
    /// @inheritdoc IUniswapV3BuyCallback
    address public immutable ROUTE_POOL;

    /// @dev Cached at deployment so the swap path needs no `token0()`/`token1()` calls on the
    /// taker's gas.
    address internal immutable ROUTE_TOKEN0;
    address internal immutable ROUTE_TOKEN1;

    /// @dev The routing venue's fee, in hundredths of a bip. Feeds the burn sizing, which has to
    /// know what the residual swap will cost before deciding how much to burn.
    uint24 internal immutable ROUTE_FEE;

    constructor(
        address owner,
        address midnight,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address positionManager,
        address routePool
    ) UniswapBuyCallbackBase(owner, midnight, priceRef, maxSlippageWad) {
        require(positionManager != address(0), ZeroAddress());
        require(routePool != address(0), ZeroAddress());

        POSITION_MANAGER = positionManager;
        FACTORY = INonfungiblePositionManager(positionManager).factory();
        ROUTE_POOL = routePool;
        ROUTE_TOKEN0 = IUniswapV3Pool(routePool).token0();
        ROUTE_TOKEN1 = IUniswapV3Pool(routePool).token1();
        ROUTE_FEE = IUniswapV3Pool(routePool).fee();
    }

    /// SETTLEMENT ///

    /// @dev Burn, collect, swap the residual. Runs on the taker's gas.
    /// @dev `amount0Min`/`amount1Min` are zero on the burn, and that is not an oversight: removing
    /// liquidity leaves `sqrtP` unchanged, so a burn has no slippage to protect against. What it
    /// does is *thin the book the residual is about to be swapped into* — the self-impact is real
    /// but it lands on the swap, which is where the protection belongs (D8).
    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal override {
        uint256 tokenId = abi.decode(data, (uint256));
        PositionState memory position = _position(tokenId);
        address residualToken = _residualToken(loanToken, position);

        uint256 heldBefore = IERC20Extended(loanToken).balanceOf(address(this));

        // Accumulated across both swaps: what the residual was worth at `PRICE_REF`, and what the
        // route venue actually paid for it. Their difference is the cost the budget caps.
        Sale memory sale;

        uint128 burn = _liquidityForShortfall(position, loanToken == position.token0, shortfall);
        _unwind(tokenId, burn);
        _swapWholeResidual(residualToken, loanToken, sale);

        uint256 sourced = IERC20Extended(loanToken).balanceOf(address(this)) - heldBefore;

        // The sizing accounts for the swap fee but not yet for price impact, so it can come up
        // short on a thin venue. Escalate rather than fail a fill the position could have covered —
        // but only within a bounded multiple of what the fill itself justified.
        //
        // The bound is the whole point. Escalating straight to the remaining liquidity means any
        // fill too small to survive the rounding in `liquidityForTarget` unwinds the entire
        // position: a take of one wei sizes to a burn that yields zero tokens, comes up short, and
        // takes the maker's whole LP with it. Proportionality is the invariant — the liquidity
        // burnt must stay tied to the size of the fill, and a fill that cannot justify its own
        // sourcing has to fail closed instead.
        uint256 ceiling = SourcingMathLib.escalationCeiling(burn, position.liquidity);
        if (sourced < shortfall && ceiling > burn) {
            _unwind(tokenId, uint128(ceiling - burn));
            _swapWholeResidual(residualToken, loanToken, sale);
            sourced = IERC20Extended(loanToken).balanceOf(address(this)) - heldBefore;
        }

        // Midnight checks that the tokens arrived, so this is strictly a better error message than
        // a bare `transferFrom` failure — worth two warm balance reads in the contract whose whole
        // point is failing honestly rather than filling badly.
        require(sourced >= shortfall, InsufficientSourced());

        // **The D8 guard.** Checked once, over both swaps, against the same cost-over-sourced ratio
        // `buyerAssetsBound` bisects on. Checked *after* the escalation rather than between the two
        // swaps: the maker's budget is a statement about what the unwind cost in total, and a first
        // swap that came in expensive can still be settled honestly if the second is cheap. A
        // revert here rolls back both burns, so nothing is spent finding that out.
        uint256 cost = SourcingMathLib.costWad(sale.referenceValue, sale.proceeds, sourced);
        require(cost <= MAX_SLIPPAGE_WAD, SourcingCostAboveBudget(cost, MAX_SLIPPAGE_WAD));
    }

    /// @dev How much of the position this fill needs. See `SourcingMathLib.liquidityForTarget` for
    /// why the estimate leans towards burning too much rather than too little.
    function _liquidityForShortfall(PositionState memory position, bool loanIsToken0, uint256 shortfall)
        internal
        view
        returns (uint128)
    {
        if (position.liquidity == 0) return 0;

        address pool = IUniswapV3Factory(FACTORY).getPool(position.token0, position.token1, position.fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        return SourcingMathLib.liquidityForTarget(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position.tickLower),
            TickMath.getSqrtPriceAtTick(position.tickUpper),
            position.liquidity,
            loanIsToken0,
            shortfall,
            ROUTE_FEE
        );
    }

    /// @dev Burns `liquidity` and sweeps everything owed. `collect` takes the accrued fees along
    /// with the burnt amounts, which is the yield leg of the position finally being realised.
    function _unwind(uint256 tokenId, uint128 liquidity) internal {
        if (liquidity > 0) {
            INonfungiblePositionManager(POSITION_MANAGER)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                    })
                );
        }

        INonfungiblePositionManager(POSITION_MANAGER)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @dev Swaps the callback's whole residual balance, which also sweeps up anything an earlier
    /// fill left behind.
    function _swapWholeResidual(address residualToken, address loanToken, Sale memory sale) internal {
        uint256 residual = IERC20Extended(residualToken).balanceOf(address(this));
        if (residual > 0) _swapResidual(residualToken, loanToken, residual, sale);
    }

    /// @dev Swaps the entire residual rather than only what the fill needs. Any excess becomes
    /// buffer, which is exactly where surplus loan token wants to be, and it means no residual dust
    /// ever accumulates on the callback.
    ///
    /// @dev The sqrt-price limit stays at the extremes on purpose. A price limit makes v3
    /// *partially* fill and return quietly, which here surfaces as a shortfall, triggers the
    /// escalation path, and burns more of the maker's position — the attack paying for itself
    /// through a different door. The protection is the cost check in `_sourceLoanToken`, on the
    /// loan token that actually arrived.
    function _swapResidual(address residualToken, address loanToken, uint256 amountIn, Sale memory sale) internal {
        require(
            (residualToken == ROUTE_TOKEN0 && loanToken == ROUTE_TOKEN1)
                || (residualToken == ROUTE_TOKEN1 && loanToken == ROUTE_TOKEN0),
            RoutePairMismatch()
        );
        bool zeroForOne = residualToken == ROUTE_TOKEN0;

        // Read before the swap. `PRICE_REF` is an immutable pointing at a venue this contract is
        // not about to trade in, so nothing the swap does can move it — but reading it first also
        // means a reference that cannot price the pair reverts before any liquidity has moved.
        sale.referenceValue += SourcingMathLib.valueAtRef(
            amountIn, PRICE_REF.refSqrtPriceX96(ROUTE_TOKEN0, ROUTE_TOKEN1), zeroForOne
        );

        (int256 amount0, int256 amount1) = IUniswapV3Pool(ROUTE_POOL)
            .swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                ""
            );

        // The output side is negative — v3 signs deltas from the pool's perspective.
        sale.proceeds += uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @dev The pool pulls payment through here. Guarded on `ROUTE_POOL`, which is immutable — so
    /// there is no route through this function for an arbitrary contract to drain the callback.
    /// @dev Which token to pay is derived from the sign of the deltas rather than from `data`, so
    /// the function trusts nothing it is handed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == ROUTE_POOL, NotRoutePool());

        (address tokenIn, uint256 amountToPay) =
            amount0Delta > 0 ? (ROUTE_TOKEN0, uint256(amount0Delta)) : (ROUTE_TOKEN1, uint256(amount1Delta));

        SafeTransferLib.safeTransfer(tokenIn, ROUTE_POOL, amountToPay);
    }

    /// QUOTING ///

    /// @dev **The single-step bound, D5.** Simulates the actual unwind — burn `dL`, sell the
    /// residual on the route venue against a book that `dL` may itself have thinned — and bisects
    /// on `dL` for the largest fill whose cost stays inside `MAX_SLIPPAGE_WAD`. See
    /// `SourcingMathLib.boundBySlippage`; D6 replaces the single step with a tick walk and D8 makes
    /// the cost reference-relative rather than route-spot-relative.
    ///
    /// @dev This reads the *route* pool as well as the parked one, and that is the point: the
    /// residual is sold there, not where it came from. When the two are the same pool the burn also
    /// thins the book, which the model accounts for; when they are not, it does not.
    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        PositionState memory position = _position(abi.decode(data, (uint256)));
        bool loanIsToken0 = loanToken == position.token0;
        if (!loanIsToken0 && loanToken != position.token1) revert LoanTokenNotInPool();

        address residualToken = loanIsToken0 ? position.token1 : position.token0;

        // The residual has to be sellable on the immutable route venue or the unwind reverts, so
        // the honest bound in that case is zero, not the position's paper value.
        if (residualToken != ROUTE_TOKEN0 && residualToken != ROUTE_TOKEN1) return 0;
        if (loanToken != ROUTE_TOKEN0 && loanToken != ROUTE_TOKEN1) return 0;

        address pool = IUniswapV3Factory(FACTORY).getPool(position.token0, position.token1, position.fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        (uint160 routeSqrtPriceX96, int24 routeTick,,,,,) = IUniswapV3Pool(ROUTE_POOL).slot0();
        bool residualIsRouteToken0 = residualToken == ROUTE_TOKEN0;

        uint256 bound = SourcingMathLib.boundBySlippage(
            SourcingMathLib.BoundParams({
                sqrtPriceX96: sqrtPriceX96,
                sqrtLowerX96: TickMath.getSqrtPriceAtTick(position.tickLower),
                sqrtUpperX96: TickMath.getSqrtPriceAtTick(position.tickUpper),
                liquidity: position.liquidity,
                loanIsToken0: loanIsToken0,
                routeSqrtPriceX96: routeSqrtPriceX96,
                routeLiquidity: IUniswapV3Pool(ROUTE_POOL).liquidity(),
                routeFeePips: ROUTE_FEE,
                refSqrtPriceX96: PRICE_REF.refSqrtPriceX96(ROUTE_TOKEN0, ROUTE_TOKEN1),
                routeBook: TickBookLib.readBook(
                    routeTick,
                    IUniswapV3Pool(ROUTE_POOL).tickSpacing(),
                    residualIsRouteToken0,
                    _routeBitmapWord,
                    _routeLiquidityNet
                ),
                residualIsRouteToken0: residualIsRouteToken0,
                routeIsParkVenue: pool == ROUTE_POOL,
                maxSlippageWad: MAX_SLIPPAGE_WAD
            })
        );

        // Uncollected fees on the loan side come back with the `collect` every burn ends in, so
        // they are sourceable without a swap. The residual side is left out on purpose: selling it
        // is a swap the model has not sized, and a bound must never over-promise. It arrives as a
        // bonus in the buffer instead.
        return bound + (loanIsToken0 ? position.owed0 : position.owed1);
    }

    /// INTERNAL ///

    function _position(uint256 tokenId) internal view returns (PositionState memory position) {
        (
            ,,
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,,,
            position.owed0,
            position.owed1
        ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
    }

    /// @dev The two venue-specific reads `TickBookLib` walks the route venue with. Passed as
    /// function pointers so the walk itself is written once and shared with v4.
    function _routeBitmapWord(int16 wordPosition) private view returns (uint256) {
        return IUniswapV3Pool(ROUTE_POOL).tickBitmap(wordPosition);
    }

    function _routeLiquidityNet(int24 tick) private view returns (int128 liquidityNet) {
        (, liquidityNet,,,,,,) = IUniswapV3Pool(ROUTE_POOL).ticks(tick);
    }

    function _residualToken(address loanToken, PositionState memory position) internal pure returns (address) {
        if (loanToken == position.token0) return position.token1;
        if (loanToken == position.token1) return position.token0;
        revert LoanTokenNotInPool();
    }
}
