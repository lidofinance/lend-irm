// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {AdaptiveCurveParams} from "./IAdaptiveCurveTypes.sol";

/// @title IAdaptiveCurveConfig
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by an AdaptiveCurveConfig: an immutable holder of one curve's parameters, deployed per
/// market by the AdaptiveCurveIrm and read by it through an external static call.
interface IAdaptiveCurveConfig {
    /// @notice `Params.curveSteepness`.
    function CURVE_STEEPNESS() external view returns (int256);

    /// @notice `Params.adjustmentSpeed`.
    function ADJUSTMENT_SPEED() external view returns (int256);

    /// @notice `Params.targetUtilization`.
    function TARGET_UTILIZATION() external view returns (int256);

    /// @notice `Params.initialRateAtTarget`.
    function INITIAL_RATE_AT_TARGET() external view returns (int256);

    /// @notice `Params.minRateAtTarget`.
    function MIN_RATE_AT_TARGET() external view returns (int256);

    /// @notice `Params.maxRateAtTarget`.
    function MAX_RATE_AT_TARGET() external view returns (int256);

    /// @notice `Params.maxBorrowRate`.
    function MAX_BORROW_RATE() external view returns (uint256);

    /// @notice Returns the full `Params` frozen into this contract's immutables.
    function getCurveParams() external view returns (AdaptiveCurveParams memory);
}
