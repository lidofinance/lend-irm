// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id, MarketParams} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IOwnerManager} from "../../common/IOwnerManager.sol";
import {IAdaptiveCurveConfig} from "./IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./IAdaptiveCurveTypes.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface of the AdaptiveCurveIrm: per-market curve configs, the adapting `rateAtTarget`, and the `IIrm`
/// pricing surface.
interface IAdaptiveCurveIrm is IIrm, IOwnerManager {
    /// @notice Emitted when an AdaptiveCurveConfig is deployed for a new `paramsHash` (skipped on a dedup hit).
    event ConfigDeployed(bytes32 indexed paramsHash, address indexed config);

    /// @notice Emitted when market `id` is pointed at the config holding `curveParams`.
    event MarketCurveParamsSet(Id indexed id, address indexed config, AdaptiveCurveParams curveParams);

    /// @notice The only address whose `borrowRate` calls are accepted: the IrmRouter in front of the IRM.
    function ROUTER() external view returns (address);

    /// @notice Rate at target utilization for market `id`.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);

    /// @notice The AdaptiveCurveConfig set for market `id`. Zero if the market has no config. The borrow rate is
    /// computed from whichever config is currently set.
    function marketCurveConfig(Id id) external view returns (IAdaptiveCurveConfig);

    /// @notice The AdaptiveCurveConfig deployed for `paramsHash = keccak256(abi.encode(AdaptiveCurveParams))`, or zero.
    /// @dev Deduplication cache: identical params resolve to one shared config across markets.
    function deployedCurveConfigs(bytes32 paramsHash) external view returns (IAdaptiveCurveConfig);

    /// @notice Deploys (or reuses, by params hash) an AdaptiveCurveConfig from `curveParams` and sets it as the config
    /// for market `id = marketParams.id()`. Owner or manager only.
    function setMarketCurveParams(MarketParams memory marketParams, AdaptiveCurveParams calldata curveParams) external;
}
