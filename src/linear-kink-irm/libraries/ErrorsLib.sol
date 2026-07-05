// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author Lido.
/// @notice Library exposing error messages for the linear-kink IRM. Role/init errors live in OwnerManagerBase.
library ErrorsLib {
    /// @dev Thrown when a borrow rate is requested for a market that has no params set.
    string internal constant CONFIG_NOT_SET = "config not set";

    /// @dev Thrown when `optimalUtilization` is outside (0, WAD).
    string internal constant INVALID_OPTIMAL_UTILIZATION = "invalid optimalUtilization";

    /// @dev Thrown when the peak rate (baseRate + slope1 + slope2) exceeds MAX_BORROW_RATE.
    string internal constant MAX_RATE_EXCEEDED = "max rate exceeded";
}
