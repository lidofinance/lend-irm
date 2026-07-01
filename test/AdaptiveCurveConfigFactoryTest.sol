// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdaptiveCurveConfig} from "../src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveConfigFactory} from "../src/adaptive-curve-irm/AdaptiveCurveConfigFactory.sol";
import {IAdaptiveCurveConfig} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {ConstantsLib} from "./ConstantsLib.sol";

import "../lib/forge-std/src/Test.sol";

contract AdaptiveCurveConfigFactoryTest is Test {
    event ConfigCreated(address indexed config);

    AdaptiveCurveConfigFactory internal factory;

    function setUp() public {
        factory = new AdaptiveCurveConfigFactory();
    }

    /// createConfig is permissionless: any caller can deploy a config, and it is recorded under its params hash.
    function testCreateConfigIsPermissionless(address caller) public {
        IAdaptiveCurveConfig.Params memory params = _defaultConfig();

        vm.prank(caller);
        address config = address(factory.createConfig(params));

        assertEq(address(factory.configFor(_hash(params))), config, "config recorded under its params hash");
        assertEq(
            IAdaptiveCurveConfig(config).getCurveParams().curveSteepness,
            ConstantsLib.CURVE_STEEPNESS,
            "config round-trips"
        );
    }

    /// createConfig emits ConfigCreated with the deployed config address.
    function testCreateConfigEmitsEvent() public {
        // address not known ahead of time; check only that the event fires from the factory.
        vm.recordLogs();
        address config = address(factory.createConfig(_defaultConfig()));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("ConfigCreated(address)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), config, "event carries the config address");
                found = true;
            }
        }
        assertTrue(found, "ConfigCreated emitted");
    }

    /// Identical params deduplicate: the second createConfig returns the existing config and deploys nothing new.
    function testCreateConfigDeduplicates() public {
        address first = address(factory.createConfig(_defaultConfig()));

        vm.recordLogs();
        address second = address(factory.createConfig(_defaultConfig()));

        assertEq(second, first, "identical params return the same config");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("ConfigCreated(address)"), "no ConfigCreated on a dedup hit");
        }
    }

    /// Different params get distinct configs, each recorded under its own hash.
    function testDifferentParamsGetDistinctConfigs() public {
        IAdaptiveCurveConfig.Params memory a = _defaultConfig();
        IAdaptiveCurveConfig.Params memory b = _defaultConfig();
        b.maxBorrowRate = 1; // any single-field difference changes the hash

        address configA = address(factory.createConfig(a));
        address configB = address(factory.createConfig(b));

        assertTrue(configA != configB, "distinct params -> distinct configs");
        assertEq(address(factory.configFor(_hash(a))), configA, "a recorded under its hash");
        assertEq(address(factory.configFor(_hash(b))), configB, "b recorded under its hash");
    }

    /// A config deployed directly (not via the factory) has no provenance: the hash slot is empty or points elsewhere.
    function testProvenanceRejectsDirectlyDeployedConfig() public {
        IAdaptiveCurveConfig.Params memory params = _defaultConfig();
        assertEq(address(factory.configFor(_hash(params))), address(0), "no config for unseen params");

        address canonical = address(factory.createConfig(params));
        address rogue = address(new AdaptiveCurveConfig(params)); // same params, deployed directly

        assertEq(address(factory.configFor(_hash(params))), canonical, "hash points at the factory's canonical config");
        assertTrue(rogue != canonical, "the directly-deployed config is not the canonical one");
    }

    /* HELPERS */

    function _hash(IAdaptiveCurveConfig.Params memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function _defaultConfig() internal pure returns (IAdaptiveCurveConfig.Params memory) {
        return IAdaptiveCurveConfig.Params({
            curveSteepness: ConstantsLib.CURVE_STEEPNESS,
            adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
            targetUtilization: ConstantsLib.TARGET_UTILIZATION,
            initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
            minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
            maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }
}
