// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IMarketConfig} from "./interfaces/IMarketConfig.sol";
import {IMarketConfigFactory} from "./interfaces/IMarketConfigFactory.sol";

import {MarketConfig} from "./MarketConfig.sol";

/// @title MarketConfigFactory
/// @author Morpho Labs. Modified by Lido.
/// @notice Permissionless deployer of immutable MarketConfigs. Deploying a config carries no authority (the config
/// is an inert, validated data holder); the factory only records provenance so the IRM can require that any config a
/// market points to originated here. Activating a config for a market is gated on the IRM (`setConfig`, owner-only).
contract MarketConfigFactory is IMarketConfigFactory {
    /// @inheritdoc IMarketConfigFactory
    mapping(address => bool) public isValidDeployment;

    /// @inheritdoc IMarketConfigFactory
    function createConfig(IMarketConfig.Config calldata cfg) external returns (IMarketConfig) {
        MarketConfig config = new MarketConfig(cfg);
        isValidDeployment[address(config)] = true;

        emit ConfigCreated(address(config));
        return config;
    }
}
