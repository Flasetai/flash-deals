// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FlasetTestBase} from "./utils/FlasetTestBase.sol";
import {FlasetDealsV3} from "../src/FlasetDealsV3.sol";
import {ExactTransfer} from "../src/libraries/ExactTransfer.sol";
import {IFlasetRegistry} from "../src/interfaces/IFlasetRegistry.sol";
import {ISablierLockup, Lockup, LockupTranched} from "../src/interfaces/ISablierLockup.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSablierLockup} from "./utils/MockSablierLockup.sol";
import {FeeOnTransferToken, FalseReturnToken, HookToken} from "./utils/QuirkTokens.sol";
import {Erc1271Wallet} from "./utils/TestWallets.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token whose transferFrom checks the allowance but never spends it.
contract StickyAllowanceToken is ERC20 {
    constructor() ERC20("Sticky Allowance", "STICKY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(allowance(from, msg.sender) >= value, "allowance");
        _transfer(from, to, value);
        return true;
    }
}

/// @notice Unit tests against MockSablierLockup: v1/v2 guards, the create call per shape, and post-create checks
/// against a misbehaving Lockup. The registry lists nothing and caps everything at 0 (V3 reads neither).
/// Token edge cases and the block list are in FlasetDealsV3Tokens.t.sol.
contract FlasetDealsV3Test is FlasetTestBase {
    uint256 constant PAY = 10_000e6; // 10,000 USDG
    uint256 constant ASSET = 1_000_000e18; // 1M project tokens
    uint256 constant VESTED = ASSET * 3 / 10;

    FlasetDealsV3 internal v3;
    MockSablierLockup internal lockup;
    bytes32[] internal noProof; // OneWallet deals carry no Merkle proof

    function setUp() public override {
        super.setUp();
        lockup = new MockSablierLockup();
        v3 = new FlasetDealsV3(IFlasetRegistry(address(registry)), ISablierLockup(address(lockup)), admin, treasury);
        vm.startPrank(admin);
        v3.unpause();
        // Nothing listed and every cap at 0, which closed these tokens on V2; V3 must not care.
        address[3] memory tokens = [address(usdg), address(weth), address(projectToken)];
        for (uint256 i; i < 3; ++i) {
            registry.setTokenFlags(tokens[i], 0);
            registry.setTxCap(tokens[i], 0);
        }
        vm.stopPrank();
        vm.label(address(v3), "FlasetDealsV3");
        vm.label(address(lockup), "MockSablierLockup");
    }

    // ---------------------------------------------------------------- the five shapes: what Sablier is asked for

    function test_settle_withoutVesting_movesExactAmounts() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = _settle(d);

        uint256 fee = PAY * 20 / 10_000; // 20 USDG
        assertEq(usdg.balanceOf(seller), PAY - fee, "seller proceeds");
        assertEq(usdg.balanceOf(treasury), fee, "fee");
        assertEq(usdg.balanceOf(buyer), 0, "buyer paid all");
        assertEq(projectToken.balanceOf(buyer), ASSET, "buyer asset");
        assertEq(projectToken.balanceOf(seller), 0, "seller delivered all");
        assertTrue(v3.consumed(digest));
        assertEq(v3.feesCollected(address(usdg)), fee);
        assertEq(lockup.nextStreamId(), 1, "no stream");
        _assertHoldsNothing();
    }

    /// 70% delivered now, 30% into a linear stream.
    function test_shape_linear_70_30() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        vm.expectEmit(false, true, true, true, address(v3));
        emit FlasetDealsV3.DealSettled(
            bytes32(0), seller, buyer, address(projectToken), ASSET, VESTED, 1, address(usdg), PAY, 20e6
        );
        _settle(d);

        assertEq(projectToken.balanceOf(buyer), ASSET * 7 / 10, "70% now");
        assertEq(projectToken.balanceOf(address(lockup)), VESTED, "30% in the stream");
        MockSablierLockup.Stream memory s = _common(1, VESTED, block.timestamp, block.timestamp + 180 days, "linear");
        assertEq(uint8(s.model), uint8(Lockup.Model.LOCKUP_LINEAR));
        assertEq(s.cliffTime, 0, "no cliff");
        assertEq(s.unlockStart, 0);
        assertEq(s.unlockCliff, 0);
        assertEq(s.granularity, 0, "per second");
        assertEq(lockup.lastValue(), 0, "no ETH sent to Sablier");
        _assertHoldsNothing();
    }

    function test_shape_cliff_unlocksWhatAccruedSinceStart() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.vestingShape = uint8(FlasetDealsV3.Shape.Cliff);
        d.vestingCliff = 30 days;
        _fund(d);
        _settle(d);
        MockSablierLockup.Stream memory s = _common(1, VESTED, block.timestamp, block.timestamp + 180 days, "cliff");
        assertEq(uint8(s.model), uint8(Lockup.Model.LOCKUP_LINEAR));
        assertEq(s.cliffTime, block.timestamp + 30 days);
        assertEq(s.unlockCliff, VESTED * 30 / 180, "one sixth at the cliff, as FlasetVesting's cliff");
        assertEq(s.unlockStart, 0);
        assertEq(s.granularity, 0);
        _assertHoldsNothing();
    }

    function test_shape_steps_sixEqualUnlocks() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.vestingShape = uint8(FlasetDealsV3.Shape.Steps);
        d.vestingSteps = 6;
        _fund(d);
        _settle(d);
        MockSablierLockup.Stream memory s =
            _common(1, VESTED, block.timestamp, block.timestamp + 180 days, "linearStepper");
        assertEq(uint8(s.model), uint8(Lockup.Model.LOCKUP_LINEAR));
        assertEq(s.granularity, 30 days, "one unlock every 30 days");
        assertEq(s.cliffTime, 0);
        assertEq(s.unlockCliff, 0);
        _assertHoldsNothing();
    }

    function test_shape_monthly_calendarMonthsFromTheStart() public {
        vm.warp(1_769_867_110); // 2026-01-31 13:45:10 UTC: a month end, so the clamping shows
        FlasetDealsV3.Deal memory d = _d(ASSET + 5, PAY, 10_000); // 1,000,000e18 + 5: not divisible by 12
        d.vestingShape = uint8(FlasetDealsV3.Shape.Monthly);
        d.vestingDuration = 0;
        d.vestingSteps = 12;
        _fund(d);
        _settle(d);
        // expected (from Python's datetime): 28 Feb, 31 Mar, 30 Apr, ... 31 Jan 2027, all at 13:45:10
        uint40[12] memory want = [
            uint40(1_772_286_310), 1_774_964_710, 1_777_556_710, 1_780_235_110, 1_782_827_110, 1_785_505_510,
            1_788_183_910, 1_790_775_910, 1_793_454_310, 1_796_046_310, 1_798_724_710, 1_801_403_110
        ];
        MockSablierLockup.Stream memory s = _common(1, ASSET + 5, block.timestamp, want[11], "tranchedMonthly");
        assertEq(uint8(s.model), uint8(Lockup.Model.LOCKUP_TRANCHED));
        LockupTranched.Tranche[] memory t = lockup.tranches(1);
        assertEq(t.length, 12);
        uint256 each = (ASSET + 5) / 12;
        for (uint256 i; i < 12; ++i) {
            assertEq(t[i].timestamp, want[i], "month end clamped, counted from the start");
            assertEq(t[i].amount, i < 11 ? each : ASSET + 5 - each * 11, "equal parts, the rest in the last");
        }
        _assertHoldsNothing();
    }

    function test_shape_allAtOnce_oneTrancheAtTheEnd() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 10_000);
        d.vestingShape = uint8(FlasetDealsV3.Shape.AllAtOnce);
        d.vestingDuration = 365 days;
        _fund(d);
        _settle(d);
        MockSablierLockup.Stream memory s =
            _common(1, ASSET, block.timestamp, block.timestamp + 365 days, "tranchedTimelock");
        assertEq(uint8(s.model), uint8(Lockup.Model.LOCKUP_TRANCHED));
        LockupTranched.Tranche[] memory t = lockup.tranches(1);
        assertEq(t.length, 1);
        assertEq(t[0].amount, ASSET, "everything");
        assertEq(t[0].timestamp, block.timestamp + 365 days, "at the end");
        assertEq(projectToken.balanceOf(buyer), 0, "nothing now: 100% locked");
        _assertHoldsNothing();
    }

    function test_explicitStartAndTransferableAreSignedThrough() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.vestingStart = uint64(block.timestamp + 7 days);
        d.vestingTransferable = true;
        _fund(d);
        _settle(d);
        MockSablierLockup.Stream memory s =
            _common(1, VESTED, block.timestamp + 7 days, block.timestamp + 187 days, "linear");
        assertTrue(s.transferable, "the NFT may move: both signed so");
    }

    function test_pastStartIsPassedOnAsSigned() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.vestingStart = uint64(block.timestamp - 30 days);
        _fund(d);
        _settle(d);
        _common(1, VESTED, block.timestamp - 30 days, block.timestamp + 150 days, "linear");
    }

    // ---------------------------------------------------------------- what each shape accepts

    function test_revert_eachShapeTakesOnlyItsOwnFields() public {
        // Linear: a duration, no cliff, no steps
        FlasetDealsV3.Deal memory d = _shape(FlasetDealsV3.Shape.Linear, 0, 180 days, 0);
        _expectSettles(d);
        _expectInvalid(_shape(FlasetDealsV3.Shape.Linear, 0, 0, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Linear, 30 days, 180 days, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Linear, 0, 180 days, 6));
        // Cliff: 0 < cliff < duration, no steps
        _expectSettles(_shape(FlasetDealsV3.Shape.Cliff, 1, 180 days, 0));
        _expectSettles(_shape(FlasetDealsV3.Shape.Cliff, 180 days - 1, 180 days, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Cliff, 0, 180 days, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Cliff, 180 days, 180 days, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Cliff, 30 days, 0, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Cliff, 30 days, 180 days, 6));
        // Steps: 2..48 steps dividing the duration, no cliff
        _expectSettles(_shape(FlasetDealsV3.Shape.Steps, 0, 180 days, 2));
        _expectSettles(_shape(FlasetDealsV3.Shape.Steps, 0, 48 * 7 days, 48));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Steps, 0, 180 days, 1));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Steps, 0, 49 * 7 days, 49));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Steps, 0, 180 days + 1, 6));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Steps, 0, 0, 6));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Steps, 30 days, 180 days, 6));
        // Monthly: 2..48 months, no duration, no cliff
        _expectSettles(_shape(FlasetDealsV3.Shape.Monthly, 0, 0, 2));
        _expectSettles(_shape(FlasetDealsV3.Shape.Monthly, 0, 0, 48));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Monthly, 0, 0, 1));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Monthly, 0, 0, 49));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Monthly, 0, 30 days, 12));
        _expectInvalid(_shape(FlasetDealsV3.Shape.Monthly, 1 days, 0, 12));
        // All at once: a duration, no cliff, no steps
        _expectSettles(_shape(FlasetDealsV3.Shape.AllAtOnce, 0, 1, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.AllAtOnce, 0, 0, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.AllAtOnce, 1, 365 days, 0));
        _expectInvalid(_shape(FlasetDealsV3.Shape.AllAtOnce, 0, 365 days, 2));
        // no sixth shape
        d = _d(ASSET, PAY, 3_000);
        d.vestingShape = 5;
        _expectInvalid(d);
        d.vestingShape = type(uint8).max;
        _expectInvalid(d);
    }

    /// With no vesting the shape fields are not read, as in v1.
    function test_noVestingIgnoresTheShapeFields() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.vestingShape = 9;
        d.vestingCliff = 1;
        d.vestingSteps = 1000;
        _fund(d);
        _settle(d);
        assertEq(projectToken.balanceOf(buyer), ASSET);
        assertEq(lockup.nextStreamId(), 1, "no stream");
    }

    /// A vesting share that rounds to 0 makes no stream, as in v1.
    function test_vestedPartRoundingToZeroMakesNoStream() public {
        FlasetDealsV3.Deal memory d = _d(9_999, PAY, 1); // 9,999 * 1 / 10,000 = 0
        _fund(d);
        _settle(d);
        assertEq(projectToken.balanceOf(buyer), 9_999);
        assertEq(lockup.nextStreamId(), 1);
    }

    function test_revert_monthlyWithFewerUnitsThanMonths() public {
        FlasetDealsV3.Deal memory d = _shape(FlasetDealsV3.Shape.Monthly, 0, 0, 12);
        d.assetAmount = 11;
        d.vestingBps = 10_000;
        _fund(d);
        _expectInvalidSigned(d);
        d.assetAmount = 12; // one unit a month
        d.nonce = 2;
        _fund(d);
        _settle(d);
        assertEq(lockup.tranches(1)[11].amount, 1);
    }

    function test_revert_timesBeyondSabliersUint40() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.vestingStart = uint64(type(uint40).max) - 180 days + 1; // end one second past uint40
        _fund(d);
        _expectInvalidSigned(d);
        d.vestingStart = uint64(type(uint40).max) - 180 days; // end exactly at uint40's last second
        _fund(d);
        _settle(d);
        assertEq(lockup.stream(1).end, type(uint40).max);
        d = _shape(FlasetDealsV3.Shape.Monthly, 0, 0, 2);
        d.vestingStart = uint64(type(uint40).max) - 40 days; // the second month is past uint40
        d.nonce = 3;
        _fund(d);
        _expectInvalidSigned(d);
    }

    function test_revert_vestedPartAboveUint128() public {
        FlasetDealsV3.Deal memory d = _d(uint256(type(uint128).max) + 1, PAY, 10_000);
        _fund(d);
        _expectInvalidSigned(d);
    }

    // ---------------------------------------------------------------- checks after Sablier's create

    function test_revert_lockupPullsLess() public {
        _expectStreamRefused(MockSablierLockup.Mode.PullLess, abi.encodeWithSelector(FlasetDealsV3.InvalidDeal.selector));
    }

    function test_revert_lockupPullsNothing() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.PullNothing, abi.encodeWithSelector(FlasetDealsV3.InvalidDeal.selector)
        );
    }

    function test_revert_lockupSendsTheDepositElsewhere() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.PullElsewhere, abi.encodeWithSelector(FlasetDealsV3.InvalidDeal.selector)
        );
    }

    function test_revert_streamForSomeoneElse() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.WrongRecipient, abi.encodeWithSelector(FlasetDealsV3.StreamMismatch.selector, 1)
        );
    }

    function test_revert_cancelableStream() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.Cancelable, abi.encodeWithSelector(FlasetDealsV3.StreamMismatch.selector, 1)
        );
    }

    function test_revert_streamWithAnotherDeposit() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.WrongDeposit, abi.encodeWithSelector(FlasetDealsV3.StreamMismatch.selector, 1)
        );
    }

    function test_revert_streamWithTheOtherTransferableFlag() public {
        _expectStreamRefused(
            MockSablierLockup.Mode.FlipTransferable, abi.encodeWithSelector(FlasetDealsV3.StreamMismatch.selector, 1)
        );
    }

    /// Each of the three money checks after the create has a case only it catches: dust left here (this test), an
    /// allowance left to Sablier (the next), the deposit not arriving at Sablier (lockupSendsTheDepositElsewhere).
    function test_revert_lockupLeavesDustWithV3() public {
        _expectStreamRefused(MockSablierLockup.Mode.LeaveDust, abi.encodeWithSelector(FlasetDealsV3.InvalidDeal.selector));
    }

    function test_revert_tokenThatKeepsTheAllowance() public {
        StickyAllowanceToken sticky = new StickyAllowanceToken();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.asset = address(sticky);
        sticky.mint(seller, ASSET);
        vm.prank(seller);
        sticky.approve(address(v3), ASSET);
        usdg.mint(buyer, PAY);
        vm.prank(buyer);
        usdg.approve(address(v3), PAY);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_reentryFromTheLockup() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        lockup.setMode(MockSablierLockup.Mode.Reenter);
        lockup.setReenter(abi.encodeCall(FlasetDealsV3.settle, (d, sigS, sigB, noProof)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        v3.settle(d, sigS, sigB, noProof);
    }

    /// A donation sitting in FlasetDealsV3 stays there: the checks compare against what it held before.
    function test_donationBeforeASettleStaysPut() public {
        projectToken.mint(address(v3), 7);
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        _settle(d);
        assertEq(projectToken.balanceOf(address(v3)), 7);
        assertEq(projectToken.balanceOf(address(lockup)), VESTED);
    }

    // ---------------------------------------------------------------- v3's own signature domain

    /// V3 keeps V2's Deal type (the app signs the same struct) and has its own domain: version 3 and its own address.
    function test_v3HasItsOwnTypeAndDomain() public view {
        assertEq(
            v3.DEAL_TYPEHASH(),
            keccak256(
                "Deal(address seller,address buyer,uint8 buyerMode,bytes32 buyersRoot,address asset,uint256 assetAmount,address payToken,uint256 payAmount,uint16 vestingBps,uint8 vestingShape,uint64 vestingStart,uint64 vestingCliff,uint64 vestingDuration,uint16 vestingSteps,bool vestingTransferable,uint256 maxFee,uint64 deadline,uint256 nonce)"
            )
        );
        (, string memory name, string memory version,, address verifying,,) = v3.eip712Domain();
        assertEq(name, "FLASET Deals");
        assertEq(version, "3", "v1 is version 1, v2 version 2");
        assertEq(verifying, address(v3));
    }

    // ---------------------------------------------------------------- v1's tests, on v3

    function test_settle_byRelayer() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.prank(makeAddr("relayer"));
        v3.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
        assertEq(projectToken.balanceOf(buyer), ASSET);
    }

    function test_settle_smartWalletBuyer_erc1271() public {
        uint256 ownerKey = 0x5AFE;
        Erc1271Wallet wallet = new Erc1271Wallet(vm.addr(ownerKey));
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.buyer = address(wallet);
        projectToken.mint(seller, ASSET);
        vm.prank(seller);
        projectToken.approve(address(v3), ASSET);
        usdg.mint(address(wallet), PAY);
        vm.prank(vm.addr(ownerKey));
        wallet.approve(usdg, address(v3), PAY);
        bytes32 digest = v3.hashDeal(d);
        v3.settle(d, _sign(sellerKey, digest), _sign(ownerKey, digest), noProof);
        assertEq(projectToken.balanceOf(address(wallet)), ASSET - VESTED);
        assertEq(lockup.stream(1).recipient, address(wallet), "the stream is the wallet's");
    }

    function test_settle_7702DelegatedEoaSignsWithItsKey() public {
        address delegate = address(new Erc1271Wallet(address(0xdead)));
        vm.etch(buyer, abi.encodePacked(hex"ef0100", delegate));
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        _settle(d);
        assertEq(projectToken.balanceOf(buyer), ASSET);
    }

    function test_revert_smartWalletSignedByWrongKey() public {
        Erc1271Wallet wallet = new Erc1271Wallet(vm.addr(0x5AFE));
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.buyer = address(wallet);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(0xBAD, digest);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, address(wallet)));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_tamperedTerms() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        d.payAmount = PAY / 2;
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, seller));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_signatureFromWrongKey() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, buyer));
        v3.settle(d, _sign(sellerKey, digest), _sign(0xBAD, digest), noProof);
    }

    function test_revert_sellerSignatureReusedForBuyer() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, buyer));
        v3.settle(d, sigS, sigS, noProof);
    }

    function test_revert_emptySignature() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, buyer));
        v3.settle(d, _sign(sellerKey, digest), "", noProof);
    }

    function test_revert_replay() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        v3.settle(d, sigS, sigB, noProof);
        _fund(d);
        vm.expectRevert(FlasetDealsV3.AlreadyConsumed.selector);
        v3.settle(d, sigS, sigB, noProof);
        assertEq(lockup.nextStreamId(), 2, "one stream only");
    }

    function test_revert_expired() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.warp(d.deadline + 1);
        vm.expectRevert(FlasetDealsV3.Expired.selector);
        v3.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
    }

    function test_settle_atDeadlineExactly() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.warp(d.deadline);
        v3.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
    }

    function test_revert_otherChainId() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.chainId(4663);
        assertTrue(v3.hashDeal(d) != digest, "domain binds chain id");
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, seller));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_otherDeployment() public {
        FlasetDealsV3 other =
            new FlasetDealsV3(IFlasetRegistry(address(registry)), ISablierLockup(address(lockup)), admin, treasury);
        vm.prank(admin);
        other.unpause();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, seller));
        other.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
    }

    function test_cancel_bySeller_blocksSettlement() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        vm.prank(seller);
        v3.cancel(d);
        vm.expectRevert(FlasetDealsV3.AlreadyConsumed.selector);
        v3.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
    }

    function test_cancel_byBuyer_twiceRefused() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        vm.prank(buyer);
        bytes32 digest = v3.cancel(d);
        assertTrue(v3.consumed(digest));
        vm.prank(seller);
        vm.expectRevert(FlasetDealsV3.AlreadyConsumed.selector);
        v3.cancel(d);
    }

    function test_revert_cancelByStranger() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FlasetDealsV3.NotAParty.selector);
        v3.cancel(d);
    }

    function test_revert_buyerShortOfFunds_isAtomic() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        vm.prank(buyer);
        usdg.transfer(address(0xdead), 1);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert();
        v3.settle(d, sigS, sigB, noProof);
        assertEq(projectToken.balanceOf(seller), ASSET, "seller kept asset");
        assertEq(usdg.balanceOf(seller), 0, "seller got nothing");
        assertEq(usdg.balanceOf(treasury), 0, "no fee on failure");
        assertFalse(v3.consumed(digest), "deal still open");
        assertEq(lockup.nextStreamId(), 1, "no stream");
    }

    function test_revert_sellerApprovalShortOfTheVestedPart_isAtomic() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        vm.prank(seller);
        projectToken.approve(address(v3), ASSET - 1);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert();
        v3.settle(d, sigS, sigB, noProof);
        assertEq(usdg.balanceOf(buyer), PAY, "buyer kept cash");
        assertEq(projectToken.balanceOf(buyer), 0);
        assertFalse(v3.consumed(digest));
    }

    function test_revert_feeAboveSignedMax() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.maxFee = 19e6;
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.FeeAboveMax.selector, 20e6, 19e6));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_feeRaisedAfterSigning_revertsInsteadOfOvercharging() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.maxFee = 20e6;
        _fund(d);
        vm.prank(admin);
        v3.setFeeBps(50);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.FeeAboveMax.selector, 50e6, 20e6));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_invalidTerms() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.buyer = seller;
        _expectInvalid(d);
        d = _d(ASSET, PAY, 0);
        d.buyer = address(0);
        _expectInvalid(d);
        d = _d(ASSET, PAY, 0);
        d.seller = address(0);
        _expectInvalid(d);
        d = _d(0, PAY, 0);
        _expectInvalid(d);
        d = _d(ASSET, 0, 0);
        _expectInvalid(d);
        d = _d(ASSET, PAY, 10_001);
        _expectInvalid(d);
        d = _d(ASSET, PAY, 0);
        d.buyer = address(v3);
        _expectInvalid(d);
        d = _d(ASSET, PAY, 0);
        d.seller = address(v3);
        _expectInvalid(d);
        d = _d(ASSET, PAY, 0);
        d.payToken = d.asset;
        _expectInvalid(d);
    }

    /// V2 refused these two (TokenNotAllowed): a token nobody listed is sold, and paid with one that is not a settlement
    /// token. On V3 both settle, with the stream.
    function test_settle_assetNobodyListed() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.asset = address(rogue);
        _fund(d);
        _settle(d);
        assertEq(rogue.balanceOf(buyer), ASSET - VESTED);
        assertEq(rogue.balanceOf(address(lockup)), VESTED);
        assertEq(address(lockup.stream(1).token), address(rogue));
    }

    function test_settle_payTokenWithoutSettlementRole() public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.payToken = address(weth);
        _fund(d);
        _settle(d);
        assertEq(weth.balanceOf(seller), PAY - PAY * 20 / 10_000);
        assertEq(weth.balanceOf(treasury), PAY * 20 / 10_000);
        assertEq(v3.feesCollected(address(weth)), PAY * 20 / 10_000);
    }

    /// V2 refused amounts above registry.txCap, and a cap of 0 closed the token. V3 never reads a cap: a cap of 1 unit,
    /// or of 0, changes nothing.
    function test_noCap_capsAreNeverRead() public {
        vm.startPrank(admin);
        registry.setTxCap(address(usdg), 1);
        registry.setTxCap(address(projectToken), 0);
        vm.stopPrank();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        _settle(d);
        assertEq(projectToken.balanceOf(buyer), ASSET - VESTED);
        assertEq(usdg.balanceOf(seller), PAY - PAY * 20 / 10_000);
    }

    function test_revert_feeOnTransferAsset() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.asset = address(fot);
        fot.mint(seller, ASSET);
        vm.prank(seller);
        fot.approve(address(v3), ASSET);
        usdg.mint(buyer, PAY);
        vm.prank(buyer);
        usdg.approve(address(v3), PAY);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExactTransfer.TransferMismatch.selector, address(fot), buyer, ASSET - VESTED, (ASSET - VESTED) * 99 / 100
            )
        );
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_falseReturningPayToken() public {
        FalseReturnToken frt = new FalseReturnToken();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        d.payToken = address(frt);
        projectToken.mint(seller, ASSET);
        vm.prank(seller);
        projectToken.approve(address(v3), ASSET);
        frt.mint(buyer, PAY);
        vm.prank(buyer);
        frt.approve(address(v3), PAY);
        frt.setFail(true);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(frt)));
        v3.settle(d, sigS, sigB, noProof);
    }

    function test_revert_reentryThroughTokenHook() public {
        HookToken hook = new HookToken();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        d.asset = address(hook);
        hook.mint(seller, ASSET);
        vm.prank(seller);
        hook.approve(address(v3), ASSET);
        usdg.mint(buyer, PAY);
        vm.prank(buyer);
        usdg.approve(address(v3), PAY);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        hook.setHook(address(v3), abi.encodeCall(FlasetDealsV3.settle, (d, sigS, sigB, noProof)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        v3.settle(d, sigS, sigB, noProof);
    }

    // ---------------------------------------------------------------- admin

    function test_startsPausedUntilTheOwnerUnpauses() public {
        FlasetDealsV3 fresh =
            new FlasetDealsV3(IFlasetRegistry(address(registry)), ISablierLockup(address(lockup)), admin, treasury);
        assertTrue(fresh.paused(), "paused from the constructor on");
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fresh.settle(d, "", "", noProof);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        fresh.unpause();
        vm.prank(admin);
        fresh.unpause();
        assertFalse(fresh.paused());
        assertEq(address(fresh.lockup()), address(lockup));
        assertEq(address(fresh.registry()), address(registry));
        assertEq(fresh.feeRecipient(), treasury);
        assertEq(fresh.owner(), admin);
        assertEq(fresh.feeBps(), 20);
    }

    function test_revert_constructorZeroAddresses() public {
        IFlasetRegistry r = IFlasetRegistry(address(registry));
        ISablierLockup l = ISablierLockup(address(lockup));
        vm.expectRevert(FlasetDealsV3.ZeroAddress.selector);
        this.deployV3(IFlasetRegistry(address(0)), l, admin, treasury);
        vm.expectRevert(FlasetDealsV3.ZeroAddress.selector);
        this.deployV3(r, ISablierLockup(address(0)), admin, treasury);
        vm.expectRevert(FlasetDealsV3.ZeroAddress.selector);
        this.deployV3(r, l, admin, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        this.deployV3(r, l, address(0), treasury);
    }

    /// Each refused creation in its own external call, so the lines after an expected revert still run.
    function deployV3(IFlasetRegistry r, ISablierLockup l, address o, address f) external returns (FlasetDealsV3) {
        return new FlasetDealsV3(r, l, o, f);
    }

    function test_pause_keyPausesOnlyTheOwnerUnpauses() public {
        address key = makeAddr("pauseKey");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        v3.setPauser(key);
        vm.prank(admin);
        v3.setPauser(key);
        assertEq(v3.pauser(), key);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FlasetDealsV3.NotPauser.selector);
        v3.pause();
        vm.prank(key);
        v3.pause();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        v3.settle(d, sigS, sigB, noProof);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, key));
        v3.unpause();
        vm.prank(admin);
        v3.unpause();
        v3.settle(d, sigS, sigB, noProof);
        vm.prank(admin);
        v3.pause(); // the owner can always pause
        assertTrue(v3.paused());
    }

    function test_admin_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        v3.setFeeBps(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        v3.setFeeRecipient(address(this));
        vm.startPrank(admin);
        vm.expectRevert(FlasetDealsV3.FeeTooHigh.selector);
        v3.setFeeBps(101);
        v3.setFeeBps(100);
        assertEq(v3.feeBps(), 100);
        vm.expectRevert(FlasetDealsV3.ZeroAddress.selector);
        v3.setFeeRecipient(address(0));
        v3.setFeeRecipient(makeAddr("newTreasury"));
        vm.expectRevert(FlasetDealsV3.RenounceDisabled.selector);
        v3.renounceOwnership();
        vm.stopPrank();
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 0);
        _fund(d);
        _settle(d);
        assertEq(usdg.balanceOf(makeAddr("newTreasury")), PAY / 100, "the new recipient gets the fee");
    }

    function test_ownershipMovesInTwoSteps() public {
        address next = makeAddr("next");
        vm.prank(admin);
        v3.transferOwnership(next);
        assertEq(v3.owner(), admin, "still the old owner");
        assertEq(v3.pendingOwner(), next);
        vm.prank(next);
        v3.acceptOwnership();
        assertEq(v3.owner(), next);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_settle_conservesValue(uint256 payAmount, uint256 assetAmount, uint16 vestingBps, uint8 shape)
        public
    {
        payAmount = bound(payAmount, 1, 1e15);
        assetAmount = bound(assetAmount, 48, 1e33);
        vestingBps = uint16(bound(vestingBps, 0, 10_000));
        FlasetDealsV3.Deal memory d = _shape(FlasetDealsV3.Shape(bound(shape, 0, 4)), 0, 0, 0);
        _fill(d);
        d.assetAmount = assetAmount;
        d.payAmount = payAmount;
        d.vestingBps = vestingBps;
        d.maxFee = payAmount;
        if (d.vestingShape == uint8(FlasetDealsV3.Shape.Monthly) && assetAmount * vestingBps / 10_000 < 12) {
            d.vestingBps = 0;
        }
        _fund(d);
        _settle(d);

        uint256 vested = assetAmount * d.vestingBps / 10_000;
        uint256 fee = usdg.balanceOf(treasury);
        assertLe(fee * 10_000, payAmount * 100, "fee in range");
        assertEq(usdg.balanceOf(seller) + fee, payAmount, "cash conserved");
        assertEq(projectToken.balanceOf(buyer) + projectToken.balanceOf(address(lockup)), assetAmount, "asset conserved");
        assertEq(projectToken.balanceOf(address(lockup)), vested, "the stream holds the vested share");
        if (vested > 0) assertEq(lockup.stream(1).deposited, vested);
        _assertHoldsNothing();
    }

    function testFuzz_revert_anyTamperedField(uint8 field, uint256 delta) public {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        delta = bound(delta, 1, 1e6);
        field = uint8(bound(field, 0, 11));
        if (field == 0) d.assetAmount -= delta;
        else if (field == 1) d.payAmount -= delta;
        else if (field == 2) d.vestingBps -= uint16(bound(delta, 1, 3_000));
        else if (field == 3) d.maxFee += delta;
        else if (field == 4) d.deadline += uint64(delta);
        else if (field == 5) d.nonce += delta;
        else if (field == 6) d.vestingShape = uint8(FlasetDealsV3.Shape.AllAtOnce);
        else if (field == 7) d.vestingStart += uint64(delta);
        else if (field == 8) d.vestingDuration += uint64(delta);
        else if (field == 9) d.vestingTransferable = true;
        else if (field == 10) (d.vestingShape, d.vestingCliff) = (uint8(FlasetDealsV3.Shape.Cliff), uint64(delta));
        else (d.vestingShape, d.vestingSteps) = (uint8(FlasetDealsV3.Shape.Steps), 2);
        if (field == 11) d.vestingDuration = 180 days;
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, seller));
        v3.settle(d, sigS, sigB, noProof);
    }

    // ---------------------------------------------------------------- helpers

    function _d(uint256 assetAmount, uint256 payAmount, uint16 vestingBps)
        internal
        view
        returns (FlasetDealsV3.Deal memory d)
    {
        d = FlasetDealsV3.Deal({
            seller: seller,
            buyer: buyer,
            buyerMode: uint8(FlasetDealsV3.BuyerMode.OneWallet),
            buyersRoot: bytes32(0),
            asset: address(projectToken),
            assetAmount: assetAmount,
            payToken: address(usdg),
            payAmount: payAmount,
            vestingBps: vestingBps,
            vestingShape: uint8(FlasetDealsV3.Shape.Linear),
            vestingStart: 0,
            vestingCliff: 0,
            vestingDuration: vestingBps > 0 ? 180 days : 0,
            vestingSteps: 0,
            vestingTransferable: false,
            maxFee: payAmount / 100,
            deadline: uint64(block.timestamp + 1 hours),
            nonce: 1
        });
    }

    /// A 30% deal of one shape with the given cliff, duration and steps; unique nonce per combination.
    function _shape(FlasetDealsV3.Shape s, uint64 cliff, uint64 duration, uint16 steps)
        internal
        view
        returns (FlasetDealsV3.Deal memory d)
    {
        d = _d(ASSET, PAY, 3_000);
        d.vestingShape = uint8(s);
        d.vestingCliff = cliff;
        d.vestingDuration = duration;
        d.vestingSteps = steps;
        d.nonce = uint256(keccak256(abi.encode(s, cliff, duration, steps)));
    }

    /// Valid shape fields for a shape picked by a fuzzer.
    function _fill(FlasetDealsV3.Deal memory d) internal pure {
        FlasetDealsV3.Shape s = FlasetDealsV3.Shape(d.vestingShape);
        d.vestingDuration = s == FlasetDealsV3.Shape.Monthly ? 0 : 360 days;
        if (s == FlasetDealsV3.Shape.Cliff) d.vestingCliff = 90 days;
        if (s == FlasetDealsV3.Shape.Steps || s == FlasetDealsV3.Shape.Monthly) d.vestingSteps = 12;
    }

    function _fund(FlasetDealsV3.Deal memory d) internal {
        MockERC20(d.asset).mint(d.seller, d.assetAmount);
        MockERC20(d.payToken).mint(d.buyer, d.payAmount);
        vm.prank(d.seller);
        MockERC20(d.asset).approve(address(v3), d.assetAmount);
        vm.prank(d.buyer);
        MockERC20(d.payToken).approve(address(v3), d.payAmount);
    }

    function _settle(FlasetDealsV3.Deal memory d) internal returns (bytes32) {
        bytes32 digest = v3.hashDeal(d);
        return v3.settle(d, _sign(sellerKey, digest), _sign(buyerKey, digest), noProof);
    }

    /// The fields every stream shares, asserted against the mock's record of stream `id`.
    function _common(uint256 id, uint256 deposit, uint256 start, uint256 end, string memory shape)
        internal
        view
        returns (MockSablierLockup.Stream memory s)
    {
        s = lockup.stream(id);
        assertEq(s.sender, address(v3), "sender: FlasetDealsV3");
        assertEq(s.recipient, buyer, "recipient: the buyer");
        assertEq(s.deposited, deposit, "deposit: the vested part");
        assertEq(address(s.token), address(projectToken), "token: the asset");
        assertFalse(s.cancelable, "never cancelable");
        assertEq(s.start, start, "start");
        assertEq(s.end, end, "end");
        assertEq(s.shape, shape, "Sablier's shape id");
    }

    function _expectInvalid(FlasetDealsV3.Deal memory d) internal {
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(d, "", "", noProof);
    }

    /// For checks that run after the signatures: a fully signed and funded deal.
    function _expectInvalidSigned(FlasetDealsV3.Deal memory d) internal {
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(d, sigS, sigB, noProof);
    }

    function _expectSettles(FlasetDealsV3.Deal memory d) internal {
        _fund(d);
        uint256 id = lockup.nextStreamId();
        _settle(d);
        assertEq(lockup.nextStreamId(), id + 1, "one stream");
        assertEq(lockup.stream(id).deposited, VESTED);
    }

    function _expectStreamRefused(MockSablierLockup.Mode mode, bytes memory err) internal {
        FlasetDealsV3.Deal memory d = _d(ASSET, PAY, 3_000);
        _fund(d);
        bytes32 digest = v3.hashDeal(d);
        bytes memory sigS = _sign(sellerKey, digest);
        bytes memory sigB = _sign(buyerKey, digest);
        lockup.setMode(mode);
        vm.expectRevert(err);
        v3.settle(d, sigS, sigB, noProof);
        assertEq(projectToken.balanceOf(seller), ASSET, "the seller keeps everything");
        assertEq(usdg.balanceOf(buyer), PAY, "the buyer keeps the cash");
        assertFalse(v3.consumed(digest), "the deal stays open");
    }

    function _assertHoldsNothing() internal view {
        assertEq(usdg.balanceOf(address(v3)), 0, "v3 holds no cash");
        assertEq(projectToken.balanceOf(address(v3)), 0, "v3 holds no asset");
        assertEq(projectToken.allowance(address(v3), address(lockup)), 0, "no allowance left to Sablier");
    }
}
