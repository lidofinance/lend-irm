// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
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
    function MAX_BORROW_RATE() external view returns (int256);

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);
}
