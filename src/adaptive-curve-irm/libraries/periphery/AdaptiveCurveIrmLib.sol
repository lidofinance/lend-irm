// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Id, Market, IMorpho} from "../../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "../../interfaces/IAdaptiveCurveIrm.sol";
import {IAdaptiveCurveConfig} from "../../interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../../interfaces/IAdaptiveCurveTypes.sol";

import {AdaptiveCurveMathLib} from "../AdaptiveCurveMathLib.sol";
import {ErrorsLib} from "../ErrorsLib.sol";
import {SharesMathLib} from "../../../../lib/lido-lend/src/libraries/SharesMathLib.sol";
import {MathLib as MorphoMathLib} from "../../../../lib/lido-lend/src/libraries/MathLib.sol";
import {UtilsLib as MorphoUtilsLib} from "../../../../lib/lido-lend/src/libraries/UtilsLib.sol";

/// @title AdaptiveCurveIrmLib
/// @author Morpho Labs. Modified by Lido.
/// @dev Library to compute borrowRateView and expectedMarketBalances with only the market id.
/// @dev Must be used only for markets routed to an AdaptiveCurveIrm (passed as `adaptiveCurveIrm`).
/// @dev Reverts with `CONFIG_NOT_SET` when the market has no config registered on the IRM.
library AdaptiveCurveIrmLib {
    using MorphoMathLib for uint256;
    using MorphoMathLib for uint128;
    using SharesMathLib for uint256;
    using MorphoUtilsLib for uint256;

    /// @dev Same as the MorphoBalancesLib.expectedMarketBalances function, but takes the market id as input.
    /// @dev Works only for markets routed to an AdaptiveCurveIrm.
    /// @dev Returns the expected totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares.
    function expectedMarketBalances(address morpho, bytes32 id, address adaptiveCurveIrm)
        internal
        view
        returns (uint256, uint256, uint256, uint256)
    {
        Market memory market = IMorpho(morpho).market(Id.wrap(id));

        uint256 elapsed = block.timestamp - market.lastUpdate;

        // Skipped if elapsed == 0 or totalBorrowAssets == 0 because interest would be null.
        if (elapsed != 0 && market.totalBorrowAssets != 0) {
            uint256 borrowRate = borrowRateView(id, market, adaptiveCurveIrm);
            uint256 interest = market.totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market.totalBorrowAssets += interest.toUint128();
            market.totalSupplyAssets += interest.toUint128();

            if (market.fee != 0) {
                uint256 feeAmount = interest.wMulDown(market.fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already updated.
                uint256 feeShares =
                    feeAmount.toSharesDown(market.totalSupplyAssets - feeAmount, market.totalSupplyShares);
                market.totalSupplyShares += feeShares.toUint128();
            }
        }

        return (market.totalSupplyAssets, market.totalSupplyShares, market.totalBorrowAssets, market.totalBorrowShares);
    }

    /// @dev Same as the AdaptiveCurveIrm.borrowRateView function, but takes the market id as input.
    /// @dev Works only for markets routed to an AdaptiveCurveIrm.
    /// @dev Returns avgRate.
    function borrowRateView(bytes32 id, Market memory market, address adaptiveCurveIrm)
        internal
        view
        returns (uint256)
    {
        (uint256 avgRate,) = _borrowRate(Id.wrap(id), market, adaptiveCurveIrm);
        return avgRate;
    }

    /// @dev Same as the AdaptiveCurveIrm.borrowRate function, but takes the market id as input.
    /// @dev Returns avgRate and endRateAtTarget.
    function _borrowRate(Id id, Market memory market, address adaptiveCurveIrm)
        internal
        view
        returns (uint256, int256)
    {
        // Mirrors the IRM: params come live from the market's current config, so the recompute tracks
        // re-pointing.
        IAdaptiveCurveConfig config = IAdaptiveCurveIrm(adaptiveCurveIrm).marketCurveConfig(id);
        require(address(config) != address(0), ErrorsLib.CONFIG_NOT_SET);
        AdaptiveCurveParams memory p = config.getCurveParams();

        int256 startRateAtTarget = IAdaptiveCurveIrm(adaptiveCurveIrm).rateAtTarget(id);

        return AdaptiveCurveMathLib.computeBorrowRate(p, startRateAtTarget, market);
    }
}
