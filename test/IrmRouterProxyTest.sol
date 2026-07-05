// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IrmRouter} from "../src/irm-router/IrmRouter.sol";
import {OwnerManagerErrors} from "../src/common/OwnerManagerErrors.sol";
import {IIrm} from "../lib/lido-lend/src/interfaces/IIrm.sol";
import {MarketParamsLib} from "../lib/lido-lend/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../lib/lido-lend/src/interfaces/IMorpho.sol";

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

/// A constant-rate IRM stub: enough for the router's probe and forwarding to succeed in proxy-level tests.
contract DummyIrm is IIrm {
    uint256 internal constant RATE = uint256(0.01 ether) / uint256(365 days);

    function borrowRate(MarketParams memory, Market memory) external pure returns (uint256) {
        return RATE;
    }

    function borrowRateView(MarketParams memory, Market memory) external pure returns (uint256) {
        return RATE;
    }
}

/// The ROUTER is the proxied contract (the IRM implementations are immutable): its only immutable (`MORPHO`) is baked
/// into the implementation bytecode and read under `delegatecall`. Its storage (`owner`, `manager`, `marketIrm`)
/// lives in the proxy. The roles are set once through the proxy via `initialize` and rotated with
/// `transferOwnership`/`setManager`. A logic upgrade to a freshly-constructed implementation preserves the proxy's
/// storage, including the per-market routing table.
contract IrmRouterProxyTest is Test {
    using MarketParamsLib for MarketParams;

    address internal owner = address(0xA11CE);
    address internal manager = address(0xB0B);

    MarketParams internal params;
    Id internal id;

    /// @dev The test doubles as MORPHO for the routers it deploys: `setMarketIrm` reads `market(id)` from it. An
    /// all-zero market (lastUpdate == 0) makes the router route without accruing or probing.
    function market(Id) external pure returns (Market memory m) {}

    /// `initialize` works exactly once through the proxy and reverts ALREADY_INITIALIZED after.
    function test_initializeThroughProxy_isOneShot() public {
        address proxy = address(new TestERC1967Proxy(address(new IrmRouter(address(this)))));

        assertFalse(IrmRouter(proxy).isInitialized(), "proxy storage starts uninitialized");
        IrmRouter(proxy).initialize(owner, manager);
        assertTrue(IrmRouter(proxy).isInitialized(), "initialized through the proxy");
        assertEq(IrmRouter(proxy).owner(), owner, "owner set through the proxy");
        assertEq(IrmRouter(proxy).manager(), manager, "manager set through the proxy");

        vm.expectRevert(bytes(OwnerManagerErrors.ALREADY_INITIALIZED));
        IrmRouter(proxy).initialize(owner, manager);
    }

    /// `initialize` rejects the zero address for either role.
    function test_initializeThroughProxy_rejectsZeroRoles() public {
        address proxy = address(new TestERC1967Proxy(address(new IrmRouter(address(this)))));

        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        IrmRouter(proxy).initialize(address(0), manager);

        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        IrmRouter(proxy).initialize(owner, address(0));
    }

    /// A market routed through the proxy prices with the routed implementation's rate.
    function test_routedMarketPricesThroughProxy() public {
        address proxy = _wiredProxy();
        address irm = _routeMarket(proxy);

        Market memory m;
        assertEq(
            IrmRouter(proxy).borrowRateView(params, m),
            DummyIrm(irm).borrowRateView(params, m),
            "the proxied router forwards pricing to the routed implementation"
        );
    }

    /// The constructor rejects a zero Morpho.
    function test_constructor_rejectsZeroMorpho() public {
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        new IrmRouter(address(0));
    }

    /// A raw implementation is locked at construction: its constructor sets isInitialized, so only a proxy (whose
    /// storage starts zeroed) can be initialized.
    function test_implementationIsLockedAtConstruction() public {
        IrmRouter impl = new IrmRouter(address(this));

        assertTrue(impl.isInitialized(), "implementation locked at construction");
        vm.expectRevert(bytes(OwnerManagerErrors.ALREADY_INITIALIZED));
        impl.initialize(owner, manager);
    }

    /// MORPHO (immutable) is readable through the proxy: delegatecall reads the implementation bytecode.
    function test_morphoReadsThroughProxy() public {
        address proxy = _wiredProxy();

        assertEq(IrmRouter(proxy).MORPHO(), address(this), "MORPHO through the proxy");
    }

    /// The roles rotate through the proxy: transferOwnership moves the owner-only powers, setManager rotates the
    /// manager.
    function test_rolesRotateThroughProxy() public {
        address proxy = _wiredProxy();
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        IrmRouter(proxy).transferOwnership(newOwner);
        assertEq(IrmRouter(proxy).owner(), newOwner, "owner rotated through the proxy");

        // The old owner lost the owner-only power and the new owner has it.
        vm.prank(owner);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_OWNER));
        IrmRouter(proxy).setManager(address(0xCAFE));

        vm.prank(newOwner);
        IrmRouter(proxy).setManager(address(0xCAFE));
        assertEq(IrmRouter(proxy).manager(), address(0xCAFE), "new owner rotated the manager");
    }

    /// A logic upgrade to a freshly-constructed router preserves the owner, the manager, and the routing table.
    function test_upgrade_logicSwap_preservesState() public {
        address proxy = _wiredProxy();
        address irmBefore = _routeMarket(proxy);

        TestERC1967Proxy(payable(proxy)).upgradeTo(address(new IrmRouter(address(this))));

        assertEq(IrmRouter(proxy).owner(), owner, "owner persisted across the upgrade");
        assertEq(IrmRouter(proxy).manager(), manager, "manager persisted across the upgrade");
        assertEq(address(IrmRouter(proxy).marketIrm(id)), irmBefore, "marketIrm persisted across the upgrade");
    }

    /// The EIP-1967 impl/admin pointers live in their own slots, never touching the marketIrm mapping (the router
    /// storage sits at its ERC-7201 namespaced base).
    function test_proxyImplAndAdminSlots_doNotCollideWithMarketIrm() public {
        address proxy = _wiredProxy();
        address irmBefore = _routeMarket(proxy);

        TestERC1967Proxy(payable(proxy)).setAdmin(address(0xADA));
        address newImpl = address(new IrmRouter(address(this)));
        TestERC1967Proxy(payable(proxy)).upgradeTo(newImpl);

        assertEq(TestERC1967Proxy(payable(proxy)).admin(), address(0xADA), "admin slot written");
        assertEq(TestERC1967Proxy(payable(proxy)).implementation(), newImpl, "impl slot written");
        assertEq(address(IrmRouter(proxy).marketIrm(id)), irmBefore, "marketIrm intact after slot writes");
        assertEq(IrmRouter(proxy).owner(), owner, "owner intact after slot writes");
    }

    /* HELPERS */

    /// @dev A proxy over a fresh implementation (MORPHO == this), initialized with the test roles, with the market
    /// (`params`/`id`) pointing at it.
    function _wiredProxy() internal returns (address proxy) {
        proxy = address(new TestERC1967Proxy(address(new IrmRouter(address(this)))));
        IrmRouter(proxy).initialize(owner, manager);
        params = MarketParams({
            loanToken: address(0x1), collateralToken: address(0x2), oracle: address(0x3), irm: proxy, lltv: 0.8 ether
        });
        id = params.id();
    }

    /// @dev Routes the wired market to a fresh DummyIrm through the proxy and returns its address.
    function _routeMarket(address proxy) internal returns (address irm) {
        irm = address(new DummyIrm());
        vm.prank(owner);
        IrmRouter(proxy).setMarketIrm(params, IIrm(irm));
        assertEq(address(IrmRouter(proxy).marketIrm(id)), irm, "market routed");
    }
}
