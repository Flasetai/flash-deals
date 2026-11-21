// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SigCheck} from "./libraries/SigCheck.sol";
import {ExactTransfer} from "./libraries/ExactTransfer.sol";
import {CalendarMonths} from "./libraries/CalendarMonths.sol";
import {IFlasetRegistry} from "./interfaces/IFlasetRegistry.sol";
import {ISablierLockup, Lockup, LockupLinear, LockupTranched} from "./interfaces/ISablierLockup.sol";

/// @title FlasetDealsV3
/// @notice Two-party atomic OTC settlement of any ERC-20 against any ERC-20. Seller and buyer sign the same EIP-712
/// Deal; anyone may submit both signatures. In one transaction the buyer pays `payAmount` of the pay token, the seller
/// delivers `assetAmount` of the asset, `vestingBps` of it becomes a Sablier Lockup stream for the buyer, and the
/// protocol fee is taken from the seller's proceeds. Any failure reverts all of it. The contract never holds funds
/// between transactions.
/// @dev FlasetDealsV2 with one change: no token needs a registry flag and no amount is capped, as on Sablier. A token
/// is refused only when it has no code or the registry's owner blocked it (one-way). Every leg is measured on the
/// receiver's balance and the stream on Lockup's, so a token that moves another amount (a fee on transfer, rounding,
/// a hook that skims) reverts the deal instead of settling it short. What no check at settlement can see stays the
/// token's own risk, as Sablier assumes: a balance that changes later without a transfer (rebasing, interest-bearing,
/// an issuer burn), a fee switched on later, callbacks, two entry points. The app warns before anyone signs.
/// The stream's recipient is the buyer and nobody can cancel it; this contract is its sender and has no
/// function that touches it after creation.
/// The seller also signs who may buy (`BuyerMode`). For a whitelist or anyone the seller signs the deal with buyer 0,
/// and the buyer who takes it signs the same deal with its own address as buyer; everything goes to that buyer.
contract FlasetDealsV3 is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ExactTransfer for IERC20;

    /// @notice Who may take a deal: the seller picks it, and it is signed into the Deal.
    enum BuyerMode {
        OneWallet, // `buyer` is the one wallet the seller named, as in v1
        Whitelist, // any wallet in the Merkle tree `buyersRoot`; the first to settle takes the deal
        Anyone // any wallet; the first to settle takes the deal, so a bot that sees it can take it first
    }

    /// @notice How the vested part unlocks, and the Sablier stream each shape becomes.
    enum Shape {
        Linear, // Lockup Linear from start to start + vestingDuration
        Cliff, // Lockup Linear with a cliff at start + vestingCliff, which unlocks what accrued since start
        Steps, // Lockup Linear in vestingSteps equal unlocks, one every vestingDuration / vestingSteps
        Monthly, // Lockup Tranched: vestingSteps equal unlocks, on the start's day of each following month
        AllAtOnce // Lockup Tranched: everything unlocks at start + vestingDuration
    }

    struct Deal {
        address seller;
        address buyer; // who takes the deal; 0 in the seller's signature for Whitelist and Anyone
        uint8 buyerMode; // a BuyerMode
        bytes32 buyersRoot; // Whitelist only: the Merkle root of the allowed wallets; 0 otherwise
        address asset;
        uint256 assetAmount;
        address payToken;
        uint256 payAmount;
        uint16 vestingBps; // share of assetAmount that becomes a Sablier stream, 0..10000
        uint8 vestingShape; // a Shape
        uint64 vestingStart; // 0 = the settlement block's timestamp
        uint64 vestingCliff; // Cliff only: seconds after start; 0 for every other shape
        uint64 vestingDuration; // seconds after start until fully vested; 0 for Monthly
        uint16 vestingSteps; // Steps and Monthly: the number of unlocks, 2..MAX_STEPS; 0 otherwise
        bool vestingTransferable; // whether the buyer may move the stream NFT to another wallet
        uint256 maxFee; // highest protocol fee, in payToken, both sides accept
        uint64 deadline; // last timestamp at which the deal can settle
        uint256 nonce; // makes each deal unique; consumed on settle or cancel
    }

    bytes32 public constant DEAL_TYPEHASH = keccak256(
        "Deal(address seller,address buyer,uint8 buyerMode,bytes32 buyersRoot,address asset,uint256 assetAmount,"
        "address payToken,uint256 payAmount,uint16 vestingBps,uint8 vestingShape,uint64 vestingStart,"
        "uint64 vestingCliff,uint64 vestingDuration,uint16 vestingSteps,bool vestingTransferable,uint256 maxFee,"
        "uint64 deadline,uint256 nonce)"
    );
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100; // hard ceiling: 1%
    uint16 public constant MAX_STEPS = 48; // at most 48 unlocks: four years of months

    IFlasetRegistry public immutable registry;
    ISablierLockup public immutable lockup;
    uint16 public feeBps = 20; // 0.20%
    address public feeRecipient;
    /// @notice A fast key that can only pause. Unpausing, and every other setting, stays with the owner.
    address public pauser;

    /// @notice Deal digests that settled or were cancelled.
    mapping(bytes32 digest => bool) public consumed;
    /// @notice Protocol fees taken per pay token, for reconciliation against the fee recipient.
    mapping(address token => uint256) public feesCollected;

    event DealSettled(
        bytes32 indexed digest,
        address indexed seller,
        address indexed buyer,
        address asset,
        uint256 assetAmount,
        uint256 vestedAmount,
        uint256 streamId,
        address payToken,
        uint256 payAmount,
        uint256 fee
    );
    event DealCancelled(bytes32 indexed digest, address indexed by);
    event FeeSet(uint16 feeBps);
    event FeeRecipientSet(address feeRecipient);
    event PauserSet(address pauser);

    error Expired();
    error InvalidDeal();
    error TokenNotAllowed(address token);
    error AlreadyConsumed();
    error BadSignature(address signer);
    error FeeAboveMax(uint256 fee, uint256 maxFee);
    error NotAParty();
    error NotPauser();
    error RenounceDisabled();
    error FeeTooHigh();
    error ZeroAddress();
    error StreamMismatch(uint256 streamId);
    error NotWhitelisted(address buyer);

    /// @notice Starts paused: nothing settles until the owner has checked the deployment and unpaused.
    constructor(IFlasetRegistry registry_, ISablierLockup lockup_, address owner_, address feeRecipient_)
        EIP712("FLASET Deals", "3")
        Ownable(owner_)
    {
        if (address(registry_) == address(0) || address(lockup_) == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        lockup = lockup_;
        feeRecipient = feeRecipient_;
        _pause();
    }

    // ---------------------------------------------------------------- views

    /// @notice The digest the buyer signs: the deal with its own address as buyer. In OneWallet mode the seller signs
    /// the same; for Whitelist and Anyone the seller signs it with buyer 0.
    function hashDeal(Deal calldata d) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(DEAL_TYPEHASH, d)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function quoteFee(uint256 payAmount) public view returns (uint256) {
        return payAmount * feeBps / BPS;
    }

    // ---------------------------------------------------------------- settlement

    /// @param d the deal with `buyer` = the wallet that takes it
    /// @param proof Whitelist only: the Merkle proof that `d.buyer` is in `d.buyersRoot`
    /// @return digest the seller's digest, which this settle consumes
    function settle(
        Deal calldata d,
        bytes calldata sellerSig,
        bytes calldata buyerSig,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused returns (bytes32 digest) {
        _validate(d);
        if (
            d.buyerMode == uint8(BuyerMode.Whitelist)
                && !MerkleProof.verifyCalldata(proof, d.buyersRoot, _leaf(d.buyer))
        ) {
            revert NotWhitelisted(d.buyer);
        }
        digest = _sellerDigest(d);
        if (consumed[digest]) revert AlreadyConsumed();
        if (!SigCheck.isValid(d.seller, digest, sellerSig)) revert BadSignature(d.seller);
        if (!SigCheck.isValid(d.buyer, hashDeal(d), buyerSig)) revert BadSignature(d.buyer);

        uint256 fee = quoteFee(d.payAmount);
        if (fee > d.maxFee) revert FeeAboveMax(fee, d.maxFee);

        uint256 vestedAmount = d.assetAmount * d.vestingBps / BPS;
        uint256 immediate = d.assetAmount - vestedAmount;

        // Effects before any token call.
        consumed[digest] = true;
        feesCollected[d.payToken] += fee;

        // Cash leg: buyer -> seller (net of fee) and buyer -> fee recipient.
        IERC20 payToken = IERC20(d.payToken);
        payToken.pullExact(d.buyer, d.seller, d.payAmount - fee);
        payToken.pullExact(d.buyer, feeRecipient, fee);

        // Asset leg: seller -> buyer now, the rest into a Sablier stream for the buyer.
        IERC20(d.asset).pullExact(d.seller, d.buyer, immediate);
        uint256 streamId = vestedAmount > 0 ? _fundStream(d, vestedAmount) : 0;

        _emitSettled(digest, d, vestedAmount, streamId, fee);
    }

    function _fundStream(Deal calldata d, uint256 vestedAmount) internal returns (uint256 streamId) {
        if (vestedAmount > type(uint128).max) revert InvalidDeal();
        IERC20 asset = IERC20(d.asset);
        uint256 held = asset.balanceOf(address(this));
        uint256 inLockup = asset.balanceOf(address(lockup));
        asset.pullExact(d.seller, address(this), vestedAmount);
        asset.forceApprove(address(lockup), vestedAmount);
        streamId = _createStream(d, vestedAmount);
        // Sablier pulled exactly vestedAmount into its own balance; nothing stays behind, no allowance lingers.
        if (
            asset.balanceOf(address(this)) != held || asset.allowance(address(this), address(lockup)) != 0
                || asset.balanceOf(address(lockup)) != inLockup + vestedAmount
        ) {
            revert InvalidDeal();
        }
        // The stream is the buyer's, holds exactly the vested part, can never be cancelled, and can move to another
        // wallet only when both parties signed so.
        if (
            lockup.getRecipient(streamId) != d.buyer || lockup.getDepositedAmount(streamId) != vestedAmount
                || lockup.isCancelable(streamId) || lockup.isTransferable(streamId) != d.vestingTransferable
        ) {
            revert StreamMismatch(streamId);
        }
    }

    /// @dev One Sablier stream per shape: Linear, Cliff and Steps are Lockup Linear, Monthly and AllAtOnce are Lockup
    /// Tranched. The shape names are the Shape IDs Sablier's app draws.
    function _createStream(Deal calldata d, uint256 vestedAmount) internal returns (uint256) {
        uint256 start = d.vestingStart == 0 ? block.timestamp : d.vestingStart;
        Shape shape = Shape(d.vestingShape);
        if (shape == Shape.Monthly) {
            uint256 n = d.vestingSteps;
            uint128 each = uint128(vestedAmount / n);
            if (each == 0) revert InvalidDeal();
            LockupTranched.Tranche[] memory tranches = new LockupTranched.Tranche[](n);
            for (uint256 i; i < n; ++i) {
                tranches[i] = LockupTranched.Tranche(each, _u40(CalendarMonths.add(start, i + 1)));
            }
            tranches[n - 1].amount = uint128(vestedAmount - uint256(each) * (n - 1));
            return lockup.createWithTimestampsLT(
                _streamParams(d, vestedAmount, start, tranches[n - 1].timestamp, "tranchedMonthly"), tranches
            );
        }
        uint256 end = _u40(start + d.vestingDuration);
        if (shape == Shape.AllAtOnce) {
            LockupTranched.Tranche[] memory one = new LockupTranched.Tranche[](1);
            one[0] = LockupTranched.Tranche(uint128(vestedAmount), uint40(end));
            return lockup.createWithTimestampsLT(_streamParams(d, vestedAmount, start, end, "tranchedTimelock"), one);
        }
        uint40 cliffTime;
        uint128 cliffUnlock;
        uint40 granularity;
        string memory name = "linear";
        if (shape == Shape.Cliff) {
            cliffTime = uint40(start + d.vestingCliff); // below end, so it fits
            cliffUnlock = uint128(vestedAmount * d.vestingCliff / d.vestingDuration); // what accrued since start
            name = "cliff";
        } else if (shape == Shape.Steps) {
            granularity = uint40(d.vestingDuration / d.vestingSteps); // below end, so it fits
            name = "linearStepper";
        }
        return lockup.createWithTimestampsLL(
            _streamParams(d, vestedAmount, start, end, name),
            LockupLinear.UnlockAmounts(0, cliffUnlock),
            granularity,
            cliffTime
        );
    }

    /// @dev What every stream shares. Virtual only so the fork tests can plant defects in a harness; nothing in
    /// production overrides it.
    function _streamParams(Deal calldata d, uint256 vestedAmount, uint256 start, uint256 end, string memory shape)
        internal
        view
        virtual
        returns (Lockup.CreateWithTimestamps memory)
    {
        return Lockup.CreateWithTimestamps({
            sender: address(this),
            recipient: d.buyer,
            depositAmount: uint128(vestedAmount),
            token: IERC20(d.asset),
            cancelable: false,
            transferable: d.vestingTransferable,
            timestamps: Lockup.Timestamps(_u40(start), _u40(end)),
            shape: shape
        });
    }

    function _emitSettled(bytes32 digest, Deal calldata d, uint256 vestedAmount, uint256 streamId, uint256 fee)
        internal
    {
        emit DealSettled(
            digest, d.seller, d.buyer, d.asset, d.assetAmount, vestedAmount, streamId, d.payToken, d.payAmount, fee
        );
    }

    /// @notice The seller can kill a signed deal before it settles, in every mode; so can the buyer of a OneWallet deal.
    /// A Whitelist or Anyone deal is the seller's alone to cancel: anyone else could otherwise kill it for everyone.
    function cancel(Deal calldata d) external returns (bytes32 digest) {
        if (msg.sender != d.seller && (msg.sender != d.buyer || d.buyerMode != uint8(BuyerMode.OneWallet))) {
            revert NotAParty();
        }
        digest = _sellerDigest(d);
        if (consumed[digest]) revert AlreadyConsumed();
        consumed[digest] = true;
        emit DealCancelled(digest, msg.sender);
    }

    // ---------------------------------------------------------------- admin (owner = the registry's owner, his wallet)

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    /// @param pauser_ zero removes the pause key; the owner can always pause
    function setPauser(address pauser_) external onlyOwner {
        pauser = pauser_;
        emit PauserSet(pauser_);
    }

    function pause() external {
        if (msg.sender != pauser && msg.sender != owner()) revert NotPauser();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Ownership can move (in two steps) but never be renounced: a paused module without an owner
    /// could never be unpaused.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- internal

    function _validate(Deal calldata d) internal view {
        if (block.timestamp > d.deadline) revert Expired();
        if (d.seller == address(0) || d.buyer == address(0) || d.seller == d.buyer) revert InvalidDeal();
        if (d.seller == address(this) || d.buyer == address(this)) revert InvalidDeal();
        // Three modes, and only a whitelist carries a root.
        if (
            d.buyerMode > uint8(BuyerMode.Anyone)
                || (d.buyerMode == uint8(BuyerMode.Whitelist)) != (d.buyersRoot != 0)
        ) {
            revert InvalidDeal();
        }
        if (d.assetAmount == 0 || d.payAmount == 0 || d.asset == d.payToken) revert InvalidDeal();
        if (d.vestingBps > BPS) revert InvalidDeal();
        if (d.vestingBps > 0 && !_validSchedule(d)) revert InvalidDeal();
        _checkToken(d.asset);
        _checkToken(d.payToken);
    }

    /// @dev Any ERC-20 may take either side. Refused: an address without code (a wallet, a typo, a precompile), where a
    /// token call would fail without a reason, and a token the registry's owner blocked, which stays blocked for good.
    function _checkToken(address token) internal view {
        if (token.code.length == 0 || registry.isBlocked(token)) revert TokenNotAllowed(token);
    }

    /// @dev Each shape takes exactly the fields it needs; its other vesting fields must be 0.
    function _validSchedule(Deal calldata d) internal pure returns (bool) {
        uint256 shape = d.vestingShape;
        bool steps = d.vestingSteps >= 2 && d.vestingSteps <= MAX_STEPS;
        if (shape == uint8(Shape.Monthly)) return d.vestingDuration == 0 && d.vestingCliff == 0 && steps;
        if (d.vestingDuration == 0) return false;
        if (shape == uint8(Shape.Linear) || shape == uint8(Shape.AllAtOnce)) {
            return d.vestingCliff == 0 && d.vestingSteps == 0;
        }
        if (shape == uint8(Shape.Cliff)) {
            return d.vestingCliff > 0 && d.vestingCliff < d.vestingDuration && d.vestingSteps == 0;
        }
        if (shape == uint8(Shape.Steps)) {
            return d.vestingCliff == 0 && steps && d.vestingDuration % d.vestingSteps == 0;
        }
        return false;
    }

    /// @dev The digest the seller signs, and the key `consumed` marks. For Whitelist and Anyone the seller cannot know
    /// who will buy, so it signs the deal with buyer 0, whatever buyer the caller filled in.
    function _sellerDigest(Deal calldata d) internal view returns (bytes32) {
        if (d.buyerMode == uint8(BuyerMode.OneWallet)) return hashDeal(d);
        Deal memory offer = d;
        offer.buyer = address(0);
        return _hashTypedDataV4(keccak256(abi.encode(DEAL_TYPEHASH, offer)));
    }

    /// @dev A leaf of OpenZeppelin's StandardMerkleTree of ["address"]: the address, ABI-encoded and hashed twice.
    function _leaf(address buyer) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(buyer))));
    }

    function _u40(uint256 t) internal pure returns (uint40) {
        if (t > type(uint40).max) revert InvalidDeal();
        return uint40(t);
    }
}
