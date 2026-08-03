// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IOwnerManager} from "../../common/IOwnerManager.sol";
import {IConfigurableIrm} from "../../common/IConfigurableIrm.sol";

/// @title ILinearKinkIrm
/// @author Lido.
/// @notice Interface of the LinearKinkIrm: per-market kink params and the `IIrm` pricing surface.
interface ILinearKinkIrm is IIrm, IOwnerManager, IConfigurableIrm {
    /// @notice The kink parameters set for market `id` (all zero if none). `optimalUtilization == 0` marks a market
    /// that has not been configured.
    function marketKinkParams(Id id)
        external
        view
        returns (uint64 optimalUtilization, uint64 baseRate, uint64 slope1, uint64 slope2);
}
