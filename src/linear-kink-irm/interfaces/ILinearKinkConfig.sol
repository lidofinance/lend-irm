// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {LinearKinkParams} from "./ILinearKinkTypes.sol";

/// @title ILinearKinkConfig
/// @author Lido.
/// @notice Interface exposed by a LinearKinkConfig: an immutable holder of one kink curve's parameters.
interface ILinearKinkConfig {
    /// @notice `LinearKinkParams.optimalUtilization`.
    function OPTIMAL_UTILIZATION() external view returns (uint64);

    /// @notice `LinearKinkParams.baseRate`.
    function BASE_RATE() external view returns (uint64);

    /// @notice `LinearKinkParams.slope1`.
    function SLOPE1() external view returns (uint64);

    /// @notice `LinearKinkParams.slope2`.
    function SLOPE2() external view returns (uint64);

    /// @notice The full `LinearKinkParams` held by this config.
    function getKinkParams() external view returns (LinearKinkParams memory);
}
