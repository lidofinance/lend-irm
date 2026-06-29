// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {MarketConfigFactory} from "../src/adaptive-curve-irm/MarketConfigFactory.sol";
import {IMarketConfig} from "../src/adaptive-curve-irm/interfaces/IMarketConfig.sol";

import "../lib/forge-std/src/Test.sol";

// Minimal ERC-1967 upgradeable proxy, test-only (no admin gating, not production code).
contract TestERC1967Proxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    constructor(address implementation_) {
        _setImplementation(implementation_);
    }

    function upgradeTo(address newImplementation) external {
        _setImplementation(newImplementation);
    }

    function setAdmin(address newAdmin) external {
        assembly {
            sstore(_ADMIN_SLOT, newAdmin)
        }
    }

    function admin() external view returns (address adminAddress) {
        assembly {
            adminAddress := sload(_ADMIN_SLOT)
        }
    }

    function implementation() external view returns (address impl) {
        impl = _implementation();
    }

    function _setImplementation(address newImplementation) private {
        require(newImplementation.code.length > 0, "impl not a contract");
        assembly {
            sstore(_IMPL_SLOT, newImplementation)
        }
    }

    function _implementation() private view returns (address impl) {
        assembly {
            impl := sload(_IMPL_SLOT)
        }
    }

    fallback() external payable {
        address impl = _implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

/// The IRM is meant to run behind a proxy. Its only immutables (`MORPHO`, `OWNER`) are baked into the implementation
/// bytecode and read under `delegatecall`; its storage (`rateAtTarget`, `marketConfig`) lives in the proxy. Because
/// the owner is immutable, no initializer is needed and the constructor writes no storage. Changing the owner (or the
/// logic) is a proxy upgrade to a freshly-constructed implementation; the proxy's storage persists.
contract AdaptiveCurveIrmProxyTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    MarketConfigFactory internal factory;
    MarketParams internal params;
    Id internal id;

    function setUp() public {
        factory = new MarketConfigFactory();
        vm.warp(90 days);
    }

    /// The immutables are readable through the proxy (delegatecall reads the impl bytecode), and a config set through
    /// the proxy lands in proxy storage and prices the market.
    function test_immutablesReadableThroughProxy() public {
        address proxy = _wiredProxy(address(this));

        assertEq(AdaptiveCurveIrm(proxy).MORPHO(), address(this), "MORPHO through proxy");
        assertEq(AdaptiveCurveIrm(proxy).OWNER(), address(this), "OWNER through proxy");

        Market memory market = _market(TARGET);
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, market),
            uint256(_defaultConfig().initialRateAtTarget),
            "prices"
        );
    }

    /// A logic upgrade (same owner) preserves marketConfig and rateAtTarget; pricing is unchanged.
    function test_upgrade_logicSwap_preservesConfigAndRateAtTarget() public {
        address proxy = _wiredProxy(address(this));
        _adaptUp(proxy);

        address configBefore = address(AdaptiveCurveIrm(proxy).marketConfig(id));
        int256 rateBefore = AdaptiveCurveIrm(proxy).rateAtTarget(id);
        assertGt(rateBefore, int256(0), "rateAtTarget seeded");

        TestERC1967Proxy(payable(proxy)).upgradeTo(address(new AdaptiveCurveIrm(address(this), address(this))));

        assertEq(
            address(AdaptiveCurveIrm(proxy).marketConfig(id)), configBefore, "marketConfig persisted across upgrade"
        );
        assertEq(AdaptiveCurveIrm(proxy).rateAtTarget(id), rateBefore, "rateAtTarget persisted across upgrade");
    }

    /// Changing the owner is an upgrade to an implementation constructed with the new owner; state persists.
    function test_upgrade_changesOwner() public {
        address proxy = _wiredProxy(address(this));
        _adaptUp(proxy);
        address newOwner = makeAddr("newOwner");

        int256 rateBefore = AdaptiveCurveIrm(proxy).rateAtTarget(id);
        assertGt(rateBefore, int256(0), "rateAtTarget seeded");
        TestERC1967Proxy(payable(proxy)).upgradeTo(address(new AdaptiveCurveIrm(address(this), newOwner)));

        assertEq(AdaptiveCurveIrm(proxy).OWNER(), newOwner, "owner changed by the upgrade");
        assertEq(AdaptiveCurveIrm(proxy).rateAtTarget(id), rateBefore, "rateAtTarget persisted");

        IMarketConfig freshConfig = factory.createConfig(_defaultConfig());

        // The old owner (this) can no longer set configs.
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        AdaptiveCurveIrm(proxy).setConfig(id, freshConfig);

        // The new owner can.
        vm.prank(newOwner);
        AdaptiveCurveIrm(proxy).setConfig(id, freshConfig);
        assertEq(address(AdaptiveCurveIrm(proxy).marketConfig(id)), address(freshConfig), "new owner set the config");
    }

    /// The EIP-1967 impl/admin pointers live in their own slots, never touching rateAtTarget (slot 0).
    function test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget() public {
        address proxy = _wiredProxy(address(this));
        _adaptUp(proxy);
        int256 seededRate = AdaptiveCurveIrm(proxy).rateAtTarget(id);
        assertGt(seededRate, int256(0), "rateAtTarget seeded in slot 0");

        TestERC1967Proxy(payable(proxy)).setAdmin(address(0xADA));
        TestERC1967Proxy(payable(proxy)).upgradeTo(address(new AdaptiveCurveIrm(address(this), address(this))));

        assertEq(TestERC1967Proxy(payable(proxy)).admin(), address(0xADA), "admin slot written");
        assertEq(AdaptiveCurveIrm(proxy).rateAtTarget(id), seededRate, "rateAtTarget (slot 0) intact after slot writes");
    }

    /* HELPERS */

    function _defaultConfig() internal pure returns (IMarketConfig.Config memory) {
        return IMarketConfig.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / int256(365 days),
            targetUtilization: int256(TARGET),
            initialRateAtTarget: int256(0.04 ether) / int256(365 days),
            minRateAtTarget: int256(0.005 ether) / int256(365 days),
            maxRateAtTarget: int256(0.2 ether) / int256(365 days),
            maxBorrowRate: 0
        });
    }

    /// @dev A proxy over a fresh impl (morpho == this, owner == `owner_`), wired to a market with a config set.
    function _wiredProxy(address owner_) internal returns (address proxy) {
        proxy = address(new TestERC1967Proxy(address(new AdaptiveCurveIrm(address(this), owner_))));
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: proxy,
            lltv: 0.8 ether
        });
        id = params.id();
        IMarketConfig config = factory.createConfig(_defaultConfig());
        // owner_ must be this for the setUp path; tests that need a different owner upgrade afterwards.
        if (owner_ == address(this)) AdaptiveCurveIrm(proxy).setConfig(id, config);
    }

    function _adaptUp(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.98 ether);
        }
    }

    function _poke(address proxy, uint256 utilizationWad) internal {
        Market memory market = _market(utilizationWad);
        vm.warp(block.timestamp + 5 days);
        AdaptiveCurveIrm(proxy).borrowRate(params, market);
    }

    function _market(uint256 utilizationWad) internal view returns (Market memory market) {
        market.totalSupplyAssets = uint128(SUPPLY);
        market.totalBorrowAssets = uint128(SUPPLY * utilizationWad / 1e18);
        market.lastUpdate = uint128(block.timestamp);
    }
}
