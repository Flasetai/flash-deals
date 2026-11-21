// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The types of Sablier Lockup v4.0 that FlasetDealsV2 uses, written from Sablier's reference documentation
/// (docs.sablier.com/reference/lockup, source commit 8b6823c of sablier-labs/evm-monorepo). Field order and types
/// match the deployed ABI: the fork tests create, read back and withdraw real streams with them.
library Lockup {
    struct Timestamps {
        uint40 start;
        uint40 end;
    }

    struct CreateWithTimestamps {
        address sender; // may cancel a cancelable stream; FlasetDealsV2 passes itself and never cancels
        address recipient; // receives the tokens and the stream NFT
        uint128 depositAmount;
        IERC20 token;
        bool cancelable;
        bool transferable; // whether the stream NFT can move to another owner
        Timestamps timestamps;
        string shape; // the Shape ID Sablier's app uses to draw the curve, at most 32 characters
    }

    enum Model {
        LOCKUP_LINEAR,
        LOCKUP_DYNAMIC,
        LOCKUP_TRANCHED,
        LOCKUP_PRICE_GATED
    }

    enum Status {
        PENDING,
        STREAMING,
        SETTLED,
        CANCELED,
        DEPLETED
    }
}

library LockupLinear {
    struct UnlockAmounts {
        uint128 start; // unlocked at the start time
        uint128 cliff; // unlocked at the cliff time
    }
}

library LockupTranched {
    struct Tranche {
        uint128 amount;
        uint40 timestamp; // the moment this tranche unlocks
    }
}

/// @notice The part of SablierLockup v4.0 that FlasetDealsV2, its tests and the app call. On Robinhood Chain (4663):
/// SablierLockup 0x548129a58bC230549DF7F9e33f27E77F6779ff0f (Sablier's deployments page, lockup-v4.0). Its code is
/// byte-identical to Sablier's v4.0 deployment on Ethereum apart from its own address, and every selector below is in
/// its dispatcher (L761, 14-11-2026).
interface ISablierLockup {
    /// @notice Creates a Lockup Linear stream, funded by msg.sender. A cliff time of 0 means no cliff; a granularity of
    /// 0 means 1 second, and a larger one unlocks in discrete steps of that many seconds.
    function createWithTimestampsLL(
        Lockup.CreateWithTimestamps calldata params,
        LockupLinear.UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        uint40 cliffTime
    ) external payable returns (uint256 streamId);

    /// @notice Creates a Lockup Tranched stream, funded by msg.sender. The tranche amounts must add up to the deposit and
    /// the last timestamp must equal the end time.
    function createWithTimestampsLT(
        Lockup.CreateWithTimestamps calldata params,
        LockupTranched.Tranche[] calldata tranches
    ) external payable returns (uint256 streamId);

    function getRecipient(uint256 streamId) external view returns (address recipient);
    function getSender(uint256 streamId) external view returns (address sender);
    function getDepositedAmount(uint256 streamId) external view returns (uint128 depositedAmount);
    function getUnderlyingToken(uint256 streamId) external view returns (IERC20 token);
    function isCancelable(uint256 streamId) external view returns (bool result);
    function isTransferable(uint256 streamId) external view returns (bool result);
    function getStartTime(uint256 streamId) external view returns (uint40 startTime);
    function getEndTime(uint256 streamId) external view returns (uint40 endTime);
    function getCliffTime(uint256 streamId) external view returns (uint40 cliffTime);
    function getGranularity(uint256 streamId) external view returns (uint40 granularity);
    function getUnlockAmounts(uint256 streamId) external view returns (LockupLinear.UnlockAmounts memory unlockAmounts);
    function getTranches(uint256 streamId) external view returns (LockupTranched.Tranche[] memory tranches);
    function getLockupModel(uint256 streamId) external view returns (Lockup.Model lockupModel);
    function getWithdrawnAmount(uint256 streamId) external view returns (uint128 withdrawnAmount);
    function statusOf(uint256 streamId) external view returns (Lockup.Status status);
    function streamedAmountOf(uint256 streamId) external view returns (uint128 streamedAmount);
    function withdrawableAmountOf(uint256 streamId) external view returns (uint128 withdrawableAmount);
    function wasCanceled(uint256 streamId) external view returns (bool result);
    /// @notice The fee in wei a withdrawal must send, set per stream sender by Sablier's comptroller (0 while no price
    /// oracle is set, as on Robinhood Chain on 14-11-2026).
    function calculateMinFeeWei(uint256 streamId) external view returns (uint256 minFeeWei);
    function nextStreamId() external view returns (uint256);
    function comptroller() external view returns (address);

    function withdraw(uint256 streamId, address to, uint128 amount) external payable;
    function withdrawMax(uint256 streamId, address to) external payable returns (uint128 withdrawnAmount);
    function cancel(uint256 streamId) external payable returns (uint128 refundedAmount);
    function renounce(uint256 streamId) external payable;

    function ownerOf(uint256 tokenId) external view returns (address owner);
    function transferFrom(address from, address to, uint256 tokenId) external;
}
