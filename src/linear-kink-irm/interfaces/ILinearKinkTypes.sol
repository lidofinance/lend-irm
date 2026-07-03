// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @notice Linear-kink ("jump rate") curve parameters for one market. All four fields pack into a single storage slot
/// (4 x uint64 = 256 bits). Rates are per-second and WAD-scaled. `uint64` holds them with no loss of precision because
/// every value stays below the model's caps (rates <= MAX_BORROW_RATE ~ 2.5e11, utilization <= WAD = 1e18).
struct LinearKinkParams {
    /// Utilization at which the slope steepens (the kink), as a WAD fraction. Range (0, WAD). `0` marks an unset
    /// market.
    uint64 optimalUtilization;
    /// Rate at zero utilization (the curve's intercept). Range [0, MAX_BORROW_RATE].
    uint64 baseRate;
    /// Rate added linearly from zero utilization up to `optimalUtilization`, contributing exactly `slope1` at the kink.
    uint64 slope1;
    /// Rate added linearly from `optimalUtilization` up to full utilization, contributing exactly `slope2` at U = WAD.
    uint64 slope2;
}
