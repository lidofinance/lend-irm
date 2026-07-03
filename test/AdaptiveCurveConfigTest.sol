// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdaptiveCurveConfig} from "../src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {IAdaptiveCurveConfig} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {ErrorsLib} from "../src/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {WAD_INT as WAD} from "../src/adaptive-curve-irm/libraries/MathLib.sol";
import {ConstantsLib} from "./ConstantsLib.sol";

import "../lib/forge-std/src/Test.sol";

contract AdaptiveCurveConfigTest is Test {
    /// The default (upstream-equivalent) config passes validation and deploys.
    function testDefaultConfigIsValid() public {
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(_defaultConfig());
        assertEq(config.getCurveParams().curveSteepness, ConstantsLib.CURVE_STEEPNESS, "default config deployed");
    }

    /// getCurveParams() round-trips every field frozen into the immutables.
    function testGetConfigRoundTrips() public {
        AdaptiveCurveParams memory config = _defaultConfig();
        config.maxBorrowRate = 0.5 ether / uint256(365 days);
        AdaptiveCurveParams memory roundTripped = new AdaptiveCurveConfig(config).getCurveParams();

        assertEq(roundTripped.curveSteepness, config.curveSteepness, "curveSteepness");
        assertEq(roundTripped.adjustmentSpeed, config.adjustmentSpeed, "adjustmentSpeed");
        assertEq(roundTripped.targetUtilization, config.targetUtilization, "targetUtilization");
        assertEq(roundTripped.initialRateAtTarget, config.initialRateAtTarget, "initialRateAtTarget");
        assertEq(roundTripped.minRateAtTarget, config.minRateAtTarget, "minRateAtTarget");
        assertEq(roundTripped.maxRateAtTarget, config.maxRateAtTarget, "maxRateAtTarget");
        assertEq(roundTripped.maxBorrowRate, config.maxBorrowRate, "maxBorrowRate");
    }

    /// The constructor rejects each parameter just outside both ends of its valid range.
    function testDeploymentRevertsOnInvalidParams() public {
        AdaptiveCurveParams memory config;

        config = _defaultConfig();
        config.curveSteepness = WAD - 1; // < 1e18
        _expectRevert(config, ErrorsLib.INVALID_CURVE_STEEPNESS);

        config = _defaultConfig();
        config.curveSteepness = int256(100 ether) + 1; // > 100 * WAD
        _expectRevert(config, ErrorsLib.INVALID_CURVE_STEEPNESS);

        config = _defaultConfig();
        config.adjustmentSpeed = -1; // < 0
        _expectRevert(config, ErrorsLib.INVALID_ADJUSTMENT_SPEED);

        config = _defaultConfig();
        config.adjustmentSpeed = int256(10_000 ether) / int256(365 days) + 1; // > limit
        _expectRevert(config, ErrorsLib.INVALID_ADJUSTMENT_SPEED);

        config = _defaultConfig();
        config.targetUtilization = 0; // <= 0
        _expectRevert(config, ErrorsLib.INVALID_TARGET_UTILIZATION);

        config = _defaultConfig();
        config.targetUtilization = WAD; // >= 1e18
        _expectRevert(config, ErrorsLib.INVALID_TARGET_UTILIZATION);

        config = _defaultConfig();
        config.minRateAtTarget = 0; // <= 0
        _expectRevert(config, ErrorsLib.INVALID_RATE_BOUNDS);

        config = _defaultConfig();
        config.maxRateAtTarget = config.minRateAtTarget - 1; // < min
        _expectRevert(config, ErrorsLib.INVALID_RATE_BOUNDS);

        config = _defaultConfig();
        config.maxRateAtTarget = int256(10_000 ether) / int256(365 days) + 1; // > limit
        _expectRevert(config, ErrorsLib.INVALID_RATE_BOUNDS);

        config = _defaultConfig();
        config.initialRateAtTarget = config.minRateAtTarget - 1; // < min
        _expectRevert(config, ErrorsLib.INVALID_INITIAL_RATE);

        config = _defaultConfig();
        config.initialRateAtTarget = config.maxRateAtTarget + 1; // > max
        _expectRevert(config, ErrorsLib.INVALID_INITIAL_RATE);

        config = _defaultConfig();
        config.maxBorrowRate = _maxBorrowRateLimit() + 1; // above the curve's maximum possible output
        _expectRevert(config, ErrorsLib.INVALID_MAX_BORROW_RATE);
    }

    /// The cap's boundary: the largest value the curve can ever output deploys; `0` stays the explicit "disabled".
    function testMaxBorrowRateBoundary() public {
        AdaptiveCurveParams memory config = _defaultConfig();
        config.maxBorrowRate = _maxBorrowRateLimit();
        assertEq(new AdaptiveCurveConfig(config).MAX_BORROW_RATE(), config.maxBorrowRate, "limit itself deploys");

        config.maxBorrowRate = 0;
        assertEq(new AdaptiveCurveConfig(config).MAX_BORROW_RATE(), 0, "zero (disabled) deploys");
    }

    /* HELPERS */

    /// @dev Mirrors the contract's `MAX_BORROW_RATE_LIMIT`: max rate-at-target times max steepness.
    function _maxBorrowRateLimit() internal pure returns (uint256) {
        return uint256(10_000 ether / int256(365 days)) * 100;
    }

    function _defaultConfig() internal pure returns (AdaptiveCurveParams memory) {
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

    function _expectRevert(AdaptiveCurveParams memory config, string memory expectedError) internal {
        vm.expectRevert(bytes(expectedError));
        new AdaptiveCurveConfig(config);
    }
}
