// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {UniswapBuyCallbackBase} from "./UniswapBuyCallbackBase.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {IUniswapV4BuyCallback} from "./interfaces/IUniswapV4BuyCallback.sol";
import {SourcingMathLib} from "./libraries/SourcingMathLib.sol";

/// @title UniswapV4BuyCallbackBase
/// @notice Everything the two v4 adapters share: the route venue, the residual swap, delta
/// accounting, and the bound math.
///
/// @dev There are two v4 adapters because v4 forces a choice v3 did not.
/// `PoolManager.modifyLiquidity` keys a position by `owner: msg.sender`, and `unlock` reverts
/// `AlreadyUnlocked` when nested. So a callback can own its liquidity and net the whole unwind
/// into one unlock, or the maker can keep a `PositionManager` NFT and the settlement takes two —
/// not both. `UniswapV4BuyCallback` is the first, `UniswapV4NftBuyCallback` the second, and this
/// holds the two-thirds of the logic that does not depend on which.
///
/// @dev What differs is only *where the liquidity lives and how it is burnt*. The residual swap is
/// identical, the sizing is identical, and the bound is identical — the last of these because
/// `SourcingMathLib` is venue-agnostic, so the D5/D6 work lands on both adapters and on v3 at once.
abstract contract UniswapV4BuyCallbackBase is UniswapBuyCallbackBase, IUniswapV4BuyCallback, IUnlockCallback {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Matches the v3 adapter. The burn a fill may escalate to is capped at this multiple of
    /// what the sizing asked for, so a fill too small to cover its own rounding reverts rather than
    /// unwinding the whole position. See `UniswapV3BuyCallback._escalationCeiling`.
    uint256 internal constant ESCALATION_FACTOR = 2;

    /// @inheritdoc IUniswapV4BuyCallback
    address public immutable POOL_MANAGER;

    /// @dev The route venue's `PoolKey`, field by field because a struct cannot be immutable.
    /// Safety envelope: a maker cannot supply a route through `callbackData`.
    Currency internal immutable ROUTE_CURRENCY0;
    Currency internal immutable ROUTE_CURRENCY1;
    uint24 internal immutable ROUTE_FEE;
    int24 internal immutable ROUTE_TICK_SPACING;
    IHooks internal immutable ROUTE_HOOKS;

    constructor(
        address owner,
        address midnight,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address poolManager,
        PoolKey memory route
    ) UniswapBuyCallbackBase(owner, midnight, priceRef, maxSlippageWad) {
        require(poolManager != address(0), ZeroAddress());
        require(!route.currency0.isAddressZero() && !route.currency1.isAddressZero(), NativeCurrencyUnsupported());

        POOL_MANAGER = poolManager;
        ROUTE_CURRENCY0 = route.currency0;
        ROUTE_CURRENCY1 = route.currency1;
        ROUTE_FEE = route.fee;
        ROUTE_TICK_SPACING = route.tickSpacing;
        ROUTE_HOOKS = route.hooks;
    }

    /// @inheritdoc IUniswapV4BuyCallback
    function routeKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: ROUTE_CURRENCY0,
            currency1: ROUTE_CURRENCY1,
            fee: ROUTE_FEE,
            tickSpacing: ROUTE_TICK_SPACING,
            hooks: ROUTE_HOOKS
        });
    }

    /// @inheritdoc IUnlockCallback
    /// @dev The guard is the whole point of keeping this here: the pool manager is the only caller,
    /// on both adapters, and neither gets to decide that for itself.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, NotPoolManager());
        return _onUnlock(data);
    }

    /// @dev What this adapter does once the manager is unlocked.
    function _onUnlock(bytes calldata data) internal virtual returns (bytes memory);

    /// SHARED SETTLEMENT PIECES ///

    /// @dev Sells the residual on the route venue as an exact-input swap.
    /// @dev No price protection, deliberately: D7's griefing test needs an unprotected version to
    /// attack so the loss can be quantified, and D8 replaces this with a bound derived from
    /// `PRICE_REF` and `MAX_SLIPPAGE_WAD`.
    function _swapResidual(Currency residualCurrency, uint256 amountIn) internal {
        bool zeroForOne = residualCurrency == ROUTE_CURRENCY0;
        require(zeroForOne || residualCurrency == ROUTE_CURRENCY1, RoutePairMismatch());

        IPoolManager(POOL_MANAGER)
            .swap(
                routeKey(),
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -amountIn.toInt256(),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
    }

    /// @dev This contract's outstanding credit in `currency`, zero if it owes rather than is owed.
    function _positiveDelta(Currency currency) internal view returns (uint256) {
        int256 delta = IPoolManager(POOL_MANAGER).currencyDelta(address(this), currency);
        return delta > 0 ? uint256(delta) : 0;
    }

    function _takeAllTo(Currency currency, address recipient) internal {
        uint256 owed = _positiveDelta(currency);
        if (owed > 0) IPoolManager(POOL_MANAGER).take(currency, recipient, owed);
    }

    /// @dev Sorts the loan token and the residual out of a pool's two currencies.
    function _currencies(address loanToken, PoolKey memory key)
        internal
        pure
        returns (Currency loanCurrency, Currency residualCurrency, bool loanIsCurrency0)
    {
        if (Currency.unwrap(key.currency0) == loanToken) return (key.currency0, key.currency1, true);
        if (Currency.unwrap(key.currency1) == loanToken) return (key.currency1, key.currency0, false);
        revert LoanCurrencyNotInPool();
    }

    function _escalationCeiling(uint128 sized, uint128 available) internal pure returns (uint256) {
        uint256 ceiling = uint256(sized) * ESCALATION_FACTOR;
        return ceiling < available ? ceiling : available;
    }

    /// @dev See `SourcingMathLib.liquidityForTarget`. Venue-agnostic, and shared with v3.
    function _liquidityForShortfall(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 available,
        bool loanIsCurrency0,
        uint256 shortfall
    ) internal view returns (uint128) {
        if (available == 0) return 0;

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());

        return SourcingMathLib.liquidityForTarget(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available,
            loanIsCurrency0,
            shortfall,
            ROUTE_FEE
        );
    }

    /// @dev The naive bound: position amounts at spot plus the residual converted at spot. Both
    /// adapters over-promise identically, which is the point of sharing it.
    function _boundFor(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity, bool loanIsCurrency0)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());

        (uint256 amount0, uint256 amount1) = SourcingMathLib.amountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );

        return loanIsCurrency0
            ? amount0 + SourcingMathLib.quote1For0(amount1, sqrtPriceX96)
            : amount1 + SourcingMathLib.quote0For1(amount0, sqrtPriceX96);
    }
}
