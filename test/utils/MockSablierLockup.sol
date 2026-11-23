// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup, LockupLinear, LockupTranched} from "../../src/interfaces/ISablierLockup.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Sablier Lockup v4.0 stand-in. Validates create params as documented, pulls the deposit and records every
/// parameter. Can be switched into failure modes to exercise FlasetDeals' post-create checks.
contract MockSablierLockup {
    enum Mode {
        Honest,
        PullLess, // pulls one unit less than the deposit
        PullNothing, // pulls nothing, so the allowance stays
        PullElsewhere, // pulls the deposit to another address
        WrongRecipient, // records the stream for someone else
        Cancelable, // records the stream as cancelable
        WrongDeposit, // pulls the deposit but records one unit more
        FlipTransferable, // records the opposite transferable flag
        Reenter, // calls back into its caller during the create
        LeaveDust // pulls the deposit, then leaves one unit of the token with its caller
    }

    struct Stream {
        address sender;
        address recipient;
        uint128 deposited;
        IERC20 token;
        bool cancelable;
        bool transferable;
        uint40 start;
        uint40 end;
        string shape;
        Lockup.Model model;
        uint128 unlockStart;
        uint128 unlockCliff;
        uint40 granularity;
        uint40 cliffTime;
    }

    Mode public mode;
    bytes public reenterCall;
    uint256 public nextStreamId = 1;
    uint256 public lastValue; // msg.value of the last create
    mapping(uint256 => Stream) internal _streams;
    mapping(uint256 => LockupTranched.Tranche[]) internal _tranches;

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(bytes calldata call) external {
        reenterCall = call;
    }

    function createWithTimestampsLL(
        Lockup.CreateWithTimestamps calldata p,
        LockupLinear.UnlockAmounts calldata u,
        uint40 granularity,
        uint40 cliffTime
    ) external payable returns (uint256 id) {
        require(p.depositAmount > 0 && p.timestamps.start > 0 && p.timestamps.start < p.timestamps.end, "LL: times");
        if (cliffTime > 0) require(cliffTime > p.timestamps.start && cliffTime < p.timestamps.end, "LL: cliff");
        else require(u.cliff == 0, "LL: cliff unlock without cliff");
        require(uint256(u.start) + u.cliff <= p.depositAmount, "LL: unlocks");
        uint40 range = cliffTime > 0 ? p.timestamps.end - cliffTime : p.timestamps.end - p.timestamps.start;
        require(granularity <= range, "LL: granularity");
        id = _record(p, Lockup.Model.LOCKUP_LINEAR);
        Stream storage s = _streams[id];
        (s.unlockStart, s.unlockCliff, s.granularity, s.cliffTime) = (u.start, u.cliff, granularity, cliffTime);
    }

    function createWithTimestampsLT(Lockup.CreateWithTimestamps calldata p, LockupTranched.Tranche[] calldata t)
        external
        payable
        returns (uint256 id)
    {
        require(p.depositAmount > 0 && t.length > 0 && p.timestamps.start > 0, "LT: empty");
        require(p.timestamps.start < t[0].timestamp && p.timestamps.end == t[t.length - 1].timestamp, "LT: ends");
        uint256 sum;
        for (uint256 i; i < t.length; ++i) {
            if (i > 0) require(t[i].timestamp > t[i - 1].timestamp, "LT: order");
            sum += t[i].amount;
        }
        require(sum == p.depositAmount, "LT: sum");
        id = _record(p, Lockup.Model.LOCKUP_TRANCHED);
        for (uint256 i; i < t.length; ++i) {
            _tranches[id].push(t[i]);
        }
    }

    function _record(Lockup.CreateWithTimestamps calldata p, Lockup.Model model) internal returns (uint256 id) {
        require(bytes(p.shape).length <= 32, "shape");
        lastValue = msg.value;
        id = nextStreamId++;
        uint128 pulled = p.depositAmount;
        address to = address(this);
        if (mode == Mode.PullLess) pulled -= 1;
        if (mode == Mode.PullElsewhere) to = address(0xdead);
        if (mode == Mode.Reenter) {
            (bool ok, bytes memory ret) = msg.sender.call(reenterCall);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        if (mode != Mode.PullNothing) p.token.transferFrom(msg.sender, to, pulled);
        if (mode == Mode.LeaveDust) IMintableToken(address(p.token)).mint(msg.sender, 1);
        _streams[id] = Stream({
            sender: p.sender,
            recipient: mode == Mode.WrongRecipient ? address(0xbeef) : p.recipient,
            deposited: mode == Mode.WrongDeposit ? p.depositAmount + 1 : p.depositAmount,
            token: p.token,
            cancelable: mode == Mode.Cancelable ? true : p.cancelable,
            transferable: mode == Mode.FlipTransferable ? !p.transferable : p.transferable,
            start: p.timestamps.start,
            end: p.timestamps.end,
            shape: p.shape,
            model: model,
            unlockStart: 0,
            unlockCliff: 0,
            granularity: 0,
            cliffTime: 0
        });
    }

    // ---------------------------------------------------------------- getters read by FlasetDeals

    function getRecipient(uint256 id) external view returns (address) {
        return _streams[id].recipient;
    }

    function getDepositedAmount(uint256 id) external view returns (uint128) {
        return _streams[id].deposited;
    }

    function isCancelable(uint256 id) external view returns (bool) {
        return _streams[id].cancelable;
    }

    function isTransferable(uint256 id) external view returns (bool) {
        return _streams[id].transferable;
    }

    // ---------------------------------------------------------------- for the tests

    function stream(uint256 id) external view returns (Stream memory) {
        return _streams[id];
    }

    function tranches(uint256 id) external view returns (LockupTranched.Tranche[] memory) {
        return _tranches[id];
    }
}
