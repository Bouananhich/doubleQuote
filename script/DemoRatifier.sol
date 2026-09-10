// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IRatifier} from "midnight/src/interfaces/IRatifier.sol";
import {Offer} from "midnight/src/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/src/libraries/ConstantsLib.sol";

/// @title DemoRatifier
/// @notice The maker's consent, as Midnight asks for it.
///
/// @dev `take` carries **no signature**. An offer is a plain struct the taker supplies, and the only
/// thing standing between it and settlement is the ratifier the offer names — which the maker must
/// separately have authorised on-chain with `setIsAuthorized`. So the ratifier *is* the maker's
/// consent, and publishing an offer means nothing more than letting someone see the struct.
///
/// @dev Midnight's own `DummyRatifier` accepts every offer that names it. This one accepts only
/// offers made by `OWNER`, which matters once it is deployed somewhere public: an address anyone
/// can read is an address anyone can name in an offer of their own.
///
/// @dev Demo scaffolding, not product. The contribution is the buy-callback in `src/`; this exists
/// because a maker cannot participate in Midnight at all without some ratifier, which is itself
/// worth noting in `FEEDBACK.md`.
contract DemoRatifier is IRatifier {
    address public immutable OWNER;

    constructor(address owner) {
        OWNER = owner;
    }

    function isRatified(Offer memory offer, bytes memory, address) external view returns (bytes32) {
        require(offer.maker == OWNER, "DemoRatifier: not my offer");
        return CALLBACK_SUCCESS;
    }
}
