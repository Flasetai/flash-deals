// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Burns part of every transfer (fee-on-transfer).
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burn = value / 100;
            super._update(from, address(0), burn);
            super._update(from, to, value - burn);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice A plain token until its issuer switches on a fee on every transfer, the way an upgradeable token can be
/// upgraded to one that takes a fee. The fee leaves the transferred amount, so the receiver gets less.
contract SwitchableFeeToken is ERC20 {
    uint256 public feeBps;

    constructor() ERC20("Switchable Fee Token", "SWF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeBps == 0 || from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0xFEE), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Returns false instead of reverting when a transfer cannot happen.
contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFail(bool fail) external {
        failTransfers = fail;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfers || balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransfers || balanceOf[from] < amount || allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Calls an arbitrary target during transferFrom, like an ERC-777 hook would.
contract HookToken is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public lastHookOk;
    bytes public lastHookReturn;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (hookTarget != address(0)) {
            address target = hookTarget;
            hookTarget = address(0);
            (bool ok, bytes memory ret) = target.call(hookData);
            // Bubble the inner revert so tests can see why re-entry failed.
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return super.transferFrom(from, to, value);
    }
}
