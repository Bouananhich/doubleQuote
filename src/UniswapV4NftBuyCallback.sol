// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IERC20Extended} from "midnight/src/periphery/blue-buy-callback/interfaces/IERC20Extended.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UniswapV4BuyCallbackBase} from "./UniswapV4BuyCallbackBase.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";
import {SourcingMathLib} from "./libraries/SourcingMathLib.sol";
import {IV4PositionManager, V4Actions, V4PositionInfo} from "./interfaces/IV4PositionManager.sol";

/// @title UniswapV4NftBuyCallback
/// @notice Parks a Midnight maker's capital in a Uniswap **v4** `PositionManager` NFT the maker
/// keeps, and unwinds it to settle.
///
/// @dev **The non-custodial v4 adapter.** Custody works exactly as in v3: the maker keeps the NFT
/// and `approve`s this contract for the `tokenId`, so the whole unwind runs without the position
/// ever leaving their wallet. Revoking approval breaks the maker's own offer and nobody else's,
/// and it fails closed.
///
/// @dev **The cost is the netting, and it is not recoverable.** `PositionManager.modifyLiquidities`
/// opens its own `unlock`, and `PoolManager.unlock` reverts `AlreadyUnlocked` when nested, so the
/// decrease and the residual swap cannot share one. The residual is therefore *taken* as real
/// tokens by the first unlock and *paid back in* by the second — two unlocks and four token
/// movements, against `UniswapV4BuyCallback`'s one unlock and one. This adapter exists to make that
/// difference measurable rather than asserted: it is the like-for-like comparison against v3, and
/// the custodial adapter is the comparison against it.
///
/// @dev **Everything about the position is read on-chain.** `callbackData` carries only the
/// `tokenId`; the pool, the range and the liquidity come from the position manager at execution
/// time. The maker cannot sign a `callbackData` that lies about the range it is burning from.
///
/// @dev **Native currency is not supported**, for the same reason as the custodial adapter.
contract UniswapV4NftBuyCallback is UniswapV4BuyCallbackBase {
    /// @dev Everything either half of the callback needs about the parked position, gathered in one
    /// read. Grouped into a struct because the settlement path otherwise runs out of stack.
    struct PositionState {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 available;
        Currency residualCurrency;
        bool loanIsCurrency0;
    }

    /// @notice The position manager holding the maker's NFT.
    address public immutable POSITION_MANAGER;

    constructor(
        address owner,
        address midnight,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address poolManager,
        address positionManager,
        PoolKey memory route
    ) UniswapV4BuyCallbackBase(owner, midnight, priceRef, maxSlippageWad, poolManager, route) {
        require(positionManager != address(0), ZeroAddress());
        POSITION_MANAGER = positionManager;
    }

    /// SETTLEMENT ///

    /// @dev Two phases, because they cannot be one. Phase one decreases through the position
    /// manager, which hands over both sides as tokens. Phase two opens our own unlock to sell the
    /// residual.
    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal override {
        uint256 tokenId = abi.decode(data, (uint256));
        PositionState memory position = _position(tokenId, loanToken);

        uint256 heldBefore = IERC20Extended(loanToken).balanceOf(address(this));

        uint128 burn = _liquidityForShortfall(
            position.key,
            position.tickLower,
            position.tickUpper,
            position.available,
            position.loanIsCurrency0,
            shortfall
        );
        _decreaseAndSell(tokenId, position, loanToken, burn);

        uint256 sourced = IERC20Extended(loanToken).balanceOf(address(this)) - heldBefore;

        // Same bounded escalation as the other two adapters.
        uint256 ceiling = SourcingMathLib.escalationCeiling(burn, position.available);
        if (sourced < shortfall && ceiling > burn) {
            _decreaseAndSell(tokenId, position, loanToken, uint128(ceiling - burn));
            sourced = IERC20Extended(loanToken).balanceOf(address(this)) - heldBefore;
        }

        require(sourced >= shortfall, InsufficientSourced());
    }

    /// @dev Both phases of one round: decrease through the position manager, then sell what it
    /// handed over. Split out because the escalation path runs it a second time.
    function _decreaseAndSell(uint256 tokenId, PositionState memory position, address loanToken, uint128 liquidity)
        internal
    {
        _decrease(tokenId, position.key, liquidity);
        _sellHeldResidual(position.residualCurrency, loanToken);
    }

    /// @dev Everything about the parked position, read from the position manager rather than
    /// trusted from `callbackData`.
    function _position(uint256 tokenId, address loanToken) internal view returns (PositionState memory position) {
        uint256 info;
        (position.key, info) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
        (,, position.loanIsCurrency0) = _currencies(loanToken, position.key);

        position.residualCurrency = position.loanIsCurrency0 ? position.key.currency1 : position.key.currency0;
        position.tickLower = V4PositionInfo.tickLower(info);
        position.tickUpper = V4PositionInfo.tickUpper(info);
        position.available = IV4PositionManager(POSITION_MANAGER).getPositionLiquidity(tokenId);
    }

    /// @dev Burns `liquidity` and takes both sides here as tokens.
    /// @dev `amount0Min`/`amount1Min` are zero, and that is not an oversight: removing liquidity
    /// leaves the price unchanged, so a decrease has no slippage to protect against. What it does
    /// is thin the book the residual is about to be sold into, and that lands on the swap, which is
    /// where the protection belongs (D8).
    function _decrease(uint256 tokenId, PoolKey memory key, uint128 liquidity) internal {
        if (liquidity == 0) return;

        bytes memory actions = abi.encodePacked(uint8(V4Actions.DECREASE_LIQUIDITY), uint8(V4Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));

        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Sells whatever residual this contract is holding, in its own unlock. Unlike the
    /// custodial adapter, the residual really is held here between the two phases — that is the
    /// difference the two adapters exist to measure.
    function _sellHeldResidual(Currency residualCurrency, address loanToken) internal {
        uint256 residual = IERC20Extended(Currency.unwrap(residualCurrency)).balanceOf(address(this));
        if (residual == 0) return;

        IPoolManager(POOL_MANAGER).unlock(abi.encode(residualCurrency, residual, loanToken));
    }

    /// @inheritdoc UniswapV4BuyCallbackBase
    function _onUnlock(bytes calldata data) internal override returns (bytes memory) {
        (Currency residualCurrency, uint256 amountIn, address loanToken) =
            abi.decode(data, (Currency, uint256, address));

        _swapResidual(residualCurrency, amountIn);

        // Pay the swap's input out of the tokens the decrease handed over, and take the proceeds.
        IPoolManager(POOL_MANAGER).sync(residualCurrency);
        SafeTransferLib.safeTransfer(Currency.unwrap(residualCurrency), POOL_MANAGER, amountIn);
        IPoolManager(POOL_MANAGER).settle();

        _takeAllTo(Currency.wrap(loanToken), address(this));

        return "";
    }

    /// QUOTING ///

    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        uint256 tokenId = abi.decode(data, (uint256));
        (PoolKey memory key, uint256 info) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
        (,, bool loanIsCurrency0) = _currencies(loanToken, key);

        return _boundFor(
            key,
            V4PositionInfo.tickLower(info),
            V4PositionInfo.tickUpper(info),
            IV4PositionManager(POSITION_MANAGER).getPositionLiquidity(tokenId),
            loanIsCurrency0
        );
    }
}
