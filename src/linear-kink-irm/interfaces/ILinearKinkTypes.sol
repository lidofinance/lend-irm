// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @author Lido.
/// @notice Linear-kink ("jump rate") curve parameters for one market. All four fields pack into a single storage slot
/// (4 x uint64 = 256 bits). Rates are per-second and WAD-scaled.
/// @param optimalUtilization Utilization at which the slope steepens (the kink), as a WAD fraction. Range (0, WAD).
/// `0` marks an unset market.
/// @param baseRate Rate at zero utilization (the curve's intercept).
/// @param slope1 Rate added linearly from zero utilization up to `optimalUtilization`, contributing exactly `slope1`
/// at the kink.
/// @param slope2 Rate added linearly from `optimalUtilization` up to full utilization, contributing exactly `slope2`
/// at U = WAD.
struct LinearKinkParams {
    uint64 optimalUtilization;
    uint64 baseRate;
    uint64 slope1;
    uint64 slope2;
}
