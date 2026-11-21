// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Odd ERC-20s for FlasetDealsV3, which takes any token. Each one breaks one of Sablier's token
/// assumptions (evm-monorepo SECURITY.md) or the ERC-20 interface in its own way.

/// @notice Takes a fee only on transfers to one address (for example Sablier's Lockup), so every leg to the parties is
/// exact and only the stream's deposit arrives short.
contract FeeIntoToken is ERC20 {
    address public feeTarget;
    uint256 public feeBps;

    constructor() ERC20("Fee Into", "FINTO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(address target, uint256 bps) external {
        (feeTarget, feeBps) = (target, bps);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != feeTarget || from == address(0) || feeBps == 0) return super._update(from, to, value);
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0xFEE), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice stETH-style: balances are shares times a rate that is not 1, and a transfer moves the shares the amount is
/// worth, rounded down, so the receiver can get one wei less than was sent.
contract SharesToken {
    string public constant name = "Shares Token";
    string public constant symbol = "SHR";
    uint8 public constant decimals = 18;
    uint256 public totalShares;
    uint256 public pooled; // what all shares are worth
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        uint256 shares = totalShares == 0 ? amount : amount * totalShares / pooled;
        totalShares += shares;
        pooled += amount;
        sharesOf[to] += shares;
    }

    /// @notice Rewards: every balance grows, as stETH's daily rebase does.
    function accrue(uint256 amount) external {
        pooled += amount;
    }

    function balanceOf(address a) public view returns (uint256) {
        return totalShares == 0 ? 0 : sharesOf[a] * pooled / totalShares;
    }

    function totalSupply() external view returns (uint256) {
        return pooled;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 shares = amount * totalShares / pooled;
        require(sharesOf[from] >= shares, "balance");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
    }
}

/// @notice AMPL-style: every transfer is exact, and the issuer can rebase every balance at once (up or down) without a
/// transfer. Nothing at settlement can tell it from a plain token.
contract ElasticToken {
    string public constant name = "Elastic Token";
    string public constant symbol = "ELS";
    uint8 public constant decimals = 9;
    uint256 internal constant GONS_PER_UNIT_START = 1e12;
    uint256 public gonsPerUnit = GONS_PER_UNIT_START;
    uint256 internal totalGons;
    mapping(address => uint256) internal gons;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        gons[to] += amount * gonsPerUnit;
        totalGons += amount * gonsPerUnit;
    }

    /// @notice Every balance times `num / den`; a negative rebase for num < den.
    function rebase(uint256 num, uint256 den) external {
        gonsPerUnit = gonsPerUnit * den / num;
    }

    function balanceOf(address a) public view returns (uint256) {
        return gons[a] / gonsPerUnit;
    }

    function totalSupply() external view returns (uint256) {
        return totalGons / gonsPerUnit;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 g = amount * gonsPerUnit;
        require(gons[from] >= g, "balance");
        gons[from] -= g;
        gons[to] += g;
    }
}

/// @notice USDT-style: transfer, transferFrom and approve return nothing, and approve refuses to move one non-zero
/// allowance to another.
contract NoBoolToken {
    string public constant name = "No Bool";
    string public constant symbol = "NOB";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "approve from non-zero");
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "balance or allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice What an ERC-777-style hook may run: `call` is made from the hook, during the transfer.
contract HookCaller {
    address public target;
    bytes public call;
    bool public armed;

    function arm(address target_, bytes calldata call_) external {
        (target, call, armed) = (target_, call_, true);
    }

    function run() external {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = target.call(call);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @notice ERC-777-style callbacks on a plain ERC-20 interface: before every move it calls the sender's registered hook
/// (tokensToSend), and after it the receiver's (tokensReceived). Each account registers its own hook, as with ERC-1820.
contract CallbackToken is ERC20 {
    mapping(address account => HookCaller) public hookOf;
    uint256 public hooksRun;

    constructor() ERC20("Callback Token", "CB777") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function registerHook(HookCaller hook) external {
        hookOf[msg.sender] = hook;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && address(hookOf[from]) != address(0)) {
            ++hooksRun;
            hookOf[from].run();
        }
        super._update(from, to, value);
        if (to != address(0) && address(hookOf[to]) != address(0)) {
            ++hooksRun;
            hookOf[to].run();
        }
    }
}

/// @notice An NFT collection: ERC-721's transferFrom(address,address,uint256) and balanceOf(address) have the ERC-20
/// selectors, so it can be named as a deal's token.
contract OddNft is ERC721 {
    constructor() ERC721("Some NFT", "NFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
