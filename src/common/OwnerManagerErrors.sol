// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title OwnerManagerErrors
/// @author Lido.
/// @notice Error messages for the shared owner/manager access base (OwnerManagerBase).
library OwnerManagerErrors {
    /// @dev Thrown when passing the zero address.
    string internal constant ZERO_ADDRESS = "zero address";

    /// @dev Thrown when the caller of an owner-only function is not the owner.
    string internal constant NOT_OWNER = "not owner";

    /// @dev Thrown when the caller of a param setter is neither the owner nor the manager.
    string internal constant NOT_AUTHORIZED = "not authorized";

    /// @dev Thrown when `initialize` is called after the contract is already initialized.
    string internal constant ALREADY_INITIALIZED = "already initialized";
}
