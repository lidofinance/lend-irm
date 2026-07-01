// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {IAdaptiveCurveConfigFactory} from "./interfaces/IAdaptiveCurveConfigFactory.sol";

import {AdaptiveCurveConfig} from "./AdaptiveCurveConfig.sol";

/// @title AdaptiveCurveConfigFactory
/// @author Morpho Labs. Modified by Lido.
/// @notice Permissionless deployer of immutable AdaptiveCurveConfigs, deduplicated by curve parameters: one canonical
/// config per distinct `Params`. `configFor[keccak256(abi.encode(params))]` is that canonical config (zero if none).
/// The record is for off-chain/periphery provenance; the IRM does not consume it. Deploying a config carries no
/// authority (it is an inert, validated data holder); activating it for a market is gated on the IRM (`setConfig`,
/// owner-only).
contract AdaptiveCurveConfigFactory is IAdaptiveCurveConfigFactory {
    /// @inheritdoc IAdaptiveCurveConfigFactory
    mapping(bytes32 => IAdaptiveCurveConfig) public configFor;

    /// @inheritdoc IAdaptiveCurveConfigFactory
    function createConfig(IAdaptiveCurveConfig.Params calldata cfg) external returns (IAdaptiveCurveConfig) {
        bytes32 paramsHash = keccak256(abi.encode(cfg));

        IAdaptiveCurveConfig existing = configFor[paramsHash];
        if (address(existing) != address(0)) return existing;

        AdaptiveCurveConfig config = new AdaptiveCurveConfig(cfg);
        configFor[paramsHash] = config;

        emit ConfigCreated(address(config));
        return config;
    }
}
