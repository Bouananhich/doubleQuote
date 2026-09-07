// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {UniswapBuyCallbackBase} from "./UniswapBuyCallbackBase.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {IUniswapV4BuyCallback} from "./interfaces/IUniswapV4BuyCallback.sol";
import {SourcingMathLib} from "./libraries/SourcingMathLib.sol";

/// @title UniswapV4BuyCallback
/// @notice Parks a Midnight maker's capital in a Uniswap **v4** position held directly on the
/// `PoolManager`, and unwinds it to settle — burn, residual swap and settlement inside a single
/// `unlock()`.
///
/// @dev **This is the custodial adapter, and that is the point.** `PoolManager.modifyLiquidity`
/// keys a position by `owner: msg.sender`, so the only position this contract can burn is one it
/// owns itself. The alternative — the maker holding a `PositionManager` NFT, as in v3 — cannot
/// share an unlock with the residual swap, because `unlock` reverts `AlreadyUnlocked` when nested.
/// That variant is worth having and is a separate adapter; this one exists because netting the
/// whole unwind into one settlement is the thing v4 does that v3 cannot, and it is only reachable
/// from here.
///
/// @dev **What netting buys.** v3 needs `decreaseLiquidity` → `collect` → `swap`, and the residual
/// token physically moves twice on the way to being sold. Here the burn credits a residual delta,
/// the swap consumes that same delta, and neither ever becomes a token transfer: the only
/// movement is one `take` of the loan token. The residual is sold without ever being held.
///
/// @dev **Custody is constrained, not open.** `unpark` is owner-only and always pays `OWNER` — the
/// maker's capital has exactly two destinations, back to the maker or into settling the maker's
/// own offers. There is no path that sends it anywhere else, which is the most this design can
/// offer in place of v3's "the maker never gives up the NFT".
///
/// @dev **Native currency is not supported.** Settling ETH needs a payable path and a `receive`
/// hook, and every additional way for value to enter this contract is another thing the safety
/// envelope has to cover. Pools with a zero-address currency revert at deployment and at parking.
///
/// @dev **Knowingly incomplete in the same way as v3.** The residual swap runs with no price
/// protection — `PRICE_REF` and `MAX_SLIPPAGE_WAD` are held and not yet read. D7 attacks it, D8
/// wires the reference in.
contract UniswapV4BuyCallback is UniswapBuyCallbackBase, IUniswapV4BuyCallback, IUnlockCallback {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Matches the v3 adapter. See `_escalationCeiling` there for why it is bounded.
    uint256 internal constant ESCALATION_FACTOR = 2;

    /// @dev What `unlockCallback` is being asked to do. Every path through this contract that
    /// touches the pool manager goes through one `unlock`, so the action has to be explicit.
    enum Action {
        SettleFill,
        Park,
        Unpark
    }

    /// @dev The parked position, as named by the maker's signed `callbackData`. Which pool, which
    /// range, which salt — nothing about the *envelope*, which is immutable.
    struct Parked {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    /// @inheritdoc IUniswapV4BuyCallback
    address public immutable POOL_MANAGER;

    /// @dev The route venue's `PoolKey`, held field by field because a struct cannot be immutable.
    /// Rebuilt by `routeKey()`. This is safety envelope: the maker cannot supply a route.
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

    /// PARKING ///

    /// @notice Moves `amount0`/`amount1` of the maker's tokens into a v4 position owned by this
    /// contract.
    /// @dev Owner-only, and the tokens come from `OWNER` — this is the maker funding their own
    /// parking, not a deposit anyone can make on their behalf.
    /// @dev Permissionless in the sense that matters: no whitelist of pools. A maker who parks in a
    /// bad pool harms only themselves, exactly as in v3.
    function park(Parked memory parked, uint128 liquidity) external {
        require(msg.sender == OWNER, NotOwner());
        require(
            !parked.key.currency0.isAddressZero() && !parked.key.currency1.isAddressZero(), NativeCurrencyUnsupported()
        );

        IPoolManager(POOL_MANAGER).unlock(abi.encode(Action.Park, parked, uint256(liquidity), address(0), uint256(0)));
    }

    /// @notice Burns `liquidity` from the parked position and sends both sides to `OWNER`.
    /// @dev The maker's escape hatch, and the reason the custody here is bounded: the recipient is
    /// not a parameter.
    function unpark(Parked memory parked, uint128 liquidity) external {
        require(msg.sender == OWNER, NotOwner());
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Action.Unpark, parked, uint256(liquidity), address(0), uint256(0)));
    }

    /// SETTLEMENT ///

    /// @dev One unlock does everything: size the burn, burn it, sell the residual against the
    /// delta it created, and take the loan token out net.
    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal override {
        Parked memory parked = abi.decode(data, (Parked));
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Action.SettleFill, parked, uint256(0), loanToken, shortfall));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev The pool manager is the only caller, and the action is decided here rather than trusted
    /// from anywhere a taker could reach.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, NotPoolManager());

        (Action action, Parked memory parked, uint256 liquidity, address loanToken, uint256 shortfall) =
            abi.decode(data, (Action, Parked, uint256, address, uint256));

        if (action == Action.SettleFill) {
            _settleFill(parked, loanToken, shortfall);
        } else if (action == Action.Park) {
            _park(parked, liquidity);
        } else {
            _unpark(parked, liquidity);
        }

        return "";
    }

    /// @dev The whole unwind, inside the unlock. Nothing here transfers the residual: it is created
    /// as a delta by the burn and consumed as a delta by the swap.
    function _settleFill(Parked memory parked, address loanToken, uint256 shortfall) internal {
        (Currency loanCurrency, Currency residualCurrency, bool loanIsCurrency0) = _currencies(loanToken, parked.key);

        uint128 available = _positionLiquidity(parked);
        uint128 burn = _liquidityForShortfall(parked, loanIsCurrency0, shortfall, available);

        _burnAndSell(parked, residualCurrency, burn);

        uint256 sourced = _positiveDelta(loanCurrency);

        // Same escalation as v3, and bounded the same way: the sizing models the swap fee but not
        // price impact, so it can fall short on a thin venue — and a fill too small to cover its
        // own rounding must revert rather than take the position with it.
        uint256 ceiling = _escalationCeiling(burn, available);
        if (sourced < shortfall && ceiling > burn) {
            _burnAndSell(parked, residualCurrency, uint128(ceiling - burn));
            sourced = _positiveDelta(loanCurrency);
        }

        require(sourced >= shortfall, InsufficientSourced());

        // The one token movement in the whole settlement.
        IPoolManager(POOL_MANAGER).take(loanCurrency, address(this), sourced);
    }

    /// @dev Burns `liquidity` and immediately sells whatever residual that credited. Split out
    /// because the escalation path runs it a second time.
    function _burnAndSell(Parked memory parked, Currency residualCurrency, uint128 liquidity) internal {
        if (liquidity == 0) return;

        IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                parked.key,
                ModifyLiquidityParams({
                    tickLower: parked.tickLower,
                    tickUpper: parked.tickUpper,
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: parked.salt
                }),
                ""
            );

        uint256 residual = _positiveDelta(residualCurrency);
        if (residual > 0) _swapResidual(residualCurrency, residual);
    }

    /// @dev Sells the residual on the route venue as an exact-input swap. The input is paid out of
    /// the delta the burn just created, so the tokens never leave the pool manager.
    function _swapResidual(Currency residualCurrency, uint256 amountIn) internal {
        bool zeroForOne = residualCurrency == ROUTE_CURRENCY0;
        require(zeroForOne || residualCurrency == ROUTE_CURRENCY1, RoutePairMismatch());

        IPoolManager(POOL_MANAGER)
            .swap(
                routeKey(),
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -amountIn.toInt256(),
                    // No protection, deliberately, until D8 — see the note on this contract.
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
    }

    /// @dev Adds liquidity and pays for it out of the maker's wallet.
    function _park(Parked memory parked, uint256 liquidity) internal {
        IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                parked.key,
                ModifyLiquidityParams({
                    tickLower: parked.tickLower,
                    tickUpper: parked.tickUpper,
                    liquidityDelta: int256(liquidity),
                    salt: parked.salt
                }),
                ""
            );

        _settleOwed(parked.key.currency0);
        _settleOwed(parked.key.currency1);
    }

    /// @dev Removes liquidity and pays it straight to the maker.
    function _unpark(Parked memory parked, uint256 liquidity) internal {
        IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                parked.key,
                ModifyLiquidityParams({
                    tickLower: parked.tickLower,
                    tickUpper: parked.tickUpper,
                    liquidityDelta: -int256(liquidity),
                    salt: parked.salt
                }),
                ""
            );

        _takeAllTo(parked.key.currency0, OWNER);
        _takeAllTo(parked.key.currency1, OWNER);
    }

    /// INTERNAL ///

    /// @dev Pays a negative delta by pulling from the maker. `sync` then transfer then `settle` is
    /// v4's payment pattern: the manager measures its own balance change rather than trusting a
    /// reported amount.
    function _settleOwed(Currency currency) internal {
        int256 delta = IPoolManager(POOL_MANAGER).currencyDelta(address(this), currency);
        if (delta >= 0) return;

        uint256 owed = uint256(-delta);
        IPoolManager(POOL_MANAGER).sync(currency);
        SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), OWNER, POOL_MANAGER, owed);
        IPoolManager(POOL_MANAGER).settle();
    }

    function _takeAllTo(Currency currency, address recipient) internal {
        uint256 owed = _positiveDelta(currency);
        if (owed > 0) IPoolManager(POOL_MANAGER).take(currency, recipient, owed);
    }

    /// @dev This contract's outstanding credit in `currency`, zero if it owes rather than is owed.
    function _positiveDelta(Currency currency) internal view returns (uint256) {
        int256 delta = IPoolManager(POOL_MANAGER).currencyDelta(address(this), currency);
        return delta > 0 ? uint256(delta) : 0;
    }

    /// @dev Sorts the loan token and the residual out of the parked pool's two currencies.
    function _currencies(address loanToken, PoolKey memory key)
        internal
        pure
        returns (Currency loanCurrency, Currency residualCurrency, bool loanIsCurrency0)
    {
        if (Currency.unwrap(key.currency0) == loanToken) return (key.currency0, key.currency1, true);
        if (Currency.unwrap(key.currency1) == loanToken) return (key.currency1, key.currency0, false);
        revert LoanCurrencyNotInPool();
    }

    /// @dev Position ids on the pool manager are keyed by owner, so this only ever finds positions
    /// this contract owns — which is the custody model stated on the contract.
    function _positionLiquidity(Parked memory parked) internal view returns (uint128) {
        return IPoolManager(POOL_MANAGER)
            .getPositionLiquidity(
                parked.key.toId(),
                keccak256(abi.encodePacked(address(this), parked.tickLower, parked.tickUpper, parked.salt))
            );
    }

    /// @dev See `SourcingMathLib.liquidityForTarget`; the math is venue-agnostic and shared with v3.
    function _liquidityForShortfall(Parked memory parked, bool loanIsCurrency0, uint256 shortfall, uint128 available)
        internal
        view
        returns (uint128)
    {
        if (available == 0) return 0;

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(parked.key.toId());

        return SourcingMathLib.liquidityForTarget(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(parked.tickLower),
            TickMath.getSqrtPriceAtTick(parked.tickUpper),
            available,
            loanIsCurrency0,
            shortfall,
            ROUTE_FEE
        );
    }

    function _escalationCeiling(uint128 sized, uint128 available) internal pure returns (uint256) {
        uint256 ceiling = uint256(sized) * ESCALATION_FACTOR;
        return ceiling < available ? ceiling : available;
    }

    /// QUOTING ///

    /// @dev Naive, exactly as in v3: position amounts at spot plus the residual converted at spot.
    /// The math library is shared, so the two adapters over-promise identically and the D5/D6 work
    /// lands on both at once.
    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        Parked memory parked = abi.decode(data, (Parked));
        (,, bool loanIsCurrency0) = _currencies(loanToken, parked.key);

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(parked.key.toId());

        (uint256 amount0, uint256 amount1) = SourcingMathLib.amountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(parked.tickLower),
            TickMath.getSqrtPriceAtTick(parked.tickUpper),
            _positionLiquidity(parked)
        );

        return loanIsCurrency0
            ? amount0 + SourcingMathLib.quote1For0(amount1, sqrtPriceX96)
            : amount1 + SourcingMathLib.quote0For1(amount0, sqrtPriceX96);
    }
}
