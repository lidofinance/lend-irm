// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {IAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ExpLib} from "./libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../lib/morpho-blue/src/libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract AdaptiveCurveIrm is IAdaptiveCurveIrm {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* STRUCTS */

    /// @notice Curve parameters passed at construction and frozen into immutables.
    struct Config {
        int256 curveSteepness; // WAD, >= 1e18
        int256 adjustmentSpeed; // WAD per second, >= 0
        int256 targetUtilization; // WAD, in (0, 1e18)
        int256 initialRateAtTarget; // WAD per second, in [minRateAtTarget, maxRateAtTarget]
        int256 minRateAtTarget; // WAD per second, > 0
        int256 maxRateAtTarget; // WAD per second, >= minRateAtTarget
        int256 maxBorrowRate; // WAD per second, >= 0; 0 = uncapped, else a hard ceiling on the charged rate
    }

    /* IMMUTABLES */

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable MORPHO;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable CURVE_STEEPNESS;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable ADJUSTMENT_SPEED;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable TARGET_UTILIZATION;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable INITIAL_RATE_AT_TARGET;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable MIN_RATE_AT_TARGET;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable MAX_RATE_AT_TARGET;

    /// @inheritdoc IAdaptiveCurveIrm
    int256 public immutable MAX_BORROW_RATE;

    /* STORAGE */

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /* CONSTRUCTOR */

    /// @notice Constructor.
    /// @param morpho The address of Morpho.
    /// @param cfg The curve parameters, lifted to immutables so a single implementation can be deployed behind a
    /// proxy and reparametrized by upgrading to a new implementation while the stored `rateAtTarget` persists.
    constructor(address morpho, Config memory cfg) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);
        _validateConfig(cfg);

        MORPHO = morpho;
        CURVE_STEEPNESS = cfg.curveSteepness;
        ADJUSTMENT_SPEED = cfg.adjustmentSpeed;
        TARGET_UTILIZATION = cfg.targetUtilization;
        INITIAL_RATE_AT_TARGET = cfg.initialRateAtTarget;
        MIN_RATE_AT_TARGET = cfg.minRateAtTarget;
        MAX_RATE_AT_TARGET = cfg.maxRateAtTarget;
        MAX_BORROW_RATE = cfg.maxBorrowRate;
    }

    /// @dev Reverts unless `cfg` is a valid curve configuration, with a per-parameter error message.
    function _validateConfig(Config memory cfg) internal pure {
        require(cfg.curveSteepness >= WAD, ErrorsLib.INVALID_CURVE_STEEPNESS);
        require(cfg.adjustmentSpeed >= 0, ErrorsLib.INVALID_ADJUSTMENT_SPEED);
        require(cfg.targetUtilization > 0 && cfg.targetUtilization < WAD, ErrorsLib.INVALID_TARGET_UTILIZATION);
        require(cfg.minRateAtTarget > 0 && cfg.maxRateAtTarget >= cfg.minRateAtTarget, ErrorsLib.INVALID_RATE_BOUNDS);
        require(
            cfg.initialRateAtTarget >= cfg.minRateAtTarget && cfg.initialRateAtTarget <= cfg.maxRateAtTarget,
            ErrorsLib.INVALID_INITIAL_RATE
        );
        require(cfg.maxBorrowRate >= 0, ErrorsLib.INVALID_MAX_BORROW_RATE);
    }

    /// @notice Returns all curve parameters of this implementation in a single call (convenience for integrators).
    function getConfig() external view returns (Config memory) {
        return Config({
            curveSteepness: CURVE_STEEPNESS,
            adjustmentSpeed: ADJUSTMENT_SPEED,
            targetUtilization: TARGET_UTILIZATION,
            initialRateAtTarget: INITIAL_RATE_AT_TARGET,
            minRateAtTarget: MIN_RATE_AT_TARGET,
            maxRateAtTarget: MAX_RATE_AT_TARGET,
            maxBorrowRate: MAX_BORROW_RATE
        });
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
        // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
            // So the rate is always underestimated.
            int256 speed = ADJUSTMENT_SPEED.wMulToZero(err);
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
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        uint256 rate = uint256(_curve(avgRateAtTarget, err));

        // Hard cap: clamp the charged rate to MAX_BORROW_RATE, leaving endRateAtTarget untouched. Adaptation is
        // err-driven, not rate-driven, so the state machine is unchanged and only the reported rate is bounded.
        if (MAX_BORROW_RATE != 0 && rate > uint256(MAX_BORROW_RATE)) rate = uint256(MAX_BORROW_RATE);

        return (rate, endRateAtTarget);
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err) private view returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD;
        // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
        return (coeff.wMulToZero(err) + WAD).wMulToZero(int256(_rateAtTarget));
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) private view returns (int256) {
        // Non negative because MIN_RATE_AT_TARGET > 0.
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }
}
