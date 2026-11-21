// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Accepts an ECDSA signature by the signer's own key, or else an ERC-1271 signature.
/// OpenZeppelin's SignatureChecker only tries ERC-1271 once an address has code, and an EOA with an
/// EIP-7702 delegation has code (0xef0100 || delegate). Robinhood Chain runs 7702: on mainnet such
/// accounts exist today, and their plain wallet signatures would be refused. The key behind an EOA
/// controls it whatever it delegates to, so its ECDSA signature stays valid. A contract account has
/// no key that recovers to its address, so trying ECDSA first never lets anyone sign for one.
library SigCheck {
    function isValid(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length > 0 && SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }
}
