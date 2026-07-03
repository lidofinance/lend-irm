// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IOwnerManager} from "./IOwnerManager.sol";
import {OwnerManagerErrors} from "./OwnerManagerErrors.sol";

/// @title OwnerManagerBase
/// @author Lido.
/// @notice Two-role access base shared by the IRMs: an `owner` that rotates itself and the `manager`, a `manager`
/// scoped to the param setters, and a one-shot `isInitialized` lock. The constructor marks the implementation itself
/// initialized so only a freshly-deployed proxy (whose storage starts zeroed) can be `initialize`d.
/// @dev Derived contracts call `_initializeRoles` from their own `initialize` (which also sets the model params), gate
/// owner-only actions with `_checkOwner`, and owner-or-manager actions with `_checkAuthorized`.
abstract contract OwnerManagerBase is IOwnerManager {
    /* STORAGE */

    /// @inheritdoc IOwnerManager
    address public override owner;

    /// @inheritdoc IOwnerManager
    address public override manager;

    /// @inheritdoc IOwnerManager
    bool public override isInitialized;

    /* CONSTRUCTOR */

    /// @dev Locks the implementation: only a proxy (whose storage starts zeroed) can be `initialize`d.
    constructor() {
        isInitialized = true;
    }

    /* OWNERSHIP & MANAGEMENT */

    /// @inheritdoc IOwnerManager
    function transferOwnership(address newOwner) external override {
        _checkOwner();
        _transferOwnership(newOwner);
    }

    /// @inheritdoc IOwnerManager
    function setManager(address newManager) external override {
        _checkOwner();
        _setManager(newManager);
    }

    /// @inheritdoc IOwnerManager
    function initialize(address owner_, address manager_) external override {
        require(!isInitialized, OwnerManagerErrors.ALREADY_INITIALIZED);

        isInitialized = true;
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    /// @dev Reverts unless the caller is the owner.
    function _checkOwner() internal view {
        require(msg.sender == owner, OwnerManagerErrors.NOT_OWNER);
    }

    /// @dev Reverts unless the caller is the owner or the manager.
    function _checkAuthorized() internal view {
        require(msg.sender == owner || msg.sender == manager, OwnerManagerErrors.NOT_AUTHORIZED);
    }

    /// @dev Sets `owner` to `newOwner`, reverting on the zero address, and emits `OwnershipTransferred`.
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @dev Sets `manager` to `newManager`, reverting on the zero address, and emits `ManagerSet`.
    function _setManager(address newManager) internal {
        require(newManager != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        manager = newManager;
        emit ManagerSet(newManager);
    }
}
