<p align="center">
  <img src="./assets/flash-deals-banner.png" alt="An orange sphere with three small ones in orbit, drawn in sand." width="100%">
</p>

# flash-deals

**Flash Deals sells a token for payment in one atomic transaction.**

The seller and the buyer sign the same terms. One `settle` call then moves the price, the fee and the tokens. If any
part fails, the call reverts.

This repository holds the deployed Solidity source of `FlasetDeals`, the `FlasetRegistry` it reads, and their tests.

[Docs](https://flaset.ai/docs/deals/) | [Security model](https://flaset.ai/docs/security/)

## How a deal settles

1. The seller signs the Deal. It sets the asset, the price, who may buy, the vesting, a deadline and the highest fee
   the seller accepts (`maxFee`).
2. The buyer approves the exact price to `FlasetDeals` and signs the same Deal with its own address.
3. Anyone can send `settle` and pays the gas. The signatures fix every term, so the sender cannot change what moves
   or where.
4. The contract checks the terms, both signatures and the fee, and marks the deal used. The seller gets the price minus
   the fee and the fee recipient gets the fee. The buyer gets the immediate share, and the vested share goes into a
   vesting stream for the buyer.

Every transfer is checked against the receiver's balance, and a different amount reverts. A fee-on-transfer token
reverts the deal.

On either side, `FlasetDeals` takes any ERC-20 with code that the registry has not blocked. Signatures are EIP-712
and count only on `FlasetDeals` on its own chain.

## Who may buy

The seller picks the mode and signs it. Everything goes to the address the buyer signs with. A deal settles once.

| Mode | Who can take it | Who can cancel |
|---|---|---|
| 0 One wallet | The wallet the seller named | The seller or that wallet |
| 1 Whitelist | The first wallet on the seller's list to settle, with its Merkle proof | The seller |
| 2 Anyone | The first wallet to settle | The seller |

An Anyone deal goes to whoever settles first, a bot included. Until it settles, a deal can be cancelled for good, also
while Flash Deals is paused.

## The vested share

The vested share goes into a stream on Sablier's Lockup contract, minted as an NFT to the buyer with
`cancelable: false`. Nobody can cancel it, the owner included.

## The fee

The fee is 0.20% of the price, from the seller's side, in the pay token: `fee = payAmount * feeBps / 10000`, rounded
down. The owner sets `feeBps`, which the contract reads at settlement, and a fee change never exceeds a signed
`maxFee`.

## What the owner can do

The owner sets the fee and can pause new settlements. It cannot touch a stream, move a party's tokens or change a
signed deal.

No contract here has a proxy, an upgrade function or a self-destruct. `renounceOwnership` reverts, and `FlasetDeals`
starts paused.

## Deployments

| Chain | Contract | Address | Sourcify |
|---|---|---|---|
| Robinhood Chain | `FlasetDeals` | [`0x2c5224c5e456B9E1CeE0E6F1ffF8106Cd383e449`](https://robin.etherscan.io/address/0x2c5224c5e456B9E1CeE0E6F1ffF8106Cd383e449#code) | [Exact match](https://repo.sourcify.dev/4663/0x2c5224c5e456B9E1CeE0E6F1ffF8106Cd383e449) |
| Base | `FlasetDeals` | [`0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58`](https://basescan.org/address/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) | [Exact match](https://repo.sourcify.dev/8453/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) |
| BNB Chain | `FlasetDeals` | [`0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58`](https://bscscan.com/address/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) | [Exact match](https://repo.sourcify.dev/56/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) |
| Ethereum | `FlasetDeals` | [`0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58`](https://etherscan.io/address/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) | [Exact match](https://repo.sourcify.dev/1/0x0Aed92C2AAc63e8dd1f325a0Ca3EbE78cceb0F58) |
| Robinhood Chain | `FlasetRegistry` | [`0xb41a45AEE32806061DDe1341249170BE3559FB8c`](https://robin.etherscan.io/address/0xb41a45AEE32806061DDe1341249170BE3559FB8c#code) | [Exact match](https://repo.sourcify.dev/4663/0xb41a45AEE32806061DDe1341249170BE3559FB8c) |
| Base | `FlasetRegistry` | [`0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A`](https://basescan.org/address/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A#code) | [Exact match](https://repo.sourcify.dev/8453/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A) |
| BNB Chain | `FlasetRegistry` | [`0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A`](https://bscscan.com/address/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A#code) | [Exact match](https://repo.sourcify.dev/56/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A) |
| Ethereum | `FlasetRegistry` | [`0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A`](https://etherscan.io/address/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A#code) | [Exact match](https://repo.sourcify.dev/1/0x8fbB95d5c5f4612B4E8376133508F47BB875Af2A) |

## Verification

Every file in `src/` and `lib/` that these contracts compile from is identical to the source verified on
[Sourcify](https://sourcify.dev), apart from the licence line at the top of each file in `src/`. Every deployment is
an exact match there, for both the creation and the runtime code. The explorers show an exact match too, except for
`FlasetDeals` on Base, BNB Chain and Ethereum, which is verified on Sourcify only.

A `forge build` here compiles to the deployed code apart from the metadata hash at its end, because the deploy build
listed more remappings in its settings.

## Build and test

You need [Foundry](https://getfoundry.sh). The libraries are git submodules, pinned to the commits the deployed
contracts were built with.

```sh
git clone --recurse-submodules <this repository>
cd flash-deals
forge build
forge test
```

`forge test` runs 80 tests in two suites, against a stand-in for the Lockup contract. They cover every guard, the
buyer modes, each vesting shape and odd tokens.

## Security

Report a vulnerability to **security@flaset.com**.
See [SECURITY.md](SECURITY.md).

## Links

[Website](https://flaset.ai) | [Docs](https://flaset.ai/docs/) | [X](https://x.com/flasetai) | [Telegram](https://t.me/flasetportal)

## License

[Business Source License 1.1](LICENSE), with no Additional Use Grant. Four years after publication, each version
changes to the GNU General Public License v2.0 or later.
