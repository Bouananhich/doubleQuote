// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {UniswapV4BuyCallbackBase} from "./UniswapV4BuyCallbackBase.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {SourcingMathLib} from "./libraries/SourcingMathLib.sol";

/// @title UniswapV4BuyCallback
/// @notice Parks a Midnight maker's capital in a Uniswap **v4** position held directly on the
/// `PoolManager`, and unwinds it to settle — burn, residual swap and settlement inside a single
/// `unlock()`.
///
/// @dev **This is the custodial adapter, and that is the point.** `PoolManager.modifyLiquidity`
/// keys a position by `owner: msg.sender`, so the only position this contract can burn is one it
/// owns. The alternative — the maker holding a `PositionManager` NFT, as in v3 — cannot share an
/// unlock with the residual swap, because `unlock` reverts `AlreadyUnlocked` when nested. That
/// variant is `UniswapV4NftBuyCallback`. This one exists because netting the whole unwind into one
/// settlement is the thing v4 does that v3 cannot, and it is only reachable from here.
///
/// @dev **What netting buys.** v3 needs `decreaseLiquidity` → `collect` → `swap`, and the residual
/// token physically moves twice on the way to being sold. Here the burn credits a residual delta,
/// the swap consumes that same delta, and neither ever becomes a token transfer: the only movement
/// is one `take` of the loan token. The residual is sold without ever being held.
///
/// @dev **Custody is constrained, not open.** `park` pulls only from `OWNER`; `unpark` is
/// owner-only and takes **no recipient**, so the maker's capital has exactly two destinations —
/// back to the maker, or into settling the maker's own offers. That is weaker than v3's "the maker
/// never gives up the NFT" and it is the most this design can offer, so it is tested rather than
/// asserted in a comment.
///
/// @dev **Native currency is not supported.** Settling ETH needs a payable path and a `receive`
/// hook, and every additional way for value to enter this contract is more surface for the safety
/// envelope to cover. Pools with a zero-address currency revert at deployment and at parking. It
/// costs the ETH pools, which are the deepest on v4, and that is a real limitation.
contract UniswapV4BuyCallback is UniswapV4BuyCallbackBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev What `unlockCallback` is being asked to do. Every path here that touches the pool
    /// manager goes through one `unlock`, so the action has to be explicit.
    enum Action {
        SettleFill,
        Park,
        Unpark
    }

    /// @dev The parked position, as named by the maker's signed `callbackData`: which pool, which
    /// range, which salt. Nothing about the safety envelope, which is immutable.
    struct Parked {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    constructor(
        address owner,
        address midnight,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address poolManager,
        PoolKey memory route
    ) UniswapV4BuyCallbackBase(owner, midnight, priceRef, maxSlippageWad, poolManager, route) {}

    /// PARKING ///

    /// @notice Moves the maker's tokens into a v4 position owned by this contract.
    /// @dev Owner-only, and the tokens come from `OWNER` — the maker funding their own parking, not
    /// a deposit anyone can make on their behalf.
    /// @dev No whitelist of pools: parking stays permissionless in the sense that matters. A maker
    /// who parks in a bad pool harms only themselves, exactly as in v3.
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

    /// @dev One unlock does everything: size the burn, burn it, sell the residual against the delta
    /// it created, and take the loan token out net.
    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal override {
        Parked memory parked = abi.decode(data, (Parked));
        IPoolManager(POOL_MANAGER).unlock(abi.encode(Action.SettleFill, parked, uint256(0), loanToken, shortfall));
    }

    /// @inheritdoc UniswapV4BuyCallbackBase
    function _onUnlock(bytes calldata data) internal override returns (bytes memory) {
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
        uint128 burn = _liquidityForShortfall(
            parked.key, parked.tickLower, parked.tickUpper, available, loanIsCurrency0, shortfall
        );

        SourcingMathLib.Sale memory sale;
        _burnAndSell(parked, residualCurrency, burn, sale);
        uint256 sourced = _positiveDelta(loanCurrency);

        // The sizing models the route fee but not price impact, so it can fall short on a thin
        // venue. Escalate, but only within a bounded multiple of what the fill itself justified.
        uint256 ceiling = SourcingMathLib.escalationCeiling(burn, available);
        if (sourced < shortfall && ceiling > burn) {
            _burnAndSell(parked, residualCurrency, uint128(ceiling - burn), sale);
            sourced = _positiveDelta(loanCurrency);
        }

        require(sourced >= shortfall, InsufficientSourced());

        // **The D8 guard, ported D10.** Checked once over both swaps, against the same
        // cost-over-sourced ratio `buyerAssetsBound` bisects on, and after the escalation rather
        // than between the two: the budget is a statement about what the unwind cost in total, so a
        // first swap that came in expensive can still settle honestly if the second is cheap.
        // Reverting here rolls the whole unlock back, so nothing is spent finding that out.
        uint256 cost = SourcingMathLib.costWad(sale.referenceValue, sale.proceeds, sourced);
        require(cost <= MAX_SLIPPAGE_WAD, SourcingCostAboveBudget(cost, MAX_SLIPPAGE_WAD));

        // The one token movement in the whole settlement.
        IPoolManager(POOL_MANAGER).take(loanCurrency, address(this), sourced);
    }

    /// @dev Burns `liquidity` and immediately sells whatever residual that credited. Split out
    /// because the escalation path runs it a second time.
    function _burnAndSell(
        Parked memory parked,
        Currency residualCurrency,
        uint128 liquidity,
        SourcingMathLib.Sale memory sale
    ) internal {
        if (liquidity == 0) return;

        _modify(parked, -int256(uint256(liquidity)));

        uint256 residual = _positiveDelta(residualCurrency);
        if (residual > 0) _swapResidual(residualCurrency, residual, sale);
    }

    /// @dev Adds liquidity and pays for it out of the maker's wallet.
    function _park(Parked memory parked, uint256 liquidity) internal {
        _modify(parked, int256(liquidity));

        _settleOwed(parked.key.currency0);
        _settleOwed(parked.key.currency1);
    }

    /// @dev Removes liquidity and pays it straight to the maker.
    function _unpark(Parked memory parked, uint256 liquidity) internal {
        _modify(parked, -int256(liquidity));

        _takeAllTo(parked.key.currency0, OWNER);
        _takeAllTo(parked.key.currency1, OWNER);
    }

    /// INTERNAL ///

    function _modify(Parked memory parked, int256 liquidityDelta) internal {
        IPoolManager(POOL_MANAGER)
            .modifyLiquidity(
                parked.key,
                ModifyLiquidityParams({
                    tickLower: parked.tickLower,
                    tickUpper: parked.tickUpper,
                    liquidityDelta: liquidityDelta,
                    salt: parked.salt
                }),
                ""
            );
    }

    /// @dev Pays a negative delta by pulling from the maker. `sync` then transfer then `settle` is
    /// v4's payment pattern: the manager measures its own balance change rather than trusting a
    /// reported amount.
    function _settleOwed(Currency currency) internal {
        int256 delta = IPoolManager(POOL_MANAGER).currencyDelta(address(this), currency);
        if (delta >= 0) return;

        IPoolManager(POOL_MANAGER).sync(currency);
        SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), OWNER, POOL_MANAGER, uint256(-delta));
        IPoolManager(POOL_MANAGER).settle();
    }

    /// @dev Position ids on the pool manager are keyed by owner, so this only ever finds positions
    /// this contract owns — which is the custody model stated above.
    function _positionLiquidity(Parked memory parked) internal view returns (uint128) {
        return IPoolManager(POOL_MANAGER)
            .getPositionLiquidity(
                parked.key.toId(),
                keccak256(abi.encodePacked(address(this), parked.tickLower, parked.tickUpper, parked.salt))
            );
    }

    /// QUOTING ///

    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        Parked memory parked = abi.decode(data, (Parked));
        (,, bool loanIsCurrency0) = _currencies(loanToken, parked.key);

        return _boundFor(parked.key, parked.tickLower, parked.tickUpper, _positionLiquidity(parked), loanIsCurrency0);
    }
}
