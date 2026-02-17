# Security Properties

This page documents the on-chain security properties of the MPF Cage
validators. Each property is stated as an invariant and cross-referenced
with the test(s) that verify it.

The properties are derived from the
[upstream MPFS specification](https://cardano-foundation.github.io/mpfs/)
([architecture](https://cardano-foundation.github.io/mpfs/architecture/),
[on-chain code docs](https://cardano-foundation.github.io/mpfs/code/on-chain/))
and verified by the inline test suite in
[`cage.ak`](https://github.com/cardano-foundation/cardano-mpfs-onchain/blob/main/validators/cage.ak)
and
[`lib.ak`](https://github.com/cardano-foundation/cardano-mpfs-onchain/blob/main/validators/lib.ak).
Run `aiken check` (or `just test`) to check all 67 tests.

---

## Roles

The upstream MPFS documentation defines three roles:

- **Oracle** (token owner): controls which facts are added or removed
  from an MPF token. Maps to the `State.owner` field.
- **Requester**: proposes fact changes via `RequestDatum` UTxOs. Maps
  to `Request.requestOwner`.
- **Observer**: reads the MPF state from the blockchain. No on-chain
  role; all knowledge is reconstructable from the chain history.

The on-chain validators enforce the boundaries between these roles.

---

## On-chain vs Off-chain Guarantees

The validators enforce **what must hold on-chain**. Some guarantees
depend on off-chain behaviour:

| Guarantee | Enforced by |
|---|---|
| Token identity is unique | On-chain (UTxO consumption) |
| Only the oracle can update the MPF root | On-chain (signature check) |
| Every modification carries a valid Merkle proof | On-chain (proof verification) |
| Output root matches proof computation | On-chain (fold + compare) |
| Token stays at the script address | On-chain (address check) |
| Requesters can reclaim locked ADA in Phase 2 | On-chain (Retract + phase check) |
| Expired requests are cleaned up | On-chain (Reject + phase check) |
| Oracle fees are enforced | On-chain (fee == max_fee check) |
| Refunds are paid correctly | On-chain (verifyRefunds) |
| Time phases are exclusive | On-chain (validity_range checks) |
| The oracle honestly processes matching requests | Off-chain (oracle behaviour) |
| Proofs are computed against the correct trie state | Off-chain (proof generation) |
| All knowledge is reconstructable from history | Blockchain (ledger property) |

---

## 1. Token Uniqueness

> *Upstream: "The new token-id is unique"*

**Invariant:** Two distinct `OutputReference` values always produce
different token asset names.

The asset name is `SHA2-256(tx_id ++ output_index)`. Since an
`OutputReference` can only be consumed once, the minting policy
guarantees that no two tokens share the same identity.

| Property | Test | File |
|---|---|---|
| Same reference yields same hash (deterministic) | `assetName_deterministic` | `lib.ak` |
| Different `tx_id` yields different hash | `assetName_different_txid` | `lib.ak` |
| Different `output_index` yields different hash | `assetName_different_index` | `lib.ak` |
| Determinism holds for arbitrary references | `prop_assetName_deterministic` | `lib.ak` |

## 2. Minting Integrity

> *Upstream: "The hash in the token is null" (at boot)*

**Invariant:** A token can only be minted when all of the following
hold simultaneously:

1. The `OutputReference` is consumed in the transaction.
2. Exactly one token is minted (quantity = 1).
3. The output goes to the validator's own script address.
4. The output carries a `StateDatum` with `root = root(empty)`.

Violating any single condition causes the minting policy to reject
the transaction.

| Property | Test | Violated condition |
|---|---|---|
| Happy path (all conditions met) | `canMint` | -- |
| Reference not consumed | `mint_missing_input` | (1) |
| Quantity = 2 | `mint_quantity_two` | (2) |
| Output to wallet address | `mint_to_wallet` | (3) |
| Output to different script | `mint_to_wrong_script` | (3) |
| Non-empty initial root | `mint_nonempty_root` | (4) |
| Datum is `RequestDatum` | `mint_request_datum` | (4) |
| Output has `NoDatum` | `mint_no_datum` | (4) |
| Roundtrip: any valid reference produces a valid mint | `prop_mint_roundtrip` | -- |

## 3. Ownership & Authorization

> *Upstream: "MPF tokens can be modified only by their owner"*

**Invariant:** Only the holder of the correct verification key can
perform privileged operations.

- **Modify / Reject / End** (oracle operations): require the
  `State.owner` signature.
- **Retract** (requester operation): requires the
  `Request.requestOwner` signature.
- **Contribute**: permissionless — anyone can link a request to a
  state UTxO.

| Property | Test | Operation |
|---|---|---|
| Oracle signs Modify | `canCage` | Modify |
| Missing oracle signature blocks Modify | `modify_missing_signature` | Modify |
| Missing oracle signature blocks End | `end_missing_signature` | End |
| Missing oracle signature blocks Reject | `reject_missing_signature` | Reject |
| Requester signs Retract | `retract_happy` | Retract |
| Wrong signer blocks Retract | `retract_wrong_signer` | Retract |
| Random signer != requester fails Retract | `prop_retract_requires_owner` | Retract |
| Random signer != oracle fails Modify | `prop_modify_requires_owner` | Modify |

## 4. Token Confinement

**Invariant:** The caged token must remain at the same script
address after a `Modify` or `Reject` operation. The output's
payment credential must equal the input's payment credential.

This prevents the oracle from extracting the token to a wallet or
redirecting it to a different script during an update.

| Property | Test |
|---|---|
| Output to different script address is rejected | `modify_wrong_address` |
| Output to same address succeeds | `canCage`, `modify_owner_transfer` |

## 5. Ownership Transfer

**Invariant:** The `owner` field in the output datum is **not**
checked against the input datum during `Modify`. The current oracle
can transfer ownership to a new key by changing the `owner` field.

This is intentional: it enables oracle rotation and delegation
without burning and re-minting.

| Property | Test |
|---|---|
| Owner changes from `"owner"` to `"new-owner"` | `modify_owner_transfer` |
| Existing happy path demonstrates transfer | `canCage` |

## 6. State Integrity (MPF Root)

> *Upstream: "All modifications to an MPF root have to appear
> on-chain" and "All modifications must be consumed under a smart
> contract validation"*

**Invariant:** The output root must exactly match the result of
folding all matching request operations over the input root using
the provided Merkle proofs. A wrong claimed root is rejected.

This is the core cryptographic guarantee: every state transition
is provably correct.

| Property | Test |
|---|---|
| Correct root after one Insert | `canCage` |
| Wrong root in output datum | `modify_wrong_root` |
| No requests: root must stay unchanged | `modify_no_requests` |
| Requests for other tokens are skipped | `modify_skip_other_token` |

## 7. Proof Consumption

**Invariant:** Exactly one Merkle proof is consumed per matching
request input. Too few proofs causes failure (`uncons` on empty
list). Extra proofs are silently ignored.

| Property | Test |
|---|---|
| One proof per request (happy path) | `canCage` |
| Zero proofs for one request | `modify_too_few_proofs` |
| Two proofs for one request (extra ignored) | `modify_extra_proofs` |

!!! note
    The validator does not reject extra proofs. This is a design
    choice: it simplifies transaction building when the exact
    number of matching requests is uncertain at construction time.

## 8. Request Binding

> *Upstream: "All consumed requests reference the token being updated"*

**Invariant:** A `Contribute` transaction validates that the
request's `requestToken` matches the actual token at the referenced
State UTxO. Requests targeting a different token are rejected.

This prevents a request intended for token A from being applied
to token B.

| Property | Test |
|---|---|
| Matching token succeeds | `canCage` |
| Mismatched token | `contribute_wrong_token` |
| Referenced UTxO not in inputs | `contribute_missing_ref` |

## 9. Datum-Redeemer Type Safety

**Invariant:** Each redeemer expects a specific datum constructor.
Using the wrong combination causes the `expect` pattern match to
fail, rejecting the transaction.

This enforces a clean separation between State UTxOs (oracle
operations) and Request UTxOs (requester operations).

| Redeemer | Required datum | Wrong datum test |
|---|---|---|
| `Retract` | `RequestDatum` | `retract_on_state_datum` |
| `Contribute` | `RequestDatum` | `contribute_on_state_datum` |
| `Modify` | `StateDatum` | `modify_on_request_datum` |
| `End` | `StateDatum` | `end_on_request_datum` |

## 10. Datum Presence

**Invariant:** The spending validator requires `Some(datum)`. A
UTxO with no datum (e.g. accidentally sent ADA to the script
address) cannot be spent through any redeemer.

| Property | Test |
|---|---|
| `None` datum rejected | `spend_no_datum` |

## 11. End / Burn Integrity

**Invariant:** The `End` redeemer verifies that the mint field
contains exactly the same token being burned. Burning a different
token while keeping the caged one is rejected.

| Property | Test |
|---|---|
| Correct token burned | `end_happy` |
| Different token in mint field | `end_wrong_token_in_mint` |
| End with unrelated extra minting policy | `end_with_extra_mint_policy` |

## 12. Token Extraction

**Invariant:** `tokenFromValue` returns `Some(TokenId)` only when
the value contains exactly one non-ADA policy with exactly one
asset name. All other shapes return `None`.

This is a safety function used throughout the validators to
identify the caged NFT. If a UTxO somehow contains multiple tokens,
extraction fails and the validator rejects.

| Shape | Test | Result |
|---|---|---|
| ADA + 1 NFT | `tokenFromValue_single_nft` | `Some(TokenId)` |
| ADA only | `tokenFromValue_ada_only` | `None` |
| 2 non-ADA policies | `tokenFromValue_multi_policy` | `None` |
| 1 policy, 2 asset names | `tokenFromValue_multi_asset` | `None` |
| Roundtrip via `valueFromToken` | `tokenFromValue_roundtrip` | `Some(TokenId)` |

## 13. Time-Gated Phases

**Invariant:** Each request passes through three exclusive time
phases. The validator enforces phase boundaries using
`tx.validity_range` and the immutable `process_time` / `retract_time`
parameters. No operation can execute outside its designated phase.

```
submitted_at          + process_time       + process_time + retract_time
    |                        |                        |
    |   Phase 1: Oracle      |   Phase 2: Requester   |   Phase 3: Oracle
    |   Modify only          |   Retract only         |   Reject only
```

This eliminates the race condition where a requester retracts while
the oracle is building a Modify transaction.

| Property | Test | Expected |
|---|---|---|
| Retract blocked in Phase 1 | `retract_in_phase1` | fail |
| Retract allowed in Phase 2 | `retract_happy` | pass |
| Retract blocked in Phase 3 | `retract_in_phase3` | fail |
| Contribute blocked in Phase 2 | `contribute_in_phase2` | fail |
| Contribute allowed in Phase 3 (for Reject) | `contribute_in_phase3` | pass |
| Modify blocked in Phase 2 | `modify_in_phase2` | fail |

## 14. Reject (DDoS Protection)

**Invariant:** The oracle can discard requests that are past their
retract window (Phase 3) or have a dishonest `submitted_at`
timestamp. The oracle keeps the fee and refunds the remaining
lovelace. The MPF root must **not** change during a Reject.

This prevents DDoS attacks where requesters spam requests and
retract them before the oracle can process them.

| Property | Test | Expected |
|---|---|---|
| Reject in Phase 3 (happy path) | `reject_happy` | pass |
| Reject blocked in Phase 1 | `reject_in_phase1` | fail |
| Reject blocked in Phase 2 | `reject_in_phase2` | fail |
| Reject with future `submitted_at` (dishonest) | `reject_future_submitted_at` | pass |
| Reject without owner signature | `reject_missing_signature` | fail |
| Reject must not change root | `reject_root_changes` | fail |
| Reject with insufficient refund | `reject_wrong_refund` | fail |

## 15. Fee Enforcement

**Invariant:** When the oracle processes requests via `Modify`,
each request's `fee` must equal `state.max_fee`. The oracle
receives the fee and the requester is refunded `lovelace - fee`.
Refunds are verified on-chain: correct amount, correct address.

| Property | Test | Expected |
|---|---|---|
| Modify with fee and correct refund | `modify_with_refund` | pass |
| Modify with missing refund output | `modify_missing_refund` | fail |
| Modify with insufficient refund | `modify_insufficient_refund` | fail |
| Modify with wrong refund address | `modify_wrong_refund_address` | fail |
| Modify with zero fee (no refund deduction) | `modify_zero_fee` | pass |
| Request fee != state max_fee | `modify_fee_mismatch` | fail |

## 16. Migration

**Invariant:** A token can be migrated from an old validator to
a new one by atomically burning the old token and minting a new
one. The token identity (asset name) and MPF root are preserved.
The old token must be burned (-1) in the same transaction.

| Property | Test | Expected |
|---|---|---|
| Migration happy path (burn old, mint new) | `canMigrate` | pass |
| Migration without burning old token | `migrate_no_burn` | fail |
| Migration to wallet instead of script | `migrate_to_wallet` | fail |
| Migration with wrong old policy ID | `migrate_wrong_old_policy` | fail |

---

## Summary

| # | Category | Tests |
|---|---|---|
| 1 | Token uniqueness | 4 |
| 2 | Minting integrity | 9 |
| 3 | Ownership & authorization | 8 |
| 4 | Token confinement | 2 |
| 5 | Ownership transfer | 2 |
| 6 | State integrity (MPF root) | 4 |
| 7 | Proof consumption | 3 |
| 8 | Request binding | 3 |
| 9 | Datum-redeemer type safety | 4 |
| 10 | Datum presence | 1 |
| 11 | End / burn integrity | 3 |
| 12 | Token extraction | 5 |
| 13 | Time-gated phases | 6 |
| 14 | Reject (DDoS protection) | 7 |
| 15 | Fee enforcement | 6 |
| 16 | Migration | 4 |
| | **Total** | **67** |
