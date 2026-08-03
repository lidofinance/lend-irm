// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {AdaptiveCurveParams} from "../../adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkParams} from "../../linear-kink-irm/interfaces/ILinearKinkTypes.sol";

/// @title IIrmConfigFactory
/// @author Lido.
/// @notice Permissionless factory surface for the included IRM config contracts.
interface IIrmConfigFactory {
    /// @notice Emitted when a new AdaptiveCurveConfig is deployed for `paramsHash`.
    event AdaptiveCurveConfigDeployed(bytes32 indexed paramsHash, address indexed config);

    /// @notice Emitted when a new LinearKinkConfig is deployed for `paramsHash`.
    event LinearKinkConfigDeployed(bytes32 indexed paramsHash, address indexed config);

    /// @notice Returns the AdaptiveCurveConfig deployed for `params`, or zero if none.
    function getAdaptiveCurveConfig(AdaptiveCurveParams calldata params) external view returns (address config);

    /// @notice Returns the LinearKinkConfig deployed for `params`, or zero if none.
    function getLinearKinkConfig(LinearKinkParams calldata params) external view returns (address config);

    /// @notice Returns the existing AdaptiveCurveConfig for `params`, or deploys one if absent.
    function getOrDeployAdaptiveCurveConfig(AdaptiveCurveParams calldata params) external returns (address config);

    /// @notice Returns the existing LinearKinkConfig for `params`, or deploys one if absent.
    function getOrDeployLinearKinkConfig(LinearKinkParams calldata params) external returns (address config);
}
