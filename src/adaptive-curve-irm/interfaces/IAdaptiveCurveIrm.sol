// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IOwnerManager} from "../../common/IOwnerManager.sol";
import {IConfigurableIrm} from "../../common/IConfigurableIrm.sol";
import {IAdaptiveCurveConfig} from "./IAdaptiveCurveConfig.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface of the AdaptiveCurveIrm: per-market curve configs, the adapting `rateAtTarget`, and the `IIrm`
/// pricing surface.
interface IAdaptiveCurveIrm is IIrm, IOwnerManager, IConfigurableIrm {
    /// @notice The only address whose `borrowRate` calls are accepted: the IrmRouter in front of the IRM.
    function ROUTER() external view returns (address);

    /// @notice Rate at target utilization for market `id`.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);

    /// @notice The config contract set for market `id`. Zero if the market has no config.
    /// @dev The IRM reads this contract on every rate calculation. It must return valid parameters while selected.
    function marketCurveConfig(Id id) external view returns (IAdaptiveCurveConfig);
}
