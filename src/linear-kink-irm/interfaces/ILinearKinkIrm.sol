// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOwnerManager} from "../../common/IOwnerManager.sol";
import {LinearKinkParams} from "./ILinearKinkTypes.sol";

/// @title ILinearKinkIrm
/// @author Lido.
/// @notice Interface of the LinearKinkIrm: per-market kink params and the `IIrm` pricing surface.
interface ILinearKinkIrm is IIrm, IOwnerManager {
    /// @notice Emitted when market `id`'s kink parameters are set.
    event MarketKinkParamsSet(Id indexed id, LinearKinkParams kinkParams);

    /// @notice Maximum allowed peak rate (`baseRate + slope1 + slope2`), per second and WAD-scaled.
    function MAX_BORROW_RATE() external view returns (uint256);

    /// @notice The kink parameters set for market `id` (all zero if none). `optimalUtilization == 0` marks a market
    /// that has not been configured.
    function marketKinkParams(Id id)
        external
        view
        returns (uint64 optimalUtilization, uint64 baseRate, uint64 slope1, uint64 slope2);

    /// @notice Validates `kinkParams` and stores them for market `id = marketParams.id()`. Owner or manager only.
    function setMarketKinkParams(MarketParams memory marketParams, LinearKinkParams calldata kinkParams) external;
}
