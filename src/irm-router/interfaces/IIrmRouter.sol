// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../../lib/lido-lend/src/interfaces/IIrm.sol";
import {Id, MarketParams} from "../../../lib/lido-lend/src/interfaces/IMorpho.sol";
import {IOwnerManager} from "../../common/IOwnerManager.sol";

/// @title IIrmRouter
/// @author Lido.
/// @notice Interface of the IrmRouter: forwards a market's `borrowRate`/`borrowRateView` to a switchable
/// per-market implementation. Proxied, so the roles are set via `initialize`.
interface IIrmRouter is IIrm, IOwnerManager {
    /// @notice Emitted when market `id` is routed to `irm`.
    event MarketIrmSet(Id indexed id, address indexed irm);

    /// @notice Address of Morpho.
    function MORPHO() external view returns (address);

    /// @notice Whether the contract has been initialized. True on the implementation from construction (locking it)
    /// and on the proxy after `initialize`.
    function isInitialized() external view returns (bool);

    /// @notice Sets `owner` and `manager` once, reverting if already initialized or either address is zero. Must run
    /// atomically with proxy deployment.
    function initialize(address owner_, address manager_) external;

    /// @notice The IRM implementation serving market `id` (zero if none). Re-pointable but never clearable, so a
    /// live market always has an implementation.
    function marketIrm(Id id) external view returns (IIrm);

    /// @notice Routes market `id = marketParams.id()` to `irm`. Owner or manager only.
    function setMarketIrm(MarketParams memory marketParams, IIrm irm) external;
}
