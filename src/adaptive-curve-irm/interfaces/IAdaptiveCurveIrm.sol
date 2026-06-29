// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IMarketConfig} from "./IMarketConfig.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
    /// @notice Emitted when the config of a market is set.
    event ConfigSet(Id indexed id, address indexed config);

    /// @notice Address of Morpho.
    function MORPHO() external view returns (address);

    /// @notice Address allowed to set per-market configs (immutable; changed only by upgrading the implementation).
    function OWNER() external view returns (address);

    /// @notice The MarketConfig set for `id` (zero if none). The curve parameters are read from it through an
    /// external static call when computing the borrow rate.
    function marketConfig(Id id) external view returns (IMarketConfig);

    /// @notice Points market `id` at `config`. Owner only.
    function setConfig(Id id, IMarketConfig config) external;

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);
}
