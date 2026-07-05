// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @author Lido.
/// @notice Curve parameters held by an AdaptiveCurveConfig, validated at its construction. Rates and speeds are
/// WAD-scaled per-second values; ratios and utilizations are WAD-scaled fractions.
/// @param curveSteepness Curve slope: the rate at full utilization is `curveSteepness`x the rate at target.
/// @param adjustmentSpeed Speed at which `rateAtTarget` adapts toward closing the utilization error. 0 freezes
/// adaptation.
/// @param targetUtilization Utilization the curve steers toward, as a fraction of total supply.
/// @param initialRateAtTarget Rate at target a fresh market starts from, before any adaptation.
/// @param minRateAtTarget Lower clamp on the adapting `rateAtTarget`. Positive (a stored rate of 0 marks an
/// uninitialized market).
/// @param maxRateAtTarget Upper clamp on the adapting `rateAtTarget`.
/// @param maxBorrowRate Optional hard ceiling on the charged borrow rate, applied to the curve output only (never to
/// `rateAtTarget`). 0 disables it.
struct AdaptiveCurveParams {
    int256 curveSteepness;
    int256 adjustmentSpeed;
    int256 targetUtilization;
    int256 initialRateAtTarget;
    int256 minRateAtTarget;
    int256 maxRateAtTarget;
    uint256 maxBorrowRate;
}
