// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {AdaptiveCurveParams} from "./IAdaptiveCurveTypes.sol";

/// @title IAdaptiveCurveConfig
/// @author Lido.
/// @notice Interface exposed by an AdaptiveCurveConfig: an immutable holder of one curve's parameters.
interface IAdaptiveCurveConfig {
    /// @notice `AdaptiveCurveParams.curveSteepness`.
    function CURVE_STEEPNESS() external view returns (int256);

    /// @notice `AdaptiveCurveParams.adjustmentSpeed`.
    function ADJUSTMENT_SPEED() external view returns (int256);

    /// @notice `AdaptiveCurveParams.targetUtilization`.
    function TARGET_UTILIZATION() external view returns (int256);

    /// @notice `AdaptiveCurveParams.initialRateAtTarget`.
    function INITIAL_RATE_AT_TARGET() external view returns (int256);

    /// @notice `AdaptiveCurveParams.minRateAtTarget`.
    function MIN_RATE_AT_TARGET() external view returns (int256);

    /// @notice `AdaptiveCurveParams.maxRateAtTarget`.
    function MAX_RATE_AT_TARGET() external view returns (int256);

    /// @notice `AdaptiveCurveParams.maxBorrowRate`.
    function MAX_BORROW_RATE() external view returns (uint256);

    /// @notice The full `AdaptiveCurveParams` held by this config.
    function getCurveParams() external view returns (AdaptiveCurveParams memory);
}
