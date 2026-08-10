// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LinearKinkIrm} from "../src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkConfig} from "../src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkParams} from "../src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {AdaptiveCurveIrm} from "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IConfigurableIrm} from "../src/common/IConfigurableIrm.sol";
import {ErrorsLib} from "../src/linear-kink-irm/libraries/ErrorsLib.sol";
import {OwnerManagerErrors} from "../src/common/OwnerManagerErrors.sol";
import {MarketParamsLib} from "../lib/lido-lend/src/libraries/MarketParamsLib.sol";
import {MarketParams, Market} from "../lib/lido-lend/src/interfaces/IMorpho.sol";

import "../lib/forge-std/src/Test.sol";

contract MockLinearKinkConfig {
    LinearKinkParams internal kinkParams;

    constructor(LinearKinkParams memory kinkParams_) {
        kinkParams = kinkParams_;
    }

    function setKinkParams(LinearKinkParams memory kinkParams_) external {
        kinkParams = kinkParams_;
    }

    function getKinkParams() external view returns (LinearKinkParams memory) {
        return kinkParams;
    }
}

contract WrongLinearKinkConfig {
    function getKinkParams() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract LinearKinkIrmTest is Test {
    using MarketParamsLib for MarketParams;

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
        _applyIrmConfig(owner, marketParams, _defaultParams());
    }

    /* HELPERS */

    function _deployIrm(address owner_, address manager_) internal returns (LinearKinkIrm irm_) {
        irm_ = new LinearKinkIrm(owner_, manager_);
    }

    function _defaultParams() internal pure returns (LinearKinkParams memory) {
        return LinearKinkParams({optimalUtilization: 0.9 ether, baseRate: 1e9, slope1: 4e9, slope2: 60e9});
    }

    function _applyIrmConfig(address caller, MarketParams memory params, LinearKinkParams memory kinkParams)
        internal
        returns (LinearKinkConfig config)
    {
        config = new LinearKinkConfig(kinkParams);
        vm.prank(caller);
        irm.applyIrmConfig(params, address(config));
    }

    function _market(uint256 supply, uint256 borrow) internal pure returns (Market memory m) {
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(borrow);
    }

    function _otherMarket() internal view returns (MarketParams memory p) {
        p = marketParams;
        p.lltv = 0.5 ether; // different id, unconfigured
    }

    /* COMMON ABI */

    function test_applyIrmConfigSelectorMatchesAdaptiveCurveIrm() public {
        bytes4 expected = bytes4(keccak256("applyIrmConfig((address,address,address,address,uint256),address)"));
        assertEq(LinearKinkIrm.applyIrmConfig.selector, expected);
        assertEq(AdaptiveCurveIrm.applyIrmConfig.selector, expected);
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
        _applyIrmConfig(owner, other, p);

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

    /* CONFIG ABI AND SNAPSHOT */

    function test_applyIrmConfig_revertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert();
        irm.applyIrmConfig(_otherMarket(), address(0));
    }

    function test_applyIrmConfig_revertsForEoa() public {
        address eoa = address(0xC0FFEE);
        assertEq(eoa.code.length, 0);

        vm.prank(owner);
        vm.expectRevert();
        irm.applyIrmConfig(_otherMarket(), eoa);
    }

    function test_applyIrmConfig_revertsWhenConfigCodeWasRemoved() public {
        LinearKinkConfig config = new LinearKinkConfig(_defaultParams());
        vm.etch(address(config), bytes(""));
        assertEq(address(config).code.length, 0);

        vm.prank(owner);
        vm.expectRevert();
        irm.applyIrmConfig(_otherMarket(), address(config));
    }

    function test_applyIrmConfig_revertsForWrongConfigType() public {
        WrongLinearKinkConfig config = new WrongLinearKinkConfig();

        vm.prank(owner);
        vm.expectRevert();
        irm.applyIrmConfig(_otherMarket(), address(config));
    }

    function test_applyIrmConfig_copiesParamsAndEmitsConfig() public {
        MarketParams memory other = _otherMarket();
        LinearKinkParams memory p = _defaultParams();
        p.baseRate = 7e9;
        LinearKinkConfig config = new LinearKinkConfig(p);

        vm.expectEmit(true, true, false, true, address(irm));
        emit IConfigurableIrm.IrmConfigApplied(other.id(), address(config));
        vm.prank(owner);
        irm.applyIrmConfig(other, address(config));

        (uint64 optU, uint64 base, uint64 s1, uint64 s2) = irm.marketKinkParams(other.id());
        assertEq(optU, p.optimalUtilization);
        assertEq(base, p.baseRate);
        assertEq(s1, p.slope1);
        assertEq(s2, p.slope2);
    }

    function test_rateCalculationUsesCopiedParamsNotConfig() public {
        MarketParams memory other = _otherMarket();
        LinearKinkParams memory applied = _defaultParams();
        applied.baseRate = 2e9;
        MockLinearKinkConfig config = new MockLinearKinkConfig(applied);

        vm.prank(owner);
        irm.applyIrmConfig(other, address(config));

        LinearKinkParams memory changed = LinearKinkParams({
            optimalUtilization: applied.optimalUtilization, baseRate: 8e9, slope1: 9e9, slope2: 10e9
        });
        config.setKinkParams(changed);

        assertEq(irm.borrowRateView(other, _market(1e18, 0)), applied.baseRate);
        assertEq(
            irm.borrowRateView(other, _market(1e18, 1e18)), uint256(applied.baseRate) + applied.slope1 + applied.slope2
        );

        (uint64 optU, uint64 base, uint64 s1, uint64 s2) = irm.marketKinkParams(other.id());
        assertEq(optU, applied.optimalUtilization);
        assertEq(base, applied.baseRate);
        assertEq(s1, applied.slope1);
        assertEq(s2, applied.slope2);
    }

    /* NO SETTER-SIDE VALUE VALIDATION */

    function test_applyIrmConfig_doesNotValidateReturnedValues() public {
        MarketParams memory other = _otherMarket();
        LinearKinkParams memory p = _defaultParams();
        p.slope2 = type(uint64).max; // Invalid under the documented peak-rate invariant.
        MockLinearKinkConfig config = new MockLinearKinkConfig(p);

        vm.prank(owner);
        irm.applyIrmConfig(other, address(config));

        (uint64 optU, uint64 base, uint64 s1, uint64 s2) = irm.marketKinkParams(other.id());
        assertEq(optU, p.optimalUtilization);
        assertEq(base, p.baseRate);
        assertEq(s1, p.slope1);
        assertEq(s2, p.slope2);
    }

    /* AUTHORIZATION & REPARAMETRIZATION */

    function test_applyIrmConfig_unauthorizedReverts() public {
        LinearKinkConfig config = new LinearKinkConfig(_defaultParams());
        vm.prank(outsider);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_AUTHORIZED));
        irm.applyIrmConfig(_otherMarket(), address(config));
    }

    function test_applyIrmConfig_managerCanApply() public {
        MarketParams memory other = _otherMarket();
        _applyIrmConfig(manager, other, _defaultParams());
        (uint64 optU,,,) = irm.marketKinkParams(other.id());
        assertTrue(optU != 0);
    }

    function test_applyIrmConfig_reparametrizesInPlace() public {
        LinearKinkParams memory p = _defaultParams();
        p.baseRate = 2e9;
        _applyIrmConfig(manager, marketParams, p);
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

    /* CONSTRUCTION */

    function test_constructor_setsRoles() public {
        LinearKinkIrm fresh = new LinearKinkIrm(owner, manager);
        assertEq(fresh.owner(), owner);
        assertEq(fresh.manager(), manager);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        new LinearKinkIrm(address(0), manager);
    }

    function test_constructor_rejectsZeroManager() public {
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        new LinearKinkIrm(owner, address(0));
    }
}
