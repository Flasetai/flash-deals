// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFlasetRegistry} from "./interfaces/IFlasetRegistry.sol";

/// @title FlasetRegistry
/// @notice On-chain allowlist for tokens and swap adapters, plus a per-transaction cap per token. Every
/// module reads it before moving funds. The owner is meant to be a multisig in production; on testnet it
/// is the deployer. Blocking is one-way: tokenized stocks, other RWAs and anything unclassifiable go on
/// the block list and can never be given a flag again.
contract FlasetRegistry is IFlasetRegistry, Ownable2Step {
    uint8 public constant DEAL_ASSET = 1; // may be sold in a Flash Deal
    uint8 public constant SETTLEMENT = 2; // cash leg of a Deal, pay token of a Checkout
    uint8 public constant CHECKOUT_SOURCE = 4; // may be converted by a Checkout leg
    uint8 internal constant ALL_FLAGS = DEAL_ASSET | SETTLEMENT | CHECKOUT_SOURCE;

    mapping(address token => uint8 flags) public tokenFlags;
    mapping(address token => bool) public isBlocked;
    mapping(address adapter => bool) public isAdapter;
    /// @notice Most of a token one settlement may move, in the token's own units. Zero means nothing: a
    /// token whose cap was never set cannot be used, so a forgotten cap fails closed.
    mapping(address token => uint256 cap) public txCap;

    event TokenFlagsSet(address indexed token, uint8 flags);
    event TokenBlocked(address indexed token);
    event AdapterSet(address indexed adapter, bool allowed);
    event TxCapSet(address indexed token, uint256 cap);

    error TokenIsBlocked(address token);
    error UnknownFlags(uint8 flags);
    error ZeroAddress();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    function setTokenFlags(address token, uint8 flags) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isBlocked[token]) revert TokenIsBlocked(token);
        if (flags & ~ALL_FLAGS != 0) revert UnknownFlags(flags);
        tokenFlags[token] = flags;
        emit TokenFlagsSet(token, flags);
    }

    /// @notice Permanently removes a token from every role.
    function blockToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isBlocked[token] = true;
        tokenFlags[token] = 0;
        txCap[token] = 0;
        emit TokenBlocked(token);
        emit TokenFlagsSet(token, 0);
        emit TxCapSet(token, 0);
    }

    function setTxCap(address token, uint256 cap) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isBlocked[token]) revert TokenIsBlocked(token);
        txCap[token] = cap;
        emit TxCapSet(token, cap);
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        isAdapter[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function hasFlag(address token, uint8 flag) external view returns (bool) {
        return !isBlocked[token] && tokenFlags[token] & flag == flag && flag != 0;
    }

    /// @notice Ownership can move (in two steps) but never be renounced: without an owner the allowlist
    /// could never block a bad token again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
