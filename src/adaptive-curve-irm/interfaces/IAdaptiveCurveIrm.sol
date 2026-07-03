// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id, MarketParams} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
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

    /// @notice Whether the contract has been initialized. Set to true on the implementation at construction (locking
    /// it) and on the proxy by `initialize`.
    function isInitialized() external view returns (bool);

    /// @notice The AdaptiveCurveConfig set for market `id` (zero if none). The curve parameters are read from it
    /// through an external static call when computing the borrow rate.
    function marketCurveConfig(Id id) external view returns (IAdaptiveCurveConfig);

    /// @notice The AdaptiveCurveConfig deployed for `paramsHash = keccak256(abi.encode(Params))`, or zero if none.
    /// @dev Deduplication cache: identical params resolve to one shared config across markets.
    function deployedCurveConfigs(bytes32 paramsHash) external view returns (IAdaptiveCurveConfig);

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);

    /// @notice Sets `owner` and `manager` once; reverts if already initialized or either address is zero. Must run
    /// atomically with proxy deployment.
    function initialize(address owner_, address manager_) external;

    /// @notice Sets `owner` to `newOwner`. Owner only; reverts on zero.
    function transferOwnership(address newOwner) external;

    /// @notice Sets `manager` to `newManager`. Owner only; reverts on zero.
    function setManager(address newManager) external;

    /// @notice Deploys (or reuses, by params hash) an AdaptiveCurveConfig from `curveParams` and sets it as the
    /// config for market `id = marketParams.id()`. Owner or manager only.
    function setMarketCurveParams(MarketParams memory marketParams, AdaptiveCurveParams calldata curveParams)
        external;
}
