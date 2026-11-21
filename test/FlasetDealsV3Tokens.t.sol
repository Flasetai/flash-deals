// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {FlasetTestBase} from "./utils/FlasetTestBase.sol";
import {FlasetDealsV3} from "../src/FlasetDealsV3.sol";
import {ExactTransfer} from "../src/libraries/ExactTransfer.sol";
import {IFlasetRegistry} from "../src/interfaces/IFlasetRegistry.sol";
import {ISablierLockup} from "../src/interfaces/ISablierLockup.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSablierLockup} from "./utils/MockSablierLockup.sol";
import {FeeOnTransferToken, SwitchableFeeToken} from "./utils/QuirkTokens.sol";
import {
    FeeIntoToken, SharesToken, ElasticToken, NoBoolToken, HookCaller, CallbackToken, OddNft
} from "./utils/OddTokens.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice FlasetDealsV3 takes any ERC-20 on either side, with no registry flag and no cap, as Sablier's Lockup does.
/// This suite: tokens nobody listed, the block list, addresses without code, and the odd tokens of
/// Sablier's own assumptions (fee on transfer, rebasing, no bool, callbacks), a lookalike, odd decimals, a huge supply
/// and an NFT. Every odd token either settles exactly as signed or reverts as a whole; none leaves a stream short.
contract FlasetDealsV3TokensTest is FlasetTestBase {
    uint256 constant PAY = 10_000e6;
    uint256 constant ASSET = 1_000_000e18;

    FlasetDealsV3 internal v3;
    MockSablierLockup internal lockup;
    bytes32[] internal noProof;

    function setUp() public override {
        super.setUp();
        lockup = new MockSablierLockup();
        v3 = new FlasetDealsV3(IFlasetRegistry(address(registry)), ISablierLockup(address(lockup)), admin, treasury);
        vm.prank(admin);
        v3.unpause();
        vm.label(address(v3), "FlasetDealsV3");
        vm.label(address(lockup), "MockSablierLockup");
    }

    // ---------------------------------------------------------------- any token, no flag, no cap

    /// Two tokens nobody ever listed or capped, as the asset and the price, in each of the five shapes.
    function test_anyToken_bothSidesNobodyListed_everyShape() public {
        for (uint8 s; s < 5; ++s) {
            MockERC20 a = new MockERC20("Fresh Asset", "FRA", 18);
            MockERC20 p = new MockERC20("Fresh Pay", "FRP", 8);
            assertEq(registry.tokenFlags(address(a)) | registry.tokenFlags(address(p)), 0, "never listed");
            assertEq(registry.txCap(address(a)) + registry.txCap(address(p)), 0, "never capped");
            FlasetDealsV3.Deal memory d = _deal(address(a), ASSET, address(p), 5e8, 3_000);
            _shape(d, s);
            d.nonce = s;
            _fundAndSettle(d);
            uint256 vested = ASSET * 3_000 / 10_000;
            assertEq(a.balanceOf(buyer), ASSET - vested, "the immediate part");
            assertEq(a.balanceOf(address(lockup)), vested, "the stream holds the vested part");
            assertEq(address(lockup.stream(s + 1).token), address(a), "the stream's token");
            assertEq(lockup.stream(s + 1).deposited, vested);
            assertEq(p.balanceOf(seller), 5e8 - 5e8 * 20 / 10_000, "the price minus the fee");
            _assertHoldsNothing(address(a), address(p));
        }
    }

    /// The roles V2 fixed per token no longer exist: the settlement stablecoin is sold, paid in the project token.
    function test_anyToken_rolesSwapped() public {
        FlasetDealsV3.Deal memory d = _deal(address(usdg), PAY, address(projectToken), ASSET, 5_000);
        _fundAndSettle(d);
        assertEq(usdg.balanceOf(buyer), PAY / 2);
        assertEq(usdg.balanceOf(address(lockup)), PAY / 2);
        assertEq(projectToken.balanceOf(seller), ASSET - ASSET * 20 / 10_000);
        assertEq(v3.feesCollected(address(projectToken)), ASSET * 20 / 10_000);
    }

    // ---------------------------------------------------------------- the block list: default open, one-way

    /// The registry's owner blocks one token: it is refused on either side, before any signature is read, and every
    /// other token stays open. A block is for good: the registry refuses flags and caps for it from then on.
    function test_revert_blockedToken_eitherSide_othersStayOpen() public {
        MockERC20 bad = new MockERC20("Bad", "BAD", 18);
        vm.prank(admin);
        registry.blockToken(address(bad));
        FlasetDealsV3.Deal memory d = _deal(address(bad), ASSET, address(usdg), PAY, 0);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, address(bad)));
        v3.settle(d, "", "", noProof);
        d = _deal(address(projectToken), ASSET, address(bad), PAY, 0);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, address(bad)));
        v3.settle(d, "", "", noProof);
        // the rest of the world is unaffected
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        _fundAndSettle(_deal(address(other), ASSET, address(usdg), PAY, 3_000));
        // and the block cannot be lifted
        vm.startPrank(admin);
        vm.expectRevert();
        registry.setTokenFlags(address(bad), 0);
        vm.stopPrank();
    }

    /// A blocked token is refused even with both signatures, the funds and the approvals in place.
    function test_revert_blockedAfterSigning() public {
        FlasetDealsV3.Deal memory d = _deal(address(projectToken), ASSET, address(usdg), PAY, 3_000);
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        vm.prank(admin);
        registry.blockToken(address(projectToken));
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, address(projectToken)));
        v3.settle(d, sigS, sigB, noProof);
    }

    /// An address without code is no token: a wallet, a typo or a precompile, on either side, refused by name before
    /// any signature is read (a token call to it would fail with no reason).
    function test_revert_noCode_eitherSide() public {
        address[3] memory nothing = [makeAddr("a wallet"), address(0x04), address(0xdeadbeef)];
        for (uint256 i; i < 3; ++i) {
            FlasetDealsV3.Deal memory d = _deal(nothing[i], ASSET, address(usdg), PAY, 0);
            vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, nothing[i]));
            v3.settle(d, "", "", noProof);
            d = _deal(address(projectToken), ASSET, nothing[i], PAY, 0);
            vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, nothing[i]));
            v3.settle(d, "", "", noProof);
        }
    }

    // ---------------------------------------------------------------- fees on transfer

    /// A fee on every transfer, as the price: the seller's leg arrives short and the whole deal reverts.
    function test_revert_feeOnTransfer_payToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        FlasetDealsV3.Deal memory d = _deal(address(projectToken), ASSET, address(fot), PAY, 3_000);
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        uint256 net = PAY - PAY * 20 / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(ExactTransfer.TransferMismatch.selector, address(fot), seller, net, net * 99 / 100)
        );
        v3.settle(d, sigS, sigB, noProof);
    }

    /// A fee only on transfers into Sablier's Lockup: every leg to the parties is exact, Lockup records the full deposit
    /// without measuring it, and only V3's check of Lockup's balance sees the stream arrive short.
    function test_revert_feeOnlyIntoLockup() public {
        FeeIntoToken t = new FeeIntoToken();
        t.setFee(address(lockup), 100);
        FlasetDealsV3.Deal memory d = _deal(address(t), ASSET, address(usdg), PAY, 3_000);
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(d, sigS, sigB, noProof);
        assertFalse(v3.consumed(v3.hashDeal(d)), "the deal stays open");
        // the same token with nothing vested never touches Lockup and settles exactly
        d.vestingBps = 0;
        d.vestingDuration = 0;
        _fundAndSettle(d);
        assertEq(t.balanceOf(buyer), ASSET);
    }

    // ---------------------------------------------------------------- balances that move on their own

    /// stETH-style shares: at a rate that is not 1, a transfer delivers a wei less, and the deal reverts. The numbers
    /// are checked in Python: the immediate part of 700,000e18 + 1 arrives as 700,000e18.
    function test_revert_sharesToken_roundsAWeiShort() public {
        SharesToken t = new SharesToken();
        t.mint(seller, 3 * ASSET);
        t.accrue(ASSET / 7 + 13); // rewards: the rate is no longer 1
        FlasetDealsV3.Deal memory d = _deal(address(t), ASSET + 1, address(usdg), PAY, 3_000);
        _approve(address(t), seller, ASSET + 1);
        usdg.mint(buyer, PAY);
        _approve(address(usdg), buyer, PAY);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        uint256 now_ = ASSET + 1 - (ASSET + 1) * 3_000 / 10_000;
        vm.expectRevert(abi.encodeWithSelector(ExactTransfer.TransferMismatch.selector, address(t), buyer, now_, now_ - 1));
        v3.settle(d, sigS, sigB, noProof);
    }

    /// AMPL-style: every transfer is exact, so the deal settles and the stream holds exactly its deposit. A rebase
    /// afterwards moves Lockup's balance and not the stream's books: no check at settlement can see it, it is the
    /// token's own risk (Sablier's assumption), and the app warns against vesting such a token.
    function test_elasticToken_exactAtSettlement_aLaterRebaseIsTheTokens() public {
        ElasticToken t = new ElasticToken();
        uint256 amount = 1_000_000e9;
        FlasetDealsV3.Deal memory d = _deal(address(t), amount, address(usdg), PAY, 3_000);
        _fundAndSettle(d);
        uint256 vested = amount * 3_000 / 10_000;
        assertEq(t.balanceOf(address(lockup)), vested, "exact at creation");
        assertEq(lockup.stream(1).deposited, vested);
        t.rebase(9, 10); // -10%
        assertLt(t.balanceOf(address(lockup)), lockup.stream(1).deposited, "a later rebase leaves Lockup's books short");
    }

    // ---------------------------------------------------------------- non-standard interfaces

    /// USDT-style, returning no bool and refusing an approval from non-zero to non-zero, on both sides (SafeERC20).
    function test_noBoolToken_bothSides() public {
        NoBoolToken a = new NoBoolToken();
        NoBoolToken p = new NoBoolToken();
        FlasetDealsV3.Deal memory d = _deal(address(a), 5e12, address(p), 7e9, 0);
        _fundAndSettle(d);
        assertEq(a.balanceOf(buyer), 5e12);
        assertEq(p.balanceOf(seller), 7e9 - 7e9 * 20 / 10_000);
        assertEq(p.balanceOf(treasury), 7e9 * 20 / 10_000);
    }

    // ---------------------------------------------------------------- callbacks (ERC-777 style)

    /// Hooks that only run: the deal settles as signed.
    function test_callbackToken_quietHooksSettle() public {
        CallbackToken t = new CallbackToken();
        _registerHook(t, seller);
        _registerHook(t, buyer);
        FlasetDealsV3.Deal memory d = _deal(address(t), ASSET, address(usdg), PAY, 3_000);
        _fundAndSettle(d);
        assertGt(t.hooksRun(), 0, "the hooks ran");
        assertEq(t.balanceOf(address(lockup)), ASSET * 3_000 / 10_000);
    }

    /// The buyer's receive hook settles another deal from inside this one: the reentrancy guard refuses it.
    function test_revert_callbackToken_hookReentersSettle() public {
        CallbackToken t = new CallbackToken();
        HookCaller h = _registerHook(t, buyer);
        FlasetDealsV3.Deal memory d = _deal(address(t), ASSET, address(usdg), PAY, 3_000);
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        FlasetDealsV3.Deal memory other = _deal(address(projectToken), ASSET, address(usdg), PAY, 0);
        other.nonce = 2;
        _fund(other);
        (bytes memory oS, bytes memory oB) = _sigs(other);
        h.arm(address(v3), abi.encodeCall(v3.settle, (other, oS, oB, noProof)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        v3.settle(d, sigS, sigB, noProof);
    }

    /// The seller's send hook donates to V3 while V3 pulls the vested part: V3's receipt is measured, so the deal
    /// reverts instead of letting extra tokens through to Lockup or leaving them behind.
    function test_revert_callbackToken_hookMovesTokensMidStream() public {
        CallbackToken t = new CallbackToken();
        HookCaller h = _registerHook(t, seller);
        FlasetDealsV3.Deal memory d = _deal(address(t), ASSET, address(usdg), PAY, 10_000); // the first seller move is the pull
        _fund(d);
        t.mint(address(h), 5);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        h.arm(address(t), abi.encodeCall(t.transfer, (address(v3), 5)));
        vm.expectRevert(
            abi.encodeWithSelector(ExactTransfer.TransferMismatch.selector, address(t), address(v3), ASSET, ASSET + 5)
        );
        v3.settle(d, sigS, sigB, noProof);
    }

    // ---------------------------------------------------------------- a lookalike

    /// A token with USDG's name, symbol and decimals at another address. V3 reads addresses only: a deal signed for the
    /// real USDG never settles with the lookalike, and a deal signed for the lookalike pays in the lookalike.
    function test_lookalike_settlesAsItselfNeverAsTheRealOne() public {
        MockERC20 fake = new MockERC20(usdg.name(), usdg.symbol(), usdg.decimals());
        assertEq(fake.symbol(), usdg.symbol());
        FlasetDealsV3.Deal memory real = _deal(address(projectToken), ASSET, address(usdg), PAY, 0);
        (bytes memory sigS, bytes memory sigB) = _sigs(real);
        FlasetDealsV3.Deal memory swapped = abi.decode(abi.encode(real), (FlasetDealsV3.Deal));
        swapped.payToken = address(fake);
        _fund(swapped);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.BadSignature.selector, seller));
        v3.settle(swapped, sigS, sigB, noProof);
        // signed for the lookalike: the seller gets the lookalike, never real USDG
        _fundAndSettle(swapped);
        assertEq(fake.balanceOf(seller), PAY - PAY * 20 / 10_000);
        assertEq(usdg.balanceOf(seller), 0);
        assertEq(v3.feesCollected(address(usdg)), 0);
    }

    // ---------------------------------------------------------------- decimals and sizes

    /// Decimals 0, 2, 6 and 24 on either side: the contract never reads decimals. The fee rounds down as in V2 (a price
    /// under 500 units of a 0-decimal token pays no fee at 20 bps), and a Monthly share under its steps is refused.
    function test_oddDecimals() public {
        uint8[4] memory decs = [0, 2, 6, 24];
        for (uint256 i; i < 4; ++i) {
            MockERC20 a = new MockERC20("A", "A", decs[i]);
            MockERC20 p = new MockERC20("P", "P", decs[3 - i]);
            FlasetDealsV3.Deal memory d = _deal(address(a), 1_000 * uint256(10) ** decs[i], address(p), 499, 3_000);
            d.nonce = i;
            _fundAndSettle(d);
            assertEq(p.balanceOf(seller), 499, "499 units pay no fee at 20 bps");
            assertEq(a.balanceOf(address(lockup)), 300 * uint256(10) ** decs[i]);
        }
        MockERC20 zero = new MockERC20("Z", "Z", 0);
        FlasetDealsV3.Deal memory m = _deal(address(zero), 40, address(usdg), PAY, 3_000); // 12 vested units
        m.vestingShape = uint8(FlasetDealsV3.Shape.Monthly);
        (m.vestingDuration, m.vestingSteps) = (0, 13);
        _fund(m);
        (bytes memory sigS, bytes memory sigB) = _sigs(m);
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(m, sigS, sigB, noProof);
    }

    /// A supply past uint128 (outside Sablier's assumption): a vested part above uint128 is refused as in V2, and the
    /// same amount with nothing vested settles. A price whose fee overflows reverts.
    function test_hugeAmounts() public {
        MockERC20 huge = new MockERC20("Huge", "HUGE", 18);
        uint256 amount = uint256(type(uint128).max) + 1;
        FlasetDealsV3.Deal memory d = _deal(address(huge), amount, address(usdg), PAY, 10_000);
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        vm.expectRevert(FlasetDealsV3.InvalidDeal.selector);
        v3.settle(d, sigS, sigB, noProof);
        d.vestingBps = 0;
        d.vestingDuration = 0;
        _fundAndSettle(d);
        assertEq(huge.balanceOf(buyer), amount);
        FlasetDealsV3.Deal memory f = _deal(address(projectToken), ASSET, address(huge), type(uint256).max, 0);
        f.maxFee = type(uint256).max;
        (sigS, sigB) = _sigs(f);
        vm.expectRevert(stdError.arithmeticError);
        v3.settle(f, sigS, sigB, noProof);
    }

    /// An NFT collection named as a token: its transferFrom moves the id given as the amount, and the receiver's balance
    /// grows by 1. So only "amount 1, nothing vested" moves anything (NFT #1, as the seller signed); any other amount
    /// reverts with TransferMismatch, and a vested part reverts too (an NFT has no allowance, so it never reaches Lockup).
    function test_nftAsToken() public {
        OddNft nft = new OddNft();
        nft.mint(seller, 1);
        nft.mint(seller, 2);
        vm.prank(seller);
        nft.setApprovalForAll(address(v3), true);
        usdg.mint(buyer, 3 * PAY);
        _approve(address(usdg), buyer, 3 * PAY);
        FlasetDealsV3.Deal memory d = _deal(address(nft), 2, address(usdg), PAY, 0);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        vm.expectRevert(abi.encodeWithSelector(ExactTransfer.TransferMismatch.selector, address(nft), buyer, 2, 1));
        v3.settle(d, sigS, sigB, noProof);
        d = _deal(address(nft), 2, address(usdg), PAY, 5_000); // 1 now, 1 vested
        d.nonce = 2;
        (sigS, sigB) = _sigs(d);
        vm.expectRevert();
        v3.settle(d, sigS, sigB, noProof);
        d = _deal(address(nft), 1, address(usdg), PAY, 0);
        d.nonce = 3;
        (sigS, sigB) = _sigs(d);
        v3.settle(d, sigS, sigB, noProof);
        assertEq(nft.ownerOf(1), buyer, "NFT #1, as signed");
        assertEq(nft.ownerOf(2), seller);
    }

    // ---------------------------------------------------------------- fuzz

    /// Any decimals (0-36), any amounts and shares, any shape, on two fresh tokens: value is conserved, the stream holds
    /// exactly the vested part, and V3 holds nothing.
    function testFuzz_anyTokens_conserveValue(
        uint8 decA,
        uint8 decP,
        uint256 assetAmount,
        uint256 payAmount,
        uint16 vestingBps,
        uint8 shape
    ) public {
        MockERC20 a = new MockERC20("A", "A", uint8(bound(decA, 0, 36)));
        MockERC20 p = new MockERC20("P", "P", uint8(bound(decP, 0, 36)));
        assetAmount = bound(assetAmount, 48, type(uint128).max);
        payAmount = bound(payAmount, 1, type(uint256).max / 100);
        vestingBps = uint16(bound(vestingBps, 0, 10_000));
        FlasetDealsV3.Deal memory d = _deal(address(a), assetAmount, address(p), payAmount, vestingBps);
        _shape(d, uint8(bound(shape, 0, 4)));
        uint256 vested = assetAmount * vestingBps / 10_000;
        if (d.vestingShape == uint8(FlasetDealsV3.Shape.Monthly) && vested < 12) {
            (d.vestingBps, vested) = (0, 0);
        }
        d.maxFee = payAmount;
        _fundAndSettle(d);
        uint256 fee = payAmount * 20 / 10_000;
        assertEq(p.balanceOf(seller), payAmount - fee, "seller");
        assertEq(p.balanceOf(treasury), fee, "fee");
        assertEq(a.balanceOf(buyer), assetAmount - vested, "the immediate part");
        assertEq(a.balanceOf(address(lockup)), vested, "the stream");
        if (vested > 0) assertEq(lockup.stream(1).deposited, vested);
        else assertEq(lockup.nextStreamId(), 1, "no stream");
        _assertHoldsNothing(address(a), address(p));
    }

    /// A token with a fee of any size on any leg (every transfer, the price, or only into Lockup): the deal settles only
    /// when no leg is charged, and then exactly as signed; otherwise it reverts as a whole and stays open.
    function testFuzz_feeTokens_neverSettleShort(uint16 feeBps, uint8 side, uint256 assetAmount, uint16 vestingBps)
        public
    {
        feeBps = uint16(bound(feeBps, 1, 10_000));
        side = side % 3;
        assetAmount = bound(assetAmount, 1, 1e24);
        vestingBps = uint16(bound(vestingBps, 0, 10_000));
        uint256 payAmount = bound(uint256(keccak256(abi.encode(assetAmount))), 1, 1e24);
        address token;
        bool charged;
        uint256 vested = assetAmount * vestingBps / 10_000;
        if (side == 2) {
            FeeIntoToken t = new FeeIntoToken();
            t.setFee(address(lockup), feeBps);
            token = address(t);
            charged = vested * feeBps / 10_000 > 0;
        } else {
            SwitchableFeeToken t = new SwitchableFeeToken();
            t.setFee(feeBps);
            token = address(t);
            uint256 fee = payAmount * 20 / 10_000;
            charged = side == 0
                ? (assetAmount - vested) * feeBps / 10_000 > 0 || vested * feeBps / 10_000 > 0
                : (payAmount - fee) * feeBps / 10_000 > 0 || fee * feeBps / 10_000 > 0;
        }
        FlasetDealsV3.Deal memory d = side == 1
            ? _deal(address(projectToken), assetAmount, token, payAmount, vestingBps)
            : _deal(token, assetAmount, address(usdg), payAmount, vestingBps);
        d.maxFee = payAmount;
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        (bool ok, bytes memory ret) = address(v3).call(abi.encodeCall(v3.settle, (d, sigS, sigB, noProof)));
        assertEq(ok, !charged, "settles exactly when no leg is charged");
        if (ok) {
            assertEq(IERC20Like(d.asset).balanceOf(buyer), assetAmount - vested, "exact immediate part");
            assertEq(IERC20Like(d.asset).balanceOf(address(lockup)), vested, "exact stream");
            assertEq(IERC20Like(d.payToken).balanceOf(seller), payAmount - payAmount * 20 / 10_000, "exact price");
        } else {
            bytes4 sel = bytes4(ret);
            assertTrue(
                sel == ExactTransfer.TransferMismatch.selector || sel == FlasetDealsV3.InvalidDeal.selector,
                "a measured refusal"
            );
            assertFalse(v3.consumed(v3.hashDeal(d)), "the deal stays open");
        }
    }

    /// A blocked token is refused on whichever side it is, whatever the rest of the deal says.
    function testFuzz_blockedTokenAlwaysRefused(bool assetSide, uint256 assetAmount, uint256 payAmount, uint16 bps)
        public
    {
        MockERC20 bad = new MockERC20("Bad", "BAD", 18);
        vm.prank(admin);
        registry.blockToken(address(bad));
        FlasetDealsV3.Deal memory d = assetSide
            ? _deal(address(bad), bound(assetAmount, 1, 1e30), address(usdg), bound(payAmount, 1, 1e30), 0)
            : _deal(address(projectToken), bound(assetAmount, 1, 1e30), address(bad), bound(payAmount, 1, 1e30), 0);
        d.vestingBps = uint16(bound(bps, 0, 10_000));
        d.vestingDuration = d.vestingBps > 0 ? 180 days : 0;
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        vm.expectRevert(abi.encodeWithSelector(FlasetDealsV3.TokenNotAllowed.selector, address(bad)));
        v3.settle(d, sigS, sigB, noProof);
    }

    // ---------------------------------------------------------------- helpers

    /// A OneWallet deal; Linear over 180 days when something vests.
    function _deal(address asset, uint256 assetAmount, address payToken, uint256 payAmount, uint16 vestingBps)
        internal
        view
        returns (FlasetDealsV3.Deal memory d)
    {
        d = FlasetDealsV3.Deal({
            seller: seller,
            buyer: buyer,
            buyerMode: uint8(FlasetDealsV3.BuyerMode.OneWallet),
            buyersRoot: bytes32(0),
            asset: asset,
            assetAmount: assetAmount,
            payToken: payToken,
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

    function _shape(FlasetDealsV3.Deal memory d, uint8 s) internal pure {
        d.vestingShape = s;
        if (d.vestingBps == 0) return;
        d.vestingDuration = s == uint8(FlasetDealsV3.Shape.Monthly) ? 0 : 360 days;
        d.vestingCliff = s == uint8(FlasetDealsV3.Shape.Cliff) ? 90 days : 0;
        d.vestingSteps = s == uint8(FlasetDealsV3.Shape.Steps) || s == uint8(FlasetDealsV3.Shape.Monthly) ? 12 : 0;
    }

    function _sigs(FlasetDealsV3.Deal memory d) internal view returns (bytes memory sigS, bytes memory sigB) {
        bytes32 digest = v3.hashDeal(d);
        (sigS, sigB) = (_sign(sellerKey, digest), _sign(buyerKey, digest));
    }

    /// Mints both sides and approves V3 exactly; works for tokens that return no bool.
    function _fund(FlasetDealsV3.Deal memory d) internal {
        IMintable(d.asset).mint(d.seller, d.assetAmount);
        IMintable(d.payToken).mint(d.buyer, d.payAmount);
        _approve(d.asset, d.seller, d.assetAmount);
        _approve(d.payToken, d.buyer, d.payAmount);
    }

    function _fundAndSettle(FlasetDealsV3.Deal memory d) internal {
        _fund(d);
        (bytes memory sigS, bytes memory sigB) = _sigs(d);
        v3.settle(d, sigS, sigB, noProof);
    }

    function _approve(address token, address owner, uint256 amount) internal {
        vm.startPrank(owner);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(v3), 0));
        (bool ok2,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(v3), amount));
        vm.stopPrank();
        require(ok && ok2, "approve");
    }

    function _registerHook(CallbackToken t, address account) internal returns (HookCaller h) {
        h = new HookCaller();
        vm.prank(account);
        t.registerHook(h);
    }

    function _assertHoldsNothing(address a, address p) internal view {
        assertEq(IERC20Like(a).balanceOf(address(v3)) + IERC20Like(p).balanceOf(address(v3)), 0, "V3 holds nothing");
        assertEq(IERC20Like(a).allowance(address(v3), address(lockup)), 0, "no allowance left to Sablier");
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}
