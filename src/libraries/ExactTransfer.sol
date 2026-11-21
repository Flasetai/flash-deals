// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Token moves that must land exactly. A recipient balance that does not grow by the sent
/// amount (fee-on-transfer, rebasing, hooks that skim) reverts the whole settlement instead of
/// settling a smaller amount than both sides signed.
library ExactTransfer {
    using SafeERC20 for IERC20;

    error TransferMismatch(address token, address to, uint256 expected, uint256 received);

    function pullExact(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        uint256 received = token.balanceOf(to) - before;
        if (received != amount) revert TransferMismatch(address(token), to, amount, received);
    }

    function sendExact(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 received = token.balanceOf(to) - before;
        if (received != amount) revert TransferMismatch(address(token), to, amount, received);
    }
}
