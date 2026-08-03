// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IrmConfigFactory} from "../src/irm-config-factory/IrmConfigFactory.sol";
import {IAdaptiveCurveConfig} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {ErrorsLib as AdaptiveErrorsLib} from "../src/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {ILinearKinkConfig} from "../src/linear-kink-irm/interfaces/ILinearKinkConfig.sol";
import {LinearKinkParams} from "../src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {ErrorsLib as LinearKinkErrorsLib} from "../src/linear-kink-irm/libraries/ErrorsLib.sol";
import {ConstantsLib} from "./ConstantsLib.sol";

import {Test} from "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";

contract IrmConfigFactoryTest is Test {
    bytes32 internal constant ADAPTIVE_DEPLOYED_EVENT_SIGNATURE =
        keccak256("AdaptiveCurveConfigDeployed(bytes32,address)");
    bytes32 internal constant LINEAR_KINK_DEPLOYED_EVENT_SIGNATURE =
        keccak256("LinearKinkConfigDeployed(bytes32,address)");

    IrmConfigFactory internal factory;

    function setUp() public {
        factory = new IrmConfigFactory();
    }

    function test_getOrDeployAdaptiveCurveConfig_deploysAndResolvesByParams() public {
        AdaptiveCurveParams memory params = _adaptiveParams();
        bytes32 paramsHash = keccak256(abi.encode(params));
        assertEq(factory.getAdaptiveCurveConfig(params), address(0), "config not deployed");

        vm.recordLogs();
        vm.prank(makeAddr("permissionless caller"));
        address config = factory.getOrDeployAdaptiveCurveConfig(params);

        assertGt(config.code.length, 0, "config deployed");
        assertEq(factory.getAdaptiveCurveConfig(params), config, "config resolved by params");
        _assertAdaptiveParamsEq(IAdaptiveCurveConfig(config).getCurveParams(), params);
        _assertDeploymentEvent(vm.getRecordedLogs(), ADAPTIVE_DEPLOYED_EVENT_SIGNATURE, paramsHash, config);
    }

    function test_getOrDeployAdaptiveCurveConfig_reusesExistingConfig() public {
        AdaptiveCurveParams memory params = _adaptiveParams();
        address first = factory.getOrDeployAdaptiveCurveConfig(params);

        vm.recordLogs();
        vm.prank(makeAddr("another caller"));
        address second = factory.getOrDeployAdaptiveCurveConfig(params);

        assertEq(second, first, "same params reuse config");
        assertEq(vm.getRecordedLogs().length, 0, "reuse emits no deployment event");
    }

    function test_getOrDeployAdaptiveCurveConfig_distinctParamsDeployDistinctConfigs() public {
        AdaptiveCurveParams memory firstParams = _adaptiveParams();
        AdaptiveCurveParams memory secondParams = _adaptiveParams();
        secondParams.maxBorrowRate = 1;

        address first = factory.getOrDeployAdaptiveCurveConfig(firstParams);
        address second = factory.getOrDeployAdaptiveCurveConfig(secondParams);

        assertNotEq(second, first, "different params deploy different configs");
        assertEq(factory.getAdaptiveCurveConfig(firstParams), first);
        assertEq(factory.getAdaptiveCurveConfig(secondParams), second);
    }

    function test_getOrDeployAdaptiveCurveConfig_constructorValidationReverts() public {
        AdaptiveCurveParams memory params = _adaptiveParams();
        params.curveSteepness = 0;

        vm.expectRevert(bytes(AdaptiveErrorsLib.INVALID_CURVE_STEEPNESS));
        factory.getOrDeployAdaptiveCurveConfig(params);

        assertEq(factory.getAdaptiveCurveConfig(params), address(0), "invalid params are not indexed");
    }

    function test_getOrDeployLinearKinkConfig_deploysAndResolvesByParams() public {
        LinearKinkParams memory params = _linearKinkParams();
        bytes32 paramsHash = keccak256(abi.encode(params));
        assertEq(factory.getLinearKinkConfig(params), address(0), "config not deployed");

        vm.recordLogs();
        vm.prank(makeAddr("permissionless caller"));
        address config = factory.getOrDeployLinearKinkConfig(params);

        assertGt(config.code.length, 0, "config deployed");
        assertEq(factory.getLinearKinkConfig(params), config, "config resolved by params");
        _assertLinearKinkParamsEq(ILinearKinkConfig(config).getKinkParams(), params);
        _assertDeploymentEvent(vm.getRecordedLogs(), LINEAR_KINK_DEPLOYED_EVENT_SIGNATURE, paramsHash, config);
    }

    function test_getOrDeployLinearKinkConfig_reusesExistingConfig() public {
        LinearKinkParams memory params = _linearKinkParams();
        address first = factory.getOrDeployLinearKinkConfig(params);

        vm.recordLogs();
        vm.prank(makeAddr("another caller"));
        address second = factory.getOrDeployLinearKinkConfig(params);

        assertEq(second, first, "same params reuse config");
        assertEq(vm.getRecordedLogs().length, 0, "reuse emits no deployment event");
    }

    function test_getOrDeployLinearKinkConfig_distinctParamsDeployDistinctConfigs() public {
        LinearKinkParams memory firstParams = _linearKinkParams();
        LinearKinkParams memory secondParams = _linearKinkParams();
        secondParams.baseRate += 1;

        address first = factory.getOrDeployLinearKinkConfig(firstParams);
        address second = factory.getOrDeployLinearKinkConfig(secondParams);

        assertNotEq(second, first, "different params deploy different configs");
        assertEq(factory.getLinearKinkConfig(firstParams), first);
        assertEq(factory.getLinearKinkConfig(secondParams), second);
    }

    function test_getOrDeployLinearKinkConfig_constructorValidationReverts() public {
        LinearKinkParams memory params = _linearKinkParams();
        params.optimalUtilization = 0;

        vm.expectRevert(bytes(LinearKinkErrorsLib.INVALID_OPTIMAL_UTILIZATION));
        factory.getOrDeployLinearKinkConfig(params);

        assertEq(factory.getLinearKinkConfig(params), address(0), "invalid params are not indexed");
    }

    function _adaptiveParams() internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: ConstantsLib.CURVE_STEEPNESS,
            adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
            targetUtilization: ConstantsLib.TARGET_UTILIZATION,
            initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
            minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
            maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }

    function _linearKinkParams() internal pure returns (LinearKinkParams memory) {
        return LinearKinkParams({optimalUtilization: 0.9 ether, baseRate: 1e9, slope1: 4e9, slope2: 60e9});
    }

    function _assertAdaptiveParamsEq(AdaptiveCurveParams memory actual, AdaptiveCurveParams memory expected) internal {
        assertEq(actual.curveSteepness, expected.curveSteepness, "curveSteepness");
        assertEq(actual.adjustmentSpeed, expected.adjustmentSpeed, "adjustmentSpeed");
        assertEq(actual.targetUtilization, expected.targetUtilization, "targetUtilization");
        assertEq(actual.initialRateAtTarget, expected.initialRateAtTarget, "initialRateAtTarget");
        assertEq(actual.minRateAtTarget, expected.minRateAtTarget, "minRateAtTarget");
        assertEq(actual.maxRateAtTarget, expected.maxRateAtTarget, "maxRateAtTarget");
        assertEq(actual.maxBorrowRate, expected.maxBorrowRate, "maxBorrowRate");
    }

    function _assertLinearKinkParamsEq(LinearKinkParams memory actual, LinearKinkParams memory expected) internal {
        assertEq(actual.optimalUtilization, expected.optimalUtilization, "optimalUtilization");
        assertEq(actual.baseRate, expected.baseRate, "baseRate");
        assertEq(actual.slope1, expected.slope1, "slope1");
        assertEq(actual.slope2, expected.slope2, "slope2");
    }

    function _assertDeploymentEvent(Vm.Log[] memory logs, bytes32 signature, bytes32 paramsHash, address config)
        internal
    {
        assertEq(logs.length, 1, "one deployment event");
        assertEq(logs[0].emitter, address(factory), "event emitter");
        assertEq(logs[0].topics.length, 3, "event has three topics");
        assertEq(logs[0].topics[0], signature, "event signature");
        assertEq(logs[0].topics[1], paramsHash, "event params hash");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), config, "event config");
        assertEq(logs[0].data.length, 0, "event has no data");
    }
}
