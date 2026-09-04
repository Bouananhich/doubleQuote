// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPriceRef} from "../src/interfaces/IPriceRef.sol";
import {IUniswapBuyCallbackFactory} from "../src/interfaces/IUniswapBuyCallbackFactory.sol";
import {MockUniswapBuyCallback, MockUniswapBuyCallbackFactory} from "./mocks/MockUniswapBuyCallback.sol";

/// @notice Forked from Morpho's `BlueBuyCallbackFactoryTest` (GPL-2.0-or-later), plus the case
/// Blue's `(owner, salt)` key shape cannot express: two envelopes, one salt.
contract UniswapBuyCallbackFactoryTest is Test {
    address internal midnight = makeAddr("midnight");
    address internal owner = makeAddr("owner");
    address internal routePool = makeAddr("routePool");
    IPriceRef internal priceRef = IPriceRef(makeAddr("priceRef"));
    uint256 internal constant MAX_SLIPPAGE_WAD = 0.003e18;

    MockUniswapBuyCallbackFactory internal factory;

    function setUp() public {
        factory = new MockUniswapBuyCallbackFactory(midnight);
    }

    function _create(bytes32 salt) internal returns (address) {
        return factory.createCallback(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt);
    }

    function testConstructor() public view {
        assertEq(factory.MIDNIGHT(), midnight);
    }

    function testCreateCallbackDeploysAtTheEnvelopeKey(bytes32 salt) public {
        vm.prank(owner);
        address callbackAddress = _create(salt);
        MockUniswapBuyCallback callback = MockUniswapBuyCallback(callbackAddress);

        bytes32 configSalt = factory.computeConfigSalt(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt);
        bytes32 initCodeHash = keccak256(
            bytes.concat(
                type(MockUniswapBuyCallback).creationCode,
                abi.encode(owner, midnight, priceRef, MAX_SLIPPAGE_WAD, routePool)
            )
        );

        assertEq(callbackAddress, vm.computeCreate2Address(configSalt, initCodeHash, address(factory)));
        assertEq(factory.callbackOf(configSalt), callbackAddress);
        assertTrue(factory.isUniswapBuyCallback(callbackAddress));

        assertEq(callback.OWNER(), owner);
        assertEq(callback.MIDNIGHT(), midnight);
        assertEq(address(callback.PRICE_REF()), address(priceRef));
        assertEq(callback.MAX_SLIPPAGE_WAD(), MAX_SLIPPAGE_WAD);
        assertEq(callback.ROUTE_POOL(), routePool);
    }

    function testCreateCallbackEmitsEvent(bytes32 salt) public {
        bytes32 configSalt = factory.computeConfigSalt(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt);

        vm.recordLogs();
        vm.prank(owner);
        address callback = _create(salt);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(factory));
        assertEq(logs[0].topics[0], IUniswapBuyCallbackFactory.CreateUniswapBuyCallback.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(owner))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(owner))));
        assertEq(logs[0].topics[3], configSalt);
        assertEq(abi.decode(logs[0].data, (address)), callback);
    }

    function testCreateCallbackIsIdempotent(bytes32 salt) public {
        vm.prank(owner);
        address callback = _create(salt);

        vm.prank(owner);
        address callbackAgain = _create(salt);

        assertEq(callbackAgain, callback);
        assertEq(
            factory.callbackOf(factory.computeConfigSalt(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt)), callback
        );
    }

    function testCreateMultipleCallbacksPerOwner(bytes32 salt1, bytes32 salt2) public {
        vm.assume(salt1 != salt2);

        vm.startPrank(owner);
        address callback1 = _create(salt1);
        address callback2 = _create(salt2);
        vm.stopPrank();

        assertTrue(callback1 != callback2);
        assertTrue(factory.isUniswapBuyCallback(callback1));
        assertTrue(factory.isUniswapBuyCallback(callback2));
    }

    function testCreateCallbackForOtherOwner(bytes32 salt) public {
        address caller = makeAddr("caller");

        vm.prank(caller);
        address callback = _create(salt);

        assertEq(MockUniswapBuyCallback(callback).OWNER(), owner);
    }

    function testIsUniswapBuyCallbackFalseForUnknownAddress(address account) public view {
        assertFalse(factory.isUniswapBuyCallback(account));
    }

    /// @dev The reason the registry is not keyed on `(owner, salt)`. Under Blue's key shape these
    /// two deployments — same owner, same salt, different slippage budget — land at different
    /// CREATE2 addresses while sharing one registry slot, so the second silently orphans the first
    /// and `callbackOf` reports an envelope the caller did not ask for.
    function testSameSaltDifferentEnvelopeAreDistinctAndBothIndexed(bytes32 salt) public {
        vm.startPrank(owner);
        address tight = factory.createCallback(owner, priceRef, 0.001e18, routePool, salt);
        address loose = factory.createCallback(owner, priceRef, 0.01e18, routePool, salt);
        vm.stopPrank();

        assertTrue(tight != loose, "envelope not reflected in the address");
        assertTrue(factory.isUniswapBuyCallback(tight));
        assertTrue(factory.isUniswapBuyCallback(loose));

        assertEq(factory.callbackOf(factory.computeConfigSalt(owner, priceRef, 0.001e18, routePool, salt)), tight);
        assertEq(factory.callbackOf(factory.computeConfigSalt(owner, priceRef, 0.01e18, routePool, salt)), loose);

        assertEq(MockUniswapBuyCallback(tight).MAX_SLIPPAGE_WAD(), 0.001e18);
        assertEq(MockUniswapBuyCallback(loose).MAX_SLIPPAGE_WAD(), 0.01e18);
    }

    /// @dev Same, for the venue-specific half of the envelope.
    function testSameSaltDifferentRouteVenueAreDistinct(bytes32 salt) public {
        address otherPool = makeAddr("otherRoutePool");

        vm.startPrank(owner);
        address a = factory.createCallback(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt);
        address b = factory.createCallback(owner, priceRef, MAX_SLIPPAGE_WAD, otherPool, salt);
        vm.stopPrank();

        assertTrue(a != b, "route venue not reflected in the address");
        assertEq(MockUniswapBuyCallback(a).ROUTE_POOL(), routePool);
        assertEq(MockUniswapBuyCallback(b).ROUTE_POOL(), otherPool);
    }

    /// @dev Same, for the price reference — the member of the envelope that matters most.
    function testSameSaltDifferentPriceRefAreDistinct(bytes32 salt) public {
        IPriceRef otherRef = IPriceRef(makeAddr("otherPriceRef"));

        vm.startPrank(owner);
        address a = factory.createCallback(owner, priceRef, MAX_SLIPPAGE_WAD, routePool, salt);
        address b = factory.createCallback(owner, otherRef, MAX_SLIPPAGE_WAD, routePool, salt);
        vm.stopPrank();

        assertTrue(a != b, "price reference not reflected in the address");
        assertEq(address(MockUniswapBuyCallback(a).PRICE_REF()), address(priceRef));
        assertEq(address(MockUniswapBuyCallback(b).PRICE_REF()), address(otherRef));
    }
}
