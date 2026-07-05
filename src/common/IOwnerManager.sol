// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/// @title IOwnerManager
/// @author Lido.
/// @notice Two-role (owner + manager) access surface shared by the IRMs.
interface IOwnerManager {
    /// @notice Emitted when `owner` is set or transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when `manager` is set.
    event ManagerSet(address indexed manager);

    /// @notice Address allowed to rotate the roles (`transferOwnership`, `setManager`) and set params.
    function owner() external view returns (address);

    /// @notice Address allowed to set params (alongside `owner`).
    function manager() external view returns (address);

    /// @notice Whether the contract has been initialized. Set to true on the implementation at construction (locking
    /// it) and on the proxy by `initialize`.
    function isInitialized() external view returns (bool);

    /// @notice Sets `owner` and `manager` once, reverting if already initialized or either address is zero. Must run
    /// atomically with proxy deployment.
    function initialize(address owner_, address manager_) external;

    /// @notice Sets `owner` to `newOwner`. Owner only. Reverts on zero.
    function transferOwnership(address newOwner) external;

    /// @notice Sets `manager` to `newManager`. Owner only. Reverts on zero.
    function setManager(address newManager) external;
}
