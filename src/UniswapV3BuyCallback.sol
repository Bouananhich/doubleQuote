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
/// @dev **Knowingly incomplete in one way still.** The residual swap runs with **no price
/// protection at all** — no `minOut`, and a sqrt-price limit set to the extremes. `PRICE_REF` and
/// `MAX_SLIPPAGE_WAD` are held as immutables here and not yet read. That is scheduled, not
/// overlooked: D7's griefing test needs an unprotected version to attack so the loss can be
/// quantified, and D8 then wires the reference in and re-runs the same test.
///
/// @dev The burn sizing itself accounts for the swap fee but not for price impact, so it can come
/// up short on a thin venue; `_sourceLoanToken` falls back to unwinding the remainder rather than
/// failing a fill the position could have covered. Modelling the impact properly is D5/D6, and it
/// is what removes the fallback.
contract UniswapV3BuyCallback is UniswapBuyCallbackBase, IUniswapV3BuyCallback, IUniswapV3SwapCallback {
    using SafeCast for uint256;

    /// @dev How far past the sized burn `_sourceLoanToken` may escalate when the estimate came up
    /// short. See `_escalationCeiling`.
    uint256 internal constant ESCALATION_FACTOR = 2;

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

        uint128 burn = _liquidityForShortfall(position, loanToken == position.token0, shortfall);
        _unwind(tokenId, burn);
        _swapWholeResidual(residualToken, loanToken);

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
        uint256 ceiling = _escalationCeiling(burn, position.liquidity);
        if (sourced < shortfall && ceiling > burn) {
            _unwind(tokenId, uint128(ceiling - burn));
            _swapWholeResidual(residualToken, loanToken);
            sourced = IERC20Extended(loanToken).balanceOf(address(this)) - heldBefore;
        }

        // Midnight checks that the tokens arrived, so this is strictly a better error message than
        // a bare `transferFrom` failure — worth two warm balance reads in the contract whose whole
        // point is failing honestly rather than filling badly.
        require(sourced >= shortfall, InsufficientSourced());
    }

    /// @dev The most liquidity a fill may burn, given what the sizing said it needed. Twice the
    /// sized burn: ample for the impact the 25bp margin failed to cover — that would have to be
    /// eight times the margin before it bound — while keeping the burn proportional to the fill, so
    /// a fill that cannot justify its own sourcing reverts rather than taking the position with it.
    function _escalationCeiling(uint128 sized, uint128 available) internal pure returns (uint256) {
        uint256 ceiling = uint256(sized) * ESCALATION_FACTOR;
        return ceiling < available ? ceiling : available;
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
    function _swapWholeResidual(address residualToken, address loanToken) internal {
        uint256 residual = IERC20Extended(residualToken).balanceOf(address(this));
        if (residual > 0) _swapResidual(residualToken, loanToken, residual);
    }

    /// @dev Swaps the entire residual rather than only what the fill needs. Any excess becomes
    /// buffer, which is exactly where surplus loan token wants to be, and it means no residual dust
    /// ever accumulates on the callback.
    function _swapResidual(address residualToken, address loanToken, uint256 amountIn) internal {
        require(
            (residualToken == ROUTE_TOKEN0 && loanToken == ROUTE_TOKEN1)
                || (residualToken == ROUTE_TOKEN1 && loanToken == ROUTE_TOKEN0),
            RoutePairMismatch()
        );
        bool zeroForOne = residualToken == ROUTE_TOKEN0;

        IUniswapV3Pool(ROUTE_POOL)
            .swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                // No protection. D8 replaces this with a bound derived from `PRICE_REF` and
                // `MAX_SLIPPAGE_WAD`; D7 first measures what an attacker extracts through it.
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                ""
            );
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

    /// @dev **Naive.** Position amounts at spot, plus uncollected fees, plus the residual converted
    /// at spot — no price impact, no swap fee, no reference to `PRICE_REF`. It over-promises, and
    /// by how much is the interesting question: D5 replaces it with the single-step version (exact
    /// on the stable venue, where a small residual never leaves the active tick range), D6 with the
    /// multi-tick walk, and D8 makes it reference-relative.
    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        PositionState memory position = _position(abi.decode(data, (uint256)));
        bool loanIsToken0 = loanToken == position.token0;
        if (!loanIsToken0 && loanToken != position.token1) revert LoanTokenNotInPool();

        address pool = IUniswapV3Factory(FACTORY).getPool(position.token0, position.token1, position.fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        (uint256 amount0, uint256 amount1) = SourcingMathLib.amountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position.tickLower),
            TickMath.getSqrtPriceAtTick(position.tickUpper),
            position.liquidity
        );
        amount0 += position.owed0;
        amount1 += position.owed1;

        return loanIsToken0
            ? amount0 + SourcingMathLib.quote1For0(amount1, sqrtPriceX96)
            : amount1 + SourcingMathLib.quote0For1(amount0, sqrtPriceX96);
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

    function _residualToken(address loanToken, PositionState memory position) internal pure returns (address) {
        if (loanToken == position.token0) return position.token1;
        if (loanToken == position.token1) return position.token0;
        revert LoanTokenNotInPool();
    }
}
