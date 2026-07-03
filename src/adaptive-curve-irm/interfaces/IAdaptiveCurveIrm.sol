// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveConfig} from "./IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./IAdaptiveCurveTypes.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
    /// @notice Emitted when `owner` is set or transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when `manager` is set.
    event ManagerSet(address indexed manager);

    /// @notice Emitted when an AdaptiveCurveConfig is deployed for a new `paramsHash` (skipped on a dedup hit).
    event ConfigDeployed(bytes32 indexed paramsHash, address indexed config);

    /// @notice Emitted when market `id` is pointed at the config holding `curveParams`.
    event MarketCurveParamsSet(Id indexed id, address indexed config, AdaptiveCurveParams curveParams);

    /// @notice Address of Morpho.
    function MORPHO() external view returns (address);

    /// @notice Address allowed to manage roles (`transferOwnership`, `setManager`) and set market curve params.
    function owner() external view returns (address);

    /// @notice Address allowed to set market curve params (alongside `owner`).
    function manager() external view returns (address);

    /// @notice Whether the contract has been initialized.
    function isInitialized() external view returns (bool);

    /// @notice The AdaptiveCurveConfig set for market `id`. Zero if the market has no config. The borrow rate is
    /// computed from whichever config is currently set.
    function marketCurveConfig(Id id) external view returns (IAdaptiveCurveConfig);

    /// @notice The AdaptiveCurveConfig deployed for `paramsHash = keccak256(abi.encode(curveParams))`. Zero if none
    /// has been deployed.
    /// @dev Deduplication cache: identical params resolve to one shared config across markets.
    function deployedCurveConfigs(bytes32 paramsHash) external view returns (IAdaptiveCurveConfig);

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);

    /// @notice Initializes the contract, setting `newOwner` as `owner` and `newManager` as `manager`.
    /// @dev Warning: Deploy the proxy and initialize it atomically (e.g. via constructor calldata), or anyone can
    /// claim ownership by initializing first.
    function initialize(address newOwner, address newManager) external;

    /// @notice Sets `newOwner` as `owner` of the contract. Can only be called by the owner.
    /// @dev Warning: No two-step process, so the owner can leave the contract in the hands of a malicious address.
    /// The owner cannot be renounced (the zero address is rejected).
    function transferOwnership(address newOwner) external;

    /// @notice Sets `newManager` as `manager` of the contract. Can only be called by the owner.
    function setManager(address newManager) external;

    /// @notice Deploys (or reuses, by params hash) an AdaptiveCurveConfig from `curveParams` and sets it as the
    /// config for market `id = marketParams.id()`. Can only be called by the owner or the manager.
    function setMarketCurveParams(MarketParams memory marketParams, AdaptiveCurveParams calldata curveParams) external;
}
