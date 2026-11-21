// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Capability registry shared by every FLASET module: which tokens may play which role, how much
/// of a token one settlement may move, and which swap adapters may be called. A token on the block list
/// can never be allowlisted.
interface IFlasetRegistry {
    function DEAL_ASSET() external view returns (uint8);
    function SETTLEMENT() external view returns (uint8);
    function CHECKOUT_SOURCE() external view returns (uint8);

    function hasFlag(address token, uint8 flag) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function isBlocked(address token) external view returns (bool);
    function txCap(address token) external view returns (uint256);
}
