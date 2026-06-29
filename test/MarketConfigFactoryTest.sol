// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketConfig} from "../src/adaptive-curve-irm/MarketConfig.sol";
import {MarketConfigFactory} from "../src/adaptive-curve-irm/MarketConfigFactory.sol";
import {IMarketConfig} from "../src/adaptive-curve-irm/interfaces/IMarketConfig.sol";
import {ConstantsLib} from "./ConstantsLib.sol";

import "../lib/forge-std/src/Test.sol";

contract MarketConfigFactoryTest is Test {
    event ConfigCreated(address indexed config);

    MarketConfigFactory internal factory;

    function setUp() public {
        factory = new MarketConfigFactory();
    }

    /// createConfig is permissionless: any caller can deploy a config, and it is recorded as a valid deployment.
    function testCreateConfigIsPermissionless(address caller) public {
        vm.prank(caller);
        address config = address(factory.createConfig(_defaultConfig()));

        assertTrue(factory.isValidDeployment(config), "config recorded as a valid deployment");
        assertEq(IMarketConfig(config).getConfig().curveSteepness, ConstantsLib.CURVE_STEEPNESS, "config round-trips");
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

    /// A config deployed directly (not via the factory) has no provenance.
    function testIsValidDeploymentFalseForUnknown() public {
        address rogue = address(new MarketConfig(_defaultConfig()));
        assertFalse(factory.isValidDeployment(rogue), "directly-deployed config is not a factory deployment");
        assertFalse(factory.isValidDeployment(address(0)), "zero address is not a valid deployment");
    }

    /* HELPERS */

    function _defaultConfig() internal pure returns (IMarketConfig.Config memory) {
        return IMarketConfig.Config({
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
