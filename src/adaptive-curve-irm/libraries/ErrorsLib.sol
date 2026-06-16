// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library exposing error messages.
library ErrorsLib {
    /// @dev Thrown when passing the zero address.
    string internal constant ZERO_ADDRESS = "zero address";

    /// @dev Thrown when the caller is not Morpho.
    string internal constant NOT_MORPHO = "not Morpho";

    /// @dev Thrown when `curveSteepness` is below WAD.
    string internal constant INVALID_CURVE_STEEPNESS = "invalid curveSteepness";

    /// @dev Thrown when `adjustmentSpeed` is negative.
    string internal constant INVALID_ADJUSTMENT_SPEED = "invalid adjustmentSpeed";

    /// @dev Thrown when `targetUtilization` is outside (0, WAD).
    string internal constant INVALID_TARGET_UTILIZATION = "invalid targetUtilization";

    /// @dev Thrown when the rate-at-target bounds are invalid (minRateAtTarget <= 0 or maxRateAtTarget < min).
    string internal constant INVALID_RATE_BOUNDS = "invalid rate bounds";

    /// @dev Thrown when `initialRateAtTarget` is outside [minRateAtTarget, maxRateAtTarget].
    string internal constant INVALID_INITIAL_RATE = "invalid initialRateAtTarget";

    /// @dev Thrown when `maxBorrowRate` is negative.
    string internal constant INVALID_MAX_BORROW_RATE = "invalid maxBorrowRate";
}
