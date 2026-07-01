// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IAdaptiveCurveConfig} from "./IAdaptiveCurveConfig.sol";

/// @title IAdaptiveCurveConfigFactory
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the AdaptiveCurveConfigFactory: a permissionless deployer of immutable
/// AdaptiveCurveConfigs, deduplicated by curve parameters. The provenance record it keeps is for off-chain/periphery
/// verification; the IRM does not consume it.
interface IAdaptiveCurveConfigFactory {
    /// @notice Emitted when a config is deployed (not on a dedup hit).
    event ConfigCreated(address indexed config);

    /// @notice The canonical config for `paramsHash` = keccak256(abi.encode(Params)), or zero if none was deployed.
    /// @dev Provenance check for a config `c`: `configFor(keccak256(abi.encode(c.getCurveParams()))) == c`.
    function configFor(bytes32 paramsHash) external view returns (IAdaptiveCurveConfig);

    /// @notice Deploys an immutable AdaptiveCurveConfig from `cfg` (validated in its constructor), or returns the
    /// existing one if identical params were already deployed.
    /// @dev Permissionless and deduplicated by keccak256(abi.encode(cfg)); deploying a config grants no power, only
    /// pointing a market at one (gated elsewhere) does.
    function createConfig(IAdaptiveCurveConfig.Params calldata cfg) external returns (IAdaptiveCurveConfig);
}
