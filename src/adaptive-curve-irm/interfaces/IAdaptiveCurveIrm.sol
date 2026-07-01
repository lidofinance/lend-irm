// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveConfig} from "./IAdaptiveCurveConfig.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
    /// @notice Emitted when the config of a market is set.
    event ConfigSet(Id indexed id, address indexed config);

    /// @notice Emitted when `owner` is set or transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Address of Morpho.
    function MORPHO() external view returns (address);

    /// @notice Address allowed to set per-market configs.
    function owner() external view returns (address);

    /// @notice Sets `owner` once; reverts if already set or zero. Must run atomically with proxy deployment.
    function initialize(address initialOwner) external;

    /// @notice Sets `owner` to `newOwner`. Owner only; reverts on zero.
    function transferOwnership(address newOwner) external;

    /// @notice The AdaptiveCurveConfig set for `id` (zero if none). The curve parameters are read from it through an
    /// external static call when computing the borrow rate.
    function config(Id id) external view returns (IAdaptiveCurveConfig);

    /// @notice Sets the config for market `id` to `newConfig`. Owner only.
    function setConfig(Id id, IAdaptiveCurveConfig newConfig) external;

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);
}
