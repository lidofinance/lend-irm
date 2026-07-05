// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {LinearKinkIrm} from "../src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkParams} from "../src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {ErrorsLib} from "../src/linear-kink-irm/libraries/ErrorsLib.sol";
import {OwnerManagerErrors} from "../src/common/OwnerManagerErrors.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";

import "../lib/forge-std/src/Test.sol";

contract LinearKinkIrmTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant WAD = 1e18;

    // Slot 1 packs `manager` (offset 0) and `isInitialized` (offset 20): OwnerManagerBase lays out owner(0) then this,
    // and LinearKinkIrm appends marketKinkParams(2). The constructor sets isInitialized=true on the implementation;
    // clearing the slot unlocks a directly-deployed instance for `initialize` in tests.
    bytes32 internal constant PACKED_MANAGER_SLOT = bytes32(uint256(1));

    address internal owner = address(0xA11CE);
    address internal manager = address(0xB0B);
    address internal outsider = address(0xDEAD);

    LinearKinkIrm internal irm;
    MarketParams internal marketParams;

    function setUp() public {
        irm = _deployIrm(owner, manager);
        marketParams = MarketParams({
            loanToken: address(0x1),
            collateralToken: address(0x2),
            oracle: address(0x3),
            irm: address(irm),
            lltv: 0.8 ether
        });
        vm.prank(owner);
        irm.setMarketKinkParams(marketParams, _defaultParams());
    }

    /* HELPERS */

    function _deployIrm(address owner_, address manager_) internal returns (LinearKinkIrm irm_) {
        irm_ = new LinearKinkIrm();
        vm.store(address(irm_), PACKED_MANAGER_SLOT, 0); // undo the implementation lock for the test instance
        irm_.initialize(owner_, manager_);
    }

    function _defaultParams() internal pure returns (LinearKinkParams memory) {
        return LinearKinkParams({optimalUtilization: 0.9 ether, baseRate: 1e9, slope1: 4e9, slope2: 60e9});
    }

    function _market(uint256 supply, uint256 borrow) internal pure returns (Market memory m) {
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(borrow);
    }

    function _otherMarket() internal view returns (MarketParams memory p) {
        p = marketParams;
        p.lltv = 0.5 ether; // different id, unconfigured
    }

    /* RATE CURVE */

    function test_rateAtZeroUtilizationIsBaseRate() public {
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0)), 1e9);
    }

    function test_rateAtKinkIsBasePlusSlope1() public {
        // U = 0.9e18 == optimalUtilization
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0.9 ether)), 1e9 + 4e9);
    }

    function test_rateAtFullUtilizationIsPeak() public {
        // U = WAD
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 1e18)), 1e9 + 4e9 + 60e9);
    }

    function test_rateIsLinearOnSlope1Leg() public {
        // U = 0.45e18 = half of optimalUtilization -> baseRate + slope1/2
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0.45 ether)), 1e9 + 2e9);
    }

    function test_rateIsLinearOnSlope2Leg() public {
        // U = 0.95e18, halfway between kink (0.9) and full (1.0) -> baseRate + slope1 + slope2/2
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0.95 ether)), 1e9 + 4e9 + 30e9);
    }

    function test_borrowRateEqualsBorrowRateView() public {
        Market memory m = _market(1e18, 0.5 ether);
        assertEq(irm.borrowRate(marketParams, m), irm.borrowRateView(marketParams, m));
    }

    function test_overUtilizationClampsAtPeak() public {
        // borrow > supply cannot happen in Morpho, but the view is public; clamp to the peak.
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 2e18)), 1e9 + 4e9 + 60e9);
    }

    function test_zeroSupplyActsAsZeroUtilization() public {
        assertEq(irm.borrowRateView(marketParams, _market(0, 5e18)), 1e9);
    }

    function test_marketsAreIndependent() public {
        // configure a second market with a different curve; each id prices with its own params
        MarketParams memory other = _otherMarket();
        LinearKinkParams memory p = _defaultParams();
        p.baseRate = 7e9;
        vm.prank(owner);
        irm.setMarketKinkParams(other, p);

        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0)), 1e9);
        assertEq(irm.borrowRateView(other, _market(1e18, 0)), 7e9);
    }

    function testFuzz_monotonicAndBounded(uint128 supply, uint128 borrow1, uint128 borrow2) public {
        supply = uint128(bound(supply, 1, type(uint128).max));
        borrow1 = uint128(bound(borrow1, 0, supply));
        borrow2 = uint128(bound(borrow2, borrow1, supply)); // borrow2 >= borrow1 => U2 >= U1

        uint256 r1 = irm.borrowRateView(marketParams, _market(supply, borrow1));
        uint256 r2 = irm.borrowRateView(marketParams, _market(supply, borrow2));

        assertLe(r1, r2, "rate is non-decreasing in utilization");
        assertLe(r2, 1e9 + 4e9 + 60e9, "rate never exceeds the peak");
    }

    /* STORAGE / NOT SET */

    function test_paramsAreStoredAndReadable() public {
        (uint64 optU, uint64 base, uint64 s1, uint64 s2) = irm.marketKinkParams(marketParams.id());
        assertEq(optU, 0.9 ether);
        assertEq(base, 1e9);
        assertEq(s1, 4e9);
        assertEq(s2, 60e9);
    }

    function test_revertsWhenParamsNotSet() public {
        vm.expectRevert(bytes(ErrorsLib.CONFIG_NOT_SET));
        irm.borrowRateView(_otherMarket(), _market(1e18, 0.5 ether));
    }

    /* VALIDATION */

    function test_setRevertsOnZeroOptimalUtilization() public {
        LinearKinkParams memory p = _defaultParams();
        p.optimalUtilization = 0;
        vm.prank(owner);
        vm.expectRevert(bytes(ErrorsLib.INVALID_OPTIMAL_UTILIZATION));
        irm.setMarketKinkParams(_otherMarket(), p);
    }

    function test_setRevertsOnFullOptimalUtilization() public {
        LinearKinkParams memory p = _defaultParams();
        p.optimalUtilization = uint64(WAD);
        vm.prank(owner);
        vm.expectRevert(bytes(ErrorsLib.INVALID_OPTIMAL_UTILIZATION));
        irm.setMarketKinkParams(_otherMarket(), p);
    }

    function test_setRevertsWhenPeakRateExceedsMax() public {
        LinearKinkParams memory p = _defaultParams();
        p.slope2 = uint64(irm.MAX_BORROW_RATE()); // base + slope1 + slope2 > MAX
        vm.prank(owner);
        vm.expectRevert(bytes(ErrorsLib.MAX_RATE_EXCEEDED));
        irm.setMarketKinkParams(_otherMarket(), p);
    }

    /* AUTHORIZATION & REPARAMETRIZATION */

    function test_setMarketKinkParams_unauthorizedReverts() public {
        vm.prank(outsider);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_AUTHORIZED));
        irm.setMarketKinkParams(_otherMarket(), _defaultParams());
    }

    function test_setMarketKinkParams_managerCanSet() public {
        MarketParams memory other = _otherMarket();
        vm.prank(manager);
        irm.setMarketKinkParams(other, _defaultParams());
        (uint64 optU,,,) = irm.marketKinkParams(other.id());
        assertTrue(optU != 0);
    }

    function test_setMarketKinkParams_reparametrizesInPlace() public {
        LinearKinkParams memory p = _defaultParams();
        p.baseRate = 2e9;
        vm.prank(manager);
        irm.setMarketKinkParams(marketParams, p);
        assertEq(irm.borrowRateView(marketParams, _market(1e18, 0)), 2e9);
    }

    /* ROLES */

    function test_transferOwnership_ownerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_OWNER));
        irm.transferOwnership(address(0xCAFE));
    }

    function test_transferOwnership_works() public {
        vm.prank(owner);
        irm.transferOwnership(address(0xCAFE));
        assertEq(irm.owner(), address(0xCAFE));
    }

    function test_transferOwnership_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        irm.transferOwnership(address(0));
    }

    function test_setManager_ownerOnly() public {
        vm.prank(manager);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_OWNER));
        irm.setManager(address(0xCAFE));
    }

    function test_setManager_works() public {
        vm.prank(owner);
        irm.setManager(address(0xCAFE));
        assertEq(irm.manager(), address(0xCAFE));
    }

    /* INITIALIZATION */

    function test_initialize_isOneShot() public {
        vm.expectRevert(bytes(OwnerManagerErrors.ALREADY_INITIALIZED));
        irm.initialize(owner, manager);
    }

    function test_implementationIsLocked() public {
        LinearKinkIrm impl = new LinearKinkIrm();
        vm.expectRevert(bytes(OwnerManagerErrors.ALREADY_INITIALIZED));
        impl.initialize(owner, manager);
    }

    function test_initialize_rejectsZeroOwner() public {
        LinearKinkIrm fresh = new LinearKinkIrm();
        vm.store(address(fresh), PACKED_MANAGER_SLOT, 0);
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        fresh.initialize(address(0), manager);
    }

    function test_initialize_rejectsZeroManager() public {
        LinearKinkIrm fresh = new LinearKinkIrm();
        vm.store(address(fresh), PACKED_MANAGER_SLOT, 0);
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        fresh.initialize(owner, address(0));
    }
}
