# Cardano MPFS Onchain

Aiken validators for
[Merkle Patricia Forestry](https://github.com/aiken-lang/merkle-patricia-forestry)
on Cardano (Plutus V3).

The on-chain component defines a **cage** pattern: an NFT locked at
a script address carries the current MPF root hash as its datum.
Modifications are verified on-chain via cryptographic proofs.

## Documentation

- [Architecture Overview](architecture/overview.md) — system diagram, transaction lifecycle, protocol flow
- [Validators](architecture/validators.md) — minting policy and spending validator logic
- [Types & Encodings](architecture/types.md) — datum, redeemer, and operation structures
- [Proof System](architecture/proofs.md) — MPF proof format, verification, and performance
