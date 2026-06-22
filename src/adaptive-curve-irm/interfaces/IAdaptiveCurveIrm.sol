// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
    /// @notice Curve parameters supplied to the constructor and frozen into immutables.
    struct Config {
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

    /// @notice Address of Morpho.
    function MORPHO() external view returns (address);

    /// @notice Curve steepness (scaled by WAD).
    function CURVE_STEEPNESS() external view returns (int256);

    /// @notice Adjustment speed per second (scaled by WAD).
    function ADJUSTMENT_SPEED() external view returns (int256);

    /// @notice Target utilization (scaled by WAD).
    function TARGET_UTILIZATION() external view returns (int256);

    /// @notice Initial rate at target per second (scaled by WAD).
    function INITIAL_RATE_AT_TARGET() external view returns (int256);

    /// @notice Minimum rate at target per second (scaled by WAD).
    function MIN_RATE_AT_TARGET() external view returns (int256);

    /// @notice Maximum rate at target per second (scaled by WAD).
    function MAX_RATE_AT_TARGET() external view returns (int256);

    /// @notice Hard ceiling on the charged borrow rate per second (scaled by WAD); 0 disables it.
    function MAX_BORROW_RATE() external view returns (uint256);

    /// @notice Returns the full `Config` of this implementation in a single call (convenience for integrators).
    function getConfig() external view returns (Config memory);

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);
}
