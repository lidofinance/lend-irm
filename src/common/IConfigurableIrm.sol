// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {Id, MarketParams} from "../../lib/lido-lend/src/interfaces/IMorpho.sol";

/// @title IConfigurableIrm
/// @author Lido.
/// @notice Shared surface for applying an external IRM config to a market.
interface IConfigurableIrm {
    /// @notice Emitted when the IRM parameters returned by `config` are applied to market `id`.
    event IrmConfigApplied(Id indexed marketId, address indexed config);

    /// @notice Applies the IRM parameters returned by `config` to the market identified by `marketParams`.
    /// @dev The parameters are not validated; the caller guarantees their validity.
    function applyIrmConfig(MarketParams calldata marketParams, address config) external;
}
