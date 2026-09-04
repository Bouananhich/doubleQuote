// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";
import {SafeTransferLib} from "midnight/src/libraries/SafeTransferLib.sol";
import {IERC20Extended} from "midnight/src/periphery/blue-buy-callback/interfaces/IERC20Extended.sol";
import {ERC20Lib} from "midnight/src/periphery/libraries/ERC20Lib.sol";

import {IMidnightBuyCallback} from "./interfaces/IMidnightBuyCallback.sol";
import {IPriceRef} from "./interfaces/IPriceRef.sol";

/// @title UniswapBuyCallbackBase
/// @notice A Midnight maker buy callback that parks the maker's capital in a Uniswap LP position
/// instead of a lending market, and unwinds just enough of it to settle when an offer is taken.
///
/// @dev Forked in shape from Morpho's `BlueBuyCallback` (GPL-2.0-or-later). Everything that does
/// not depend on which Uniswap version holds the position lives here; the two adapters supply
/// `_sourceLoanToken` and `_sourceableBound`.
///
/// @dev The split between the two halves of the callback interface is the whole design:
///
///   - `buyerAssetsBound` is an `external view`, reached off-chain through `eth_call`, so it is
///     effectively gas-free and can afford real math. A maker parked in a vault answers "how much
///     can you fill?" with their balance. A maker parked in an LP position has a more interesting
///     answer, because marginal sourcing cost rises with size.
///   - `onBuy` runs on the taker's gas at settlement and must stay cheap.
///
///   Model in the view, execute in the callback.
///
/// @dev The safety envelope — `OWNER`, `MIDNIGHT`, `PRICE_REF`, `MAX_SLIPPAGE_WAD`, and whatever
/// routing venue an adapter adds — is immutable, fixed at deployment. None of it is reachable
/// through `callbackData`, which is maker-signed at offer creation and static: the callback can
/// never be handed a fresh route, a `minOut`, or a price at execution time. Every execution-time
/// decision derives from on-chain state. That is a constraint, and it is also what forces the
/// slippage bound to be a formula rather than a config field.
///
/// @dev Parking is permissionless by design. `callbackData` names the pool and position, and this
/// contract does not whitelist them — a maker forced to migrate liquidity into a blessed pool is no
/// longer an existing LP, which is the whole thesis. A maker who points an offer at a bad parking
/// venue harms only themselves; the take reverts if the loan tokens fail to arrive. Routing and
/// referencing are *not* permissionless, because a maker signing an offer that routes through a
/// manipulable pool is the sandwich vector itself.
///
/// @dev Inherits the token safety requirements of Midnight (see `Midnight.sol`).
abstract contract UniswapBuyCallbackBase is IMidnightBuyCallback {
    /// @notice Hard ceiling on the deployable slippage budget, 10%.
    /// @dev Not a recommendation — a sane budget is orders of magnitude tighter, and on the stable
    /// venue it is a handful of basis points. This only stops a fat-fingered or socially-engineered
    /// envelope from being deployed at all.
    uint256 internal constant MAX_SLIPPAGE_CEILING_WAD = 0.1e18;

    /// @inheritdoc IMidnightBuyCallback
    address public immutable OWNER;
    /// @inheritdoc IMidnightBuyCallback
    address public immutable MIDNIGHT;
    /// @inheritdoc IMidnightBuyCallback
    IPriceRef public immutable PRICE_REF;
    /// @inheritdoc IMidnightBuyCallback
    uint256 public immutable MAX_SLIPPAGE_WAD;

    constructor(address owner, address midnight, IPriceRef priceRef, uint256 maxSlippageWad) {
        require(owner != address(0), ZeroAddress());
        require(midnight != address(0), ZeroAddress());
        require(address(priceRef) != address(0), ZeroAddress());
        require(maxSlippageWad <= MAX_SLIPPAGE_CEILING_WAD, SlippageBudgetTooLarge());

        OWNER = owner;
        MIDNIGHT = midnight;
        PRICE_REF = priceRef;
        MAX_SLIPPAGE_WAD = maxSlippageWad;
    }

    /// @notice Settles a take by making `buyerAssets` of the loan token available to Midnight.
    ///
    /// @dev Buffer first, position second. Idle loan token held here serves the fill directly; the
    /// LP position is only touched for the shortfall. This is not just a gas optimisation. `onBuy`
    /// is guarded against arbitrary callers, but any taker can fire it with a dust take, and
    /// repeated dust takes forcing a micro-unwind and micro-swap each time bleed the maker through
    /// fees and slippage at the attacker's chosen price. That is extractive rather than merely
    /// annoying, and the buffer is what flattens it.
    ///
    /// @dev Does not verify the tokens arrived. Midnight checks that after the callback returns, so
    /// re-checking here would spend the taker's gas to produce a second revert on the same
    /// condition.
    function onBuy(
        bytes32,
        Market memory market,
        uint256 buyerAssets,
        uint256,
        uint256,
        address buyer,
        bytes memory data
    ) external returns (bytes32) {
        require(msg.sender == MIDNIGHT, NotMidnight());
        require(buyer == OWNER, NotOwnerBuyer());

        address loanToken = market.loanToken;
        uint256 buffered = IERC20Extended(loanToken).balanceOf(address(this));
        if (buyerAssets > buffered) _sourceLoanToken(loanToken, buyerAssets - buffered, data);

        ERC20Lib.safeApprove(loanToken, MIDNIGHT, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    /// @notice Largest `buyerAssets` amount this callback can source, for this buyer, right now.
    ///
    /// @dev Takers receive the amount to take per offer from a routing layer, which is
    /// asynchronous and offchain and might not be up to date on the chain's latest state. This
    /// function exists so a taker can cap their take against live state atomically.
    ///
    /// @dev The bound is the buffer plus whatever the parked position can source *within
    /// `MAX_SLIPPAGE_WAD` of `PRICE_REF`*. Publishing a size-aware bound is the alternative to
    /// defending against bad execution with a revert: rather than accepting any fill and failing
    /// late, the maker advertises the largest fill they can actually honour. Sandwich resistance
    /// stops being a patch and becomes the quote.
    ///
    /// @dev Reverts if `data` is not well formed, or if `PRICE_REF` has no price for the pair. A
    /// routing layer must read a revert as "no bound available", which is not the same as zero.
    ///
    /// @dev Diverges from `BlueBuyCallback`, which documents that it ignores static reasons the
    /// bound might be smaller — such as the wrong buyer — and leaves them to the routing layer.
    /// Returning a non-zero bound for an offer that would revert on take is misleading, and one
    /// comparison in a gas-free view is not worth saving.
    function buyerAssetsBound(bytes32, Market memory market, address buyer, bytes memory data)
        external
        view
        returns (uint256)
    {
        if (buyer != OWNER) return 0;

        address loanToken = market.loanToken;
        return IERC20Extended(loanToken).balanceOf(address(this)) + _sourceableBound(loanToken, data);
    }

    /// @notice Sends this contract's whole balance of `token` to `OWNER`.
    /// @dev Owner-only, unlike Blue's permissionless equivalent: `token` may be the loan token, in
    /// which case skimming empties the buffer and re-opens the dust-take bleed to anyone willing to
    /// pay for the call.
    function skim(address token) external {
        require(msg.sender == OWNER, NotOwner());

        uint256 balance = IERC20Extended(token).balanceOf(address(this));
        SafeTransferLib.safeTransfer(token, OWNER, balance);
        emit Skim(msg.sender, token, balance);
    }

    /// @dev Unwinds enough of the parked position to leave at least `shortfall` more `loanToken` in
    /// this contract, or reverts. Sourcing more than `shortfall` is allowed — the excess simply
    /// becomes buffer for the next fill.
    /// @dev Runs on the taker's gas. Keep it cheap; the modelling belongs in `_sourceableBound`.
    /// @param data The maker-signed `callbackData`, naming the parking venue and position.
    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal virtual;

    /// @dev Largest *additional* `loanToken` amount the parked position could source within
    /// `MAX_SLIPPAGE_WAD` of `PRICE_REF`, excluding the buffer, which the caller adds.
    /// @dev `view`, so it can afford the real math. See `SourcingMathLib`.
    function _sourceableBound(address loanToken, bytes memory data) internal view virtual returns (uint256);
}
