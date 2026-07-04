// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {IAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";
import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./interfaces/IAdaptiveCurveTypes.sol";
import {AdaptiveCurveConfig} from "./AdaptiveCurveConfig.sol";
import {OwnerManagerBase} from "../common/OwnerManagerBase.sol";
import {OwnerManagerErrors} from "../common/OwnerManagerErrors.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ExpLib} from "./libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../lib/morpho-blue/src/libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice One immutable instance serves many markets keyed by `Id`: each market points at an immutable
/// AdaptiveCurveConfig (deployed and deduplicated here) and keeps its own adapting `rateAtTarget`. The curve and its
/// adaptation are byte-identical to upstream. Meant to sit behind IrmRouter.
contract AdaptiveCurveIrm is IAdaptiveCurveIrm, OwnerManagerBase {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable ROUTER;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => IAdaptiveCurveConfig) public marketCurveConfig;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(bytes32 => IAdaptiveCurveConfig) public deployedCurveConfigs;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param router The IrmRouter in front of this contract, the only caller `borrowRate` accepts.
    constructor(address router, address owner_, address manager_) {
        require(router != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        ROUTER = router;
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    // ---
    // CONFIG MANAGEMENT
    // ---

    /// @inheritdoc IAdaptiveCurveIrm
    function setMarketCurveParams(MarketParams memory marketParams, AdaptiveCurveParams calldata curveParams) external {
        _checkAuthorized();

        Id id = marketParams.id();
        bytes32 curveParamsHash = keccak256(abi.encode(curveParams));

        // Deduplicate: reuse the config already deployed for these exact params, otherwise deploy one (it validates
        // `curveParams` in its constructor) and cache it. Immutable configs are safely shareable across markets.
        IAdaptiveCurveConfig config = deployedCurveConfigs[curveParamsHash];
        if (address(config) == address(0)) {
            config = new AdaptiveCurveConfig(curveParams);
            deployedCurveConfigs[curveParamsHash] = config;
            emit ConfigDeployed(curveParamsHash, address(config));
        }

        marketCurveConfig[id] = config;
        emit MarketCurveParamsSet(id, address(config), curveParams);
    }

    // ---
    // BORROW RATES
    // ---

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender == ROUTER, ErrorsLib.NOT_ROUTER);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns avgRate and endRateAtTarget for market `id`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        IAdaptiveCurveConfig curveConfig = marketCurveConfig[id];
        require(address(curveConfig) != address(0), ErrorsLib.CONFIG_NOT_SET);
        AdaptiveCurveParams memory curveParams = curveConfig.getCurveParams();

        // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor = utilization > curveParams.targetUtilization
            ? WAD - curveParams.targetUtilization
            : curveParams.targetUtilization;
        int256 err = (utilization - curveParams.targetUtilization).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = curveParams.initialRateAtTarget;
            endRateAtTarget = curveParams.initialRateAtTarget;
        } else {
            // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
            // So the rate is always underestimated.
            int256 speed = curveParams.adjustmentSpeed.wMulToZero(err);
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
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation, curveParams);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2, curveParams);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        uint256 rate = uint256(_curve(avgRateAtTarget, err, curveParams.curveSteepness));

        // Hard cap: clamp the charged rate to maxBorrowRate, leaving endRateAtTarget untouched. Adaptation is
        // err-driven, not rate-driven, so the state machine is unchanged and only the reported rate is bounded.
        if (curveParams.maxBorrowRate != 0 && rate > curveParams.maxBorrowRate) rate = curveParams.maxBorrowRate;

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
    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation, AdaptiveCurveParams memory curveParams)
        private
        pure
        returns (int256)
    {
        // Non negative because minRateAtTarget > 0.
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation))
            .bound(curveParams.minRateAtTarget, curveParams.maxRateAtTarget);
    }
}
