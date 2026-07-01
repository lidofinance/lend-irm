// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @title IAdaptiveCurveConfig
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by an AdaptiveCurveConfig: an immutable holder of one curve's parameters, deployed per
/// market by the factory and read by the AdaptiveCurveIrm through an external static call.
interface IAdaptiveCurveConfig {
    /// @notice Curve parameters supplied to the constructor and frozen into immutables.
    struct Params {
        /// Curve slope: the rate at full utilization is `curveSteepness`x the rate at target. Range [WAD, 100*WAD].
        int256 curveSteepness;
        /// Speed at which `rateAtTarget` adapts toward closing the utilization error. Range [0, ~10000/year]; 0 freezes
        /// adaptation.
        int256 adjustmentSpeed;
        /// Utilization the curve steers toward, as a fraction of total supply. Range (0, WAD).
        int256 targetUtilization;
        /// Rate at target a fresh market starts from, before any adaptation. Range [minRateAtTarget, maxRateAtTarget].
        int256 initialRateAtTarget;
        /// Lower clamp on the adapting `rateAtTarget`. Must be > 0 (0 marks an uninitialized market).
        int256 minRateAtTarget;
        /// Upper clamp on the adapting `rateAtTarget`. Range [minRateAtTarget, ~1e6%/year].
        int256 maxRateAtTarget;
        /// Optional hard ceiling on the charged borrow rate, applied to the curve output only (never to
        /// `rateAtTarget`); 0 disables it.
        uint256 maxBorrowRate;
    }

    /// @notice Returns the full `Params` frozen into this contract's immutables.
    function getCurveParams() external view returns (Params memory);

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
}
