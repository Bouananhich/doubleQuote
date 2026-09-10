// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Offer} from "midnight/src/interfaces/IMidnight.sol";
import {EIP712_DOMAIN_TYPEHASH} from "midnight/src/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "midnight/src/ratifiers/libraries/HashLib.sol";

/// @title OfferDigest
/// @notice What a maker has to sign, as a `view` — the thing `EcrecoverRatifier` does not expose.
///
/// @dev The ratifier verifies a signature over an EIP-712 digest it computes internally, and offers
/// no way to ask it what that digest *is*. So anyone signing an offer must reproduce
/// `HashLib.hashOffer`, the tree type hash and the domain separator themselves, in whatever language
/// they are working in. Morpho ships a TypeScript SDK that does it; a Solidity or CLI workflow has
/// to compile `HashLib`.
///
/// @dev And compiling it is not free: `HashLib` does not fit in the stack without the IR pipeline,
/// so it drags a compiler requirement into any build that touches it — which is why this sits in its
/// own file, importing nothing else. Anything importing `forge-std` alongside it fails to compile
/// entirely. See `foundry.toml` and `FRICTION.log`.
///
/// @dev Deploying this is not required to *use* Midnight. It exists so the demo can sign an offer
/// without a private key ever entering a script process: deploy once, `eth_call` for the digest,
/// sign it with `cast wallet sign`.
contract OfferDigest {
    address public immutable RATIFIER;

    constructor(address ratifier) {
        RATIFIER = ratifier;
    }

    /// @notice The Merkle root of a one-offer tree, and the digest to sign over it.
    /// @dev A single offer is the degenerate tree: the root is the offer hash and the proof is
    /// empty, so `offerTreeTypeHash(0)` is the type hash in play.
    function rootAndDigest(Offer memory offer) external view returns (bytes32 root, bytes32 digest) {
        root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSeparator = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, RATIFIER));
        digest = keccak256(bytes.concat("\x19\x01", domainSeparator, structHash));
    }
}
