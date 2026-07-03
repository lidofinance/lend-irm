// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./interfaces/IAdaptiveCurveTypes.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {WAD_INT as WAD} from "./libraries/MathLib.sol";

/// @title AdaptiveCurveConfig
/// @author Lido.
/// @notice Immutable holder of one curve's parameters. The factory deploys one per market and the AdaptiveCurveIrm
/// reads it through an external static call (`getCurveParams()`). Parameters are validated at construction and frozen.
contract AdaptiveCurveConfig is IAdaptiveCurveConfig {
    /* IMMUTABLES */

    int256 public immutable CURVE_STEEPNESS;
    int256 public immutable ADJUSTMENT_SPEED;
    int256 public immutable TARGET_UTILIZATION;
    int256 public immutable INITIAL_RATE_AT_TARGET;
    int256 public immutable MIN_RATE_AT_TARGET;
    int256 public immutable MAX_RATE_AT_TARGET;
    uint256 public immutable MAX_BORROW_RATE;

    /* CONSTANTS */

    /// @dev Maximum curve steepness = 100 (WAD-scaled ratio).
    int256 private constant MAX_CURVE_STEEPNESS = 100 ether;

    /// @dev Maximum adjustment speed = 10000/year (WAD-scaled, per second).
    int256 private constant MAX_ADJUSTMENT_SPEED = 10_000 ether / int256(365 days);

    /// @dev Maximum rate at target = 10000/year = 1000000%/year (WAD-scaled, per second).
    int256 private constant MAX_RATE_AT_TARGET_LIMIT = 10_000 ether / int256(365 days);

    /* CONSTRUCTOR */

    /// @notice Validates `cfg` and freezes it into immutables.
    constructor(AdaptiveCurveParams memory cfg) {
        _validateConfig(cfg);

        CURVE_STEEPNESS = cfg.curveSteepness;
        ADJUSTMENT_SPEED = cfg.adjustmentSpeed;
        TARGET_UTILIZATION = cfg.targetUtilization;
        INITIAL_RATE_AT_TARGET = cfg.initialRateAtTarget;
        MIN_RATE_AT_TARGET = cfg.minRateAtTarget;
        MAX_RATE_AT_TARGET = cfg.maxRateAtTarget;
        MAX_BORROW_RATE = cfg.maxBorrowRate;
    }

    /// @dev Reverts unless `cfg` is a valid curve configuration, with a per-parameter error message. The bounds
    /// (upper limits included) keep the curve math inside its non-overflowing range, so `borrowRate` returns a
    /// non-negative rate without reverting. They enforce well-formedness only, not economic soundness.
    function _validateConfig(AdaptiveCurveParams memory cfg) private pure {
        require(cfg.curveSteepness >= WAD, ErrorsLib.INVALID_CURVE_STEEPNESS);
        require(cfg.curveSteepness <= MAX_CURVE_STEEPNESS, ErrorsLib.INVALID_CURVE_STEEPNESS);

        require(cfg.adjustmentSpeed >= 0, ErrorsLib.INVALID_ADJUSTMENT_SPEED);
        require(cfg.adjustmentSpeed <= MAX_ADJUSTMENT_SPEED, ErrorsLib.INVALID_ADJUSTMENT_SPEED);

        require(cfg.targetUtilization > 0, ErrorsLib.INVALID_TARGET_UTILIZATION);
        require(cfg.targetUtilization < WAD, ErrorsLib.INVALID_TARGET_UTILIZATION);

        require(cfg.minRateAtTarget > 0, ErrorsLib.INVALID_RATE_BOUNDS);
        require(cfg.maxRateAtTarget >= cfg.minRateAtTarget, ErrorsLib.INVALID_RATE_BOUNDS);
        require(cfg.maxRateAtTarget <= MAX_RATE_AT_TARGET_LIMIT, ErrorsLib.INVALID_RATE_BOUNDS);

        require(cfg.initialRateAtTarget >= cfg.minRateAtTarget, ErrorsLib.INVALID_INITIAL_RATE);
        require(cfg.initialRateAtTarget <= cfg.maxRateAtTarget, ErrorsLib.INVALID_INITIAL_RATE);
    }

    /// @inheritdoc IAdaptiveCurveConfig
    function getCurveParams() external view returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: CURVE_STEEPNESS,
            adjustmentSpeed: ADJUSTMENT_SPEED,
            targetUtilization: TARGET_UTILIZATION,
            initialRateAtTarget: INITIAL_RATE_AT_TARGET,
            minRateAtTarget: MIN_RATE_AT_TARGET,
            maxRateAtTarget: MAX_RATE_AT_TARGET,
            maxBorrowRate: MAX_BORROW_RATE
        });
    }
}
