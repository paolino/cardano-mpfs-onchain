# Cardano MPFS Onchain

Aiken validators for
[Merkle Patricia Forestry](https://github.com/aiken-lang/merkle-patricia-forestry)
on Cardano (Plutus V3).

This repository contains the on-chain component of the
[MPFS project](https://github.com/cardano-foundation/mpfs)
by the Cardano Foundation. The validators were originally developed in
[`on_chain/`](https://github.com/cardano-foundation/mpfs/tree/main/on_chain)
of that repository.

The on-chain component defines a **cage** pattern: an NFT locked at
a script address carries the current MPF root hash as its datum.
Modifications are verified on-chain via cryptographic proofs.
Time-gated phases prevent race conditions between the oracle and
requesters, and a Reject mechanism enables DDoS protection.

## Documentation

- [Development](development.md) — building, dev shell, justfile recipes
- [Architecture Overview](architecture/overview.md) — system diagram, transaction lifecycle, protocol flow
- [Validators](architecture/validators.md) — minting policy and spending validator logic
- [Types & Encodings](architecture/types.md) — datum, redeemer, and operation structures
- [Proof System](architecture/proofs.md) — MPF proof format, verification, and performance
- [Security Properties](architecture/properties.md) — 16 categories verified by 67 tests
