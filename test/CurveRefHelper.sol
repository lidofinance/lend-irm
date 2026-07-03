// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {MathLib, WAD_INT as WAD} from "../src/adaptive-curve-irm/libraries/MathLib.sol";
import {UtilsLib} from "../src/adaptive-curve-irm/libraries/UtilsLib.sol";
import {ExpLib} from "../src/adaptive-curve-irm/libraries/ExpLib.sol";
import {Market} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";

/// @dev The differential tests' oracle: recomputes the borrow rate from scratch (curve + adaptation + cap) so a
/// contract's output can be checked against an independent implementation, parametrized by the market's params.
abstract contract CurveRefHelper {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;

    /// @dev Reference borrowRate: returns (avgRate, endRateAtTarget) for one interaction at the current
    /// `block.timestamp`, starting from `startRate` (0 means first interaction).
    function _refBorrowRate(AdaptiveCurveParams memory config, int256 startRate, Market memory market)
        internal
        view
        returns (uint256, int256)
    {
        int256 err = _refErr(market, config.targetUtilization);

        int256 avgRateAtTarget;
        int256 endRateAtTarget;
        if (startRate == 0) {
            avgRateAtTarget = config.initialRateAtTarget;
            endRateAtTarget = config.initialRateAtTarget;
        } else {
            int256 linearAdaptation =
                config.adjustmentSpeed.wMulToZero(err) * int256(block.timestamp - market.lastUpdate);
            if (linearAdaptation == 0) {
                avgRateAtTarget = startRate;
                endRateAtTarget = startRate;
            } else {
                endRateAtTarget =
                    _refNewRateAtTarget(startRate, linearAdaptation, config.minRateAtTarget, config.maxRateAtTarget);
                int256 midRateAtTarget = _refNewRateAtTarget(
                    startRate, linearAdaptation / 2, config.minRateAtTarget, config.maxRateAtTarget
                );
                avgRateAtTarget = (startRate + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        uint256 rate = uint256(_refCurve(avgRateAtTarget, err, config.curveSteepness));
        if (config.maxBorrowRate != 0 && rate > config.maxBorrowRate) rate = config.maxBorrowRate;
        return (rate, endRateAtTarget);
    }

    /// @dev Reference `err`: utilization's signed deviation from target, scaled to [-1, +1] (-1 empty, 0 at
    /// target, +1 full). Mirrors the contract.
    function _refErr(Market memory market, int256 targetUtilization) internal pure returns (int256) {
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > targetUtilization ? WAD - targetUtilization : targetUtilization;
        return (utilization - targetUtilization).wDivToZero(errNormFactor);
    }

    /// @dev Reference curve: maps (`rateAtTarget`, `err`) to a rate for `curveSteepness`. Mirrors the contract's
    /// `_curve`.
    function _refCurve(int256 rateAtTarget, int256 err, int256 curveSteepness) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        return (coeff.wMulToZero(err) + WAD).wMulToZero(rateAtTarget);
    }

    /// @dev Reference adaptation step: start * exp(linearAdaptation), clamped to [min, max]. Mirrors
    /// `_newRateAtTarget`.
    function _refNewRateAtTarget(int256 start, int256 linearAdaptation, int256 minRate, int256 maxRate)
        internal
        pure
        returns (int256)
    {
        return start.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(minRate, maxRate);
    }
}
