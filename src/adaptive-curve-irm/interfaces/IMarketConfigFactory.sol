// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IMarketConfig} from "./IMarketConfig.sol";

/// @title IMarketConfigFactory
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the MarketConfigFactory: a permissionless deployer of immutable MarketConfigs that
/// records the provenance of every config it creates, so a consumer can require a config it points to was produced
/// here (and therefore passed validation).
interface IMarketConfigFactory {
    /// @notice Emitted when a config is deployed.
    event ConfigCreated(address indexed config);

    /// @notice Whether `config` was deployed by this factory.
    function isValidDeployment(address config) external view returns (bool);

    /// @notice Deploys an immutable MarketConfig from `cfg` (validated in its constructor) and records its provenance.
    /// @dev Permissionless: deploying a config grants no power; only pointing a market at one (gated elsewhere) does.
    /// The provenance record (`isValidDeployment`) is for off-chain/periphery verification; the IRM does not consume
    /// it.
    function createConfig(IMarketConfig.Config calldata cfg) external returns (IMarketConfig);
}
