// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {IAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";
import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./interfaces/IAdaptiveCurveTypes.sol";
import {AdaptiveCurveConfig} from "./AdaptiveCurveConfig.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ExpLib} from "./libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../lib/morpho-blue/src/libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
contract AdaptiveCurveIrm is IAdaptiveCurveIrm {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* IMMUTABLES */

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable MORPHO;

    /* STORAGE */

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => IAdaptiveCurveConfig) public marketCurveConfig;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(bytes32 => IAdaptiveCurveConfig) public deployedCurveConfigs;

    /// @inheritdoc IAdaptiveCurveIrm
    address public owner;

    /// @inheritdoc IAdaptiveCurveIrm
    address public manager;

    /// @inheritdoc IAdaptiveCurveIrm
    bool public isInitialized;

    /* CONSTRUCTOR & INITIALIZATION */

    /// @param morpho The address of Morpho.
    /// @dev Marks the implementation contract itself as initialized.
    constructor(address morpho) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);

        MORPHO = morpho;
        isInitialized = true;
    }

    /// @inheritdoc IAdaptiveCurveIrm
    function initialize(address owner_, address manager_) external {
        require(!isInitialized, ErrorsLib.ALREADY_INITIALIZED);

        isInitialized = true;
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    /* OWNERSHIP & MANAGEMENT */

    /// @inheritdoc IAdaptiveCurveIrm
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _transferOwnership(newOwner);
    }

    /// @inheritdoc IAdaptiveCurveIrm
    function setManager(address newManager) external {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _setManager(newManager);
    }

    /* CONFIG MANAGEMENT */

    /// @inheritdoc IAdaptiveCurveIrm
    function setMarketCurveParams(MarketParams memory marketParams, AdaptiveCurveParams calldata curveParams)
        external
    {
        require(msg.sender == owner || msg.sender == manager, ErrorsLib.NOT_AUTHORIZED);

        Id id = marketParams.id();
        bytes32 curveParamsHash = keccak256(abi.encode(curveParams));

        // Deduplicate: reuse the config already deployed for these exact params, otherwise deploy one (it validates
        // `curveParams` in its constructor) and cache it. Immutable configs are safely shareable across markets.
        IAdaptiveCurveConfig curveConfig = deployedCurveConfigs[curveParamsHash];
        if (address(curveConfig) == address(0)) {
            curveConfig = new AdaptiveCurveConfig(curveParams);
            deployedCurveConfigs[curveParamsHash] = curveConfig;
            emit ConfigDeployed(curveParamsHash, address(curveConfig));
        }

        marketCurveConfig[id] = curveConfig;
        emit MarketCurveParamsSet(id, address(curveConfig), curveParams);
    }

    /* BORROW RATES */

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender == MORPHO, ErrorsLib.NOT_MORPHO);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns avgRate and endRateAtTarget.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        IAdaptiveCurveConfig curveConfig = marketCurveConfig[id];
        require(address(curveConfig) != address(0), ErrorsLib.CONFIG_NOT_SET);
        AdaptiveCurveParams memory params = curveConfig.getCurveParams();

        // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor =
            utilization > params.targetUtilization ? WAD - params.targetUtilization : params.targetUtilization;
        int256 err = (utilization - params.targetUtilization).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = params.initialRateAtTarget;
            endRateAtTarget = params.initialRateAtTarget;
        } else {
            // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
            // So the rate is always underestimated.
            int256 speed = params.adjustmentSpeed.wMulToZero(err);
            // market.lastUpdate != 0 because it is not the first interaction with this market.
            // Safe "unchecked" cast because block.timestamp - market.lastUpdate <= block.timestamp <= type(int256).max.
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                // If linearAdaptation == 0, avgRateAtTarget = endRateAtTarget = startRateAtTarget;
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                // Formula of the average rate that should be returned to Morpho Blue:
                // avg = 1/T * ∫_0^T curve(startRateAtTarget*exp(speed*x), err) dx
                // The integral is approximated with the trapezoidal rule:
                // avg ~= 1/T * Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / 2 * T/N
                // Where f(x) = startRateAtTarget*exp(speed*x)
                // avg ~= Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / (2 * N)
                // As curve is linear in its first argument:
                // avg ~= curve([Σ_i=1^N [f((i-1) * T/N) + f(i * T/N)] / (2 * N), err)
                // avg ~= curve([(f(0) + f(T))/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // With N = 2:
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + startRateAtTarget*exp(speed*T/2)] / 2, err)
                // avg ~= curve([startRateAtTarget + endRateAtTarget + 2*startRateAtTarget*exp(speed*T/2)] / 4, err)
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation, params);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2, params);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        uint256 rate = uint256(_curve(avgRateAtTarget, err, params.curveSteepness));

        // Hard cap: clamp the charged rate to maxBorrowRate, leaving endRateAtTarget untouched. Adaptation is
        // err-driven, not rate-driven, so the state machine is unchanged and only the reported rate is bounded.
        if (params.maxBorrowRate != 0 && rate > params.maxBorrowRate) rate = params.maxBorrowRate;

        return (rate, endRateAtTarget);
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err, int256 curveSteepness) private pure returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
        return (coeff.wMulToZero(err) + WAD).wMulToZero(_rateAtTarget);
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation, AdaptiveCurveParams memory cfg)
        private
        pure
        returns (int256)
    {
        // Non negative because minRateAtTarget > 0.
        return
            startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(cfg.minRateAtTarget, cfg.maxRateAtTarget);
    }

    /// @dev Sets `owner` to `newOwner`, reverting on the zero address, and emits `OwnershipTransferred`.
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @dev Sets `manager` to `newManager`, reverting on the zero address, and emits `ManagerSet`.
    function _setManager(address newManager) internal {
        require(newManager != address(0), ErrorsLib.ZERO_ADDRESS);

        manager = newManager;
        emit ManagerSet(newManager);
    }
}
