// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @notice Curve parameters supplied to an AdaptiveCurveConfig constructor and frozen into its immutables.
struct AdaptiveCurveParams {
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
