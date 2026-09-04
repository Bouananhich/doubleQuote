// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {ERC20} from "midnight/test/erc20s/ERC20.sol";

import {UniswapBuyCallbackBase} from "../../src/UniswapBuyCallbackBase.sol";
import {UniswapBuyCallbackFactoryBase} from "../../src/UniswapBuyCallbackFactoryBase.sol";
import {IPriceRef} from "../../src/interfaces/IPriceRef.sol";

/// @dev Stands in for a parked Uniswap position: it holds tokens and gives them up on demand.
/// `callbackData` names it, the way real `callbackData` names a pool and a position id.
contract MockParkedPosition {
    function unwind(address token, uint256 amount, address to) external {
        require(ERC20(token).transfer(to, amount), "unwind failed");
    }
}

/// @dev Concrete `UniswapBuyCallbackBase` with the venue hooks stubbed, so the base's own logic —
/// the guards, the buffer-first path, the bound composition, `skim` — can be tested without a
/// fork. The v3 and v4 adapters get their own fork tests.
contract MockUniswapBuyCallback is UniswapBuyCallbackBase {
    /// @dev Stands in for the routing venue an adapter pins as an immutable. Never read here; it
    /// exists so the factory's envelope keying has a venue-specific argument to cover.
    address public immutable ROUTE_POOL;

    /// @dev What `_sourceableBound` reports, capped by what the position actually holds. Models the
    /// slippage budget binding before the position runs out.
    uint256 public sourceableCap = type(uint256).max;

    /// @dev Test observability: how the base drove the venue hook.
    uint256 public sourceCalls;
    uint256 public lastShortfall;

    constructor(address owner, address midnight, IPriceRef priceRef, uint256 maxSlippageWad, address routePool)
        UniswapBuyCallbackBase(owner, midnight, priceRef, maxSlippageWad)
    {
        ROUTE_POOL = routePool;
    }

    function setSourceableCap(uint256 cap) external {
        sourceableCap = cap;
    }

    function _sourceLoanToken(address loanToken, uint256 shortfall, bytes memory data) internal override {
        sourceCalls++;
        lastShortfall = shortfall;

        MockParkedPosition(abi.decode(data, (address))).unwind(loanToken, shortfall, address(this));
    }

    function _sourceableBound(address loanToken, bytes memory data) internal view override returns (uint256) {
        uint256 held = ERC20(loanToken).balanceOf(abi.decode(data, (address)));
        return held < sourceableCap ? held : sourceableCap;
    }
}

/// @dev Concrete factory over `UniswapBuyCallbackFactoryBase`, shaped exactly as the v3 and v4
/// factories will be: derive the envelope key, deploy at it if empty, register.
contract MockUniswapBuyCallbackFactory is UniswapBuyCallbackFactoryBase {
    constructor(address midnight) UniswapBuyCallbackFactoryBase(midnight) {}

    function createCallback(address owner, IPriceRef priceRef, uint256 maxSlippageWad, address routePool, bytes32 salt)
        external
        returns (address)
    {
        bytes32 configSalt = _configSalt(owner, priceRef, maxSlippageWad, abi.encode(routePool), salt);

        address callback = callbackOf[configSalt];
        if (callback == address(0)) {
            callback = address(
                new MockUniswapBuyCallback{salt: configSalt}(owner, MIDNIGHT, priceRef, maxSlippageWad, routePool)
            );
        }
        _register(owner, configSalt, callback);

        return callback;
    }

    function computeConfigSalt(
        address owner,
        IPriceRef priceRef,
        uint256 maxSlippageWad,
        address routePool,
        bytes32 salt
    ) external pure returns (bytes32) {
        return _configSalt(owner, priceRef, maxSlippageWad, abi.encode(routePool), salt);
    }
}
