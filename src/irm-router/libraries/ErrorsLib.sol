// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author Lido.
/// @notice Errors of the IrmRouter.
library ErrorsLib {
    /// @notice Thrown when `borrowRate` is called by an address other than Morpho.
    string internal constant NOT_MORPHO = "not Morpho";

    /// @notice Thrown when pricing a market that has not been routed to an implementation.
    string internal constant IRM_NOT_SET = "irm not set";

    /// @notice Thrown when routing marketParams whose `irm` field is not this router.
    string internal constant NOT_ROUTER_MARKET = "irm is not this router";
}
