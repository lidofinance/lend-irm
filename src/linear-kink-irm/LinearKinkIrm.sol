// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IIrm} from "../../lib/lido-lend/src/interfaces/IIrm.sol";
import {ILinearKinkIrm} from "./interfaces/ILinearKinkIrm.sol";
import {LinearKinkParams} from "./interfaces/ILinearKinkTypes.sol";
import {OwnerManagerBase} from "../common/OwnerManagerBase.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../lib/lido-lend/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../lib/lido-lend/src/libraries/MathLib.sol";

/// @title LinearKinkIrm
/// @author Lido.
/// @notice A stateless kinked IRM: the per-second borrow rate is a piecewise-linear function of utilization that
/// steepens past the kink. One immutable instance serves many markets, each with its own params set by the `owner`
/// or `manager`. Meant to sit behind IrmRouter.
contract LinearKinkIrm is ILinearKinkIrm, OwnerManagerBase {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum peak rate (baseRate + slope1 + slope2, reached at full utilization) = 800%/year (WAD-scaled,
    /// per second). Also keeps the rate math from overflowing and lets every field fit in `uint64`.
    uint256 public constant MAX_BORROW_RATE = 8.0 ether / uint256(365 days);

    // ---
    // STORAGE
    // ---

    /// @inheritdoc ILinearKinkIrm
    mapping(Id => LinearKinkParams) public marketKinkParams;

    // ---
    // CONSTRUCTOR
    // ---

    constructor(address owner_, address manager_) {
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    // ---
    // CONFIG MANAGEMENT
    // ---

    /// @inheritdoc ILinearKinkIrm
    function setMarketKinkParams(MarketParams memory marketParams, LinearKinkParams calldata params) external {
        _checkAuthorized();

        require(params.optimalUtilization > 0, ErrorsLib.INVALID_OPTIMAL_UTILIZATION);
        require(params.optimalUtilization < WAD, ErrorsLib.INVALID_OPTIMAL_UTILIZATION);
        require(
            uint256(params.baseRate) + params.slope1 + params.slope2 <= MAX_BORROW_RATE, ErrorsLib.MAX_RATE_EXCEEDED
        );

        Id id = marketParams.id();
        marketKinkParams[id] = params;

        emit MarketKinkParamsSet(id, params);
    }

    // ---
    // BORROW RATES
    // ---

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return _borrowRate(marketParams.id(), market);
    }

    /// @inheritdoc IIrm
    /// @dev Stateless: identical to `borrowRateView`.
    function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return _borrowRate(marketParams.id(), market);
    }

    /// @dev Computes the linear-kink per-second borrow rate for market `id` from its current utilization. The curve
    /// is piecewise-linear in utilization `U`:
    ///   U <= optimalUtilization: baseRate + slope1 * U / optimalUtilization
    ///   U >  optimalUtilization: baseRate + slope1 + slope2 * (U - optimalUtilization) / (WAD - optimalUtilization)
    function _borrowRate(Id id, Market memory market) private view returns (uint256) {
        LinearKinkParams memory p = marketKinkParams[id];
        require(p.optimalUtilization != 0, ErrorsLib.CONFIG_NOT_SET);

        uint256 utilization =
            market.totalSupplyAssets > 0 ? uint256(market.totalBorrowAssets).wDivDown(market.totalSupplyAssets) : 0;
        // Utilization cannot exceed 100% in Morpho. Clamping defends the rate math against adversarial view inputs and
        // caps the returned rate at the curve's peak.
        if (utilization > WAD) utilization = WAD;

        if (utilization <= p.optimalUtilization) {
            return p.baseRate + uint256(p.slope1).wMulDown(utilization.wDivDown(p.optimalUtilization));
        } else {
            uint256 excess = (utilization - p.optimalUtilization).wDivDown(WAD - p.optimalUtilization);
            return uint256(p.baseRate) + p.slope1 + uint256(p.slope2).wMulDown(excess);
        }
    }
}
