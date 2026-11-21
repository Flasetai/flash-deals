# Security policy

## Report a vulnerability

Write to **security@flaset.com**.

Include what you found, how to reproduce it and what an attacker could do with it.

## In scope

- The contracts in `src/`, as deployed at the addresses in the [README](README.md#deployments).
- A deal settled on terms the seller or the buyer did not sign, or any part of it sent to another address.
- A deal settled twice, a signature replayed on another chain or deployment, or a whitelist deal taken by a wallet off
  the list.
- A settlement that lands halfway, leaves tokens or an allowance in `FlasetDeals`, or charges more than the signed
  `maxFee`.
- A vesting stream that differs from the signed terms or that anyone can cancel.
- The owner or the pause key moving a party's tokens or touching a stream.

## Out of scope

- Sniping an Anyone deal. The first valid taker wins by design.
- Sablier's own contracts and the keys that control them. Report those to Sablier.
- A token that misbehaves on its own, such as one that pauses, freezes or charges a fee on transfer. The deal reverts.
- Outages of the explorers, Sourcify or the RPC nodes.

## Rules for testing

Test on a fork or a test network, never against other people's deals or funds on mainnet. Never ask anyone for a seed
phrase or a private key.

We reply as fast as we can and credit reporters who want credit.
