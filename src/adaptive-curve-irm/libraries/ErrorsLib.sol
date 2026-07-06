// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author Morpho Labs. Modified by Lido.
/// @notice Library exposing error messages.
library ErrorsLib {
    /// @dev Thrown when the caller is not the router.
    string internal constant NOT_ROUTER = "not router";

    /// @dev Thrown when a borrow rate is requested for a market that has no config set.
    string internal constant CONFIG_NOT_SET = "config not set";

    /// @dev Thrown when `curveSteepness` is outside [WAD, 100 * WAD].
    string internal constant INVALID_CURVE_STEEPNESS = "invalid curveSteepness";

    /// @dev Thrown when `adjustmentSpeed` is negative or above its upper limit.
    string internal constant INVALID_ADJUSTMENT_SPEED = "invalid adjustmentSpeed";

    /// @dev Thrown when `targetUtilization` is outside (0, WAD).
    string internal constant INVALID_TARGET_UTILIZATION = "invalid targetUtilization";

    /// @dev Thrown unless 0 < minRateAtTarget <= maxRateAtTarget <= upper limit.
    string internal constant INVALID_RATE_BOUNDS = "invalid rate bounds";

    /// @dev Thrown when a non-zero `maxBorrowRate` exceeds the curve's maximum possible output.
    string internal constant INVALID_MAX_BORROW_RATE = "invalid maxBorrowRate";

    /// @dev Thrown when `initialRateAtTarget` is outside [minRateAtTarget, maxRateAtTarget].
    string internal constant INVALID_INITIAL_RATE = "invalid initialRateAtTarget";
}
