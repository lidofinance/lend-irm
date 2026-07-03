// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @notice Curve parameters held by an AdaptiveCurveConfig, validated at its construction. Rates and speeds are
/// WAD-scaled per-second values; ratios and utilizations are WAD-scaled fractions.
struct AdaptiveCurveParams {
    /// Curve slope: the rate at full utilization is `curveSteepness`x the rate at target.
    int256 curveSteepness;
    /// Speed at which `rateAtTarget` adapts toward closing the utilization error; 0 freezes adaptation.
    int256 adjustmentSpeed;
    /// Utilization the curve steers toward, as a fraction of total supply.
    int256 targetUtilization;
    /// Rate at target a fresh market starts from, before any adaptation.
    int256 initialRateAtTarget;
    /// Lower clamp on the adapting `rateAtTarget`. Positive (a stored rate of 0 marks an uninitialized market).
    int256 minRateAtTarget;
    /// Upper clamp on the adapting `rateAtTarget`.
    int256 maxRateAtTarget;
    /// Optional hard ceiling on the charged borrow rate, applied to the curve output only (never to
    /// `rateAtTarget`); 0 disables it.
    uint256 maxBorrowRate;
}
