# Security Properties

This page documents the on-chain security properties of the MPF Cage
validators. Each property is stated as an invariant and cross-referenced
with the test(s) that verify it.

The properties are derived from the
[upstream MPFS specification](https://cardano-foundation.github.io/mpfs/)
and verified by the inline test suite. Run `aiken check` (or `just test`)
to check all 44 tests / 242 checks.

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
| Requesters can always reclaim locked ADA | On-chain (Retract path) |
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

- **Modify / End** (oracle operations): require the `State.owner`
  signature.
- **Retract** (requester operation): requires the
  `Request.requestOwner` signature.
- **Contribute**: permissionless — anyone can link a request to a
  state UTxO.

| Property | Test | Operation |
|---|---|---|
| Oracle signs Modify | `canCage` | Modify |
| Missing oracle signature blocks Modify | `modify_missing_signature` | Modify |
| Missing oracle signature blocks End | `end_missing_signature` | End |
| Requester signs Retract | `retract_happy` | Retract |
| Wrong signer blocks Retract | `retract_wrong_signer` | Retract |
| Random signer != requester fails Retract | `prop_retract_requires_owner` | Retract |
| Random signer != oracle fails Modify | `prop_modify_requires_owner` | Modify |

## 4. Token Confinement

**Invariant:** The caged token must remain at the same script
address after a `Modify` operation. The output's payment credential
must equal the input's payment credential.

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

---

## Summary

| Category | Properties | Tests |
|---|---|---|
| Token uniqueness | 1 | 4 |
| Minting integrity | 1 | 9 |
| Ownership & authorization | 3 | 7 |
| Token confinement | 1 | 2 |
| Ownership transfer | 1 | 2 |
| State integrity (MPF root) | 1 | 4 |
| Proof consumption | 1 | 3 |
| Request binding | 1 | 3 |
| Datum-redeemer type safety | 4 | 4 |
| Datum presence | 1 | 1 |
| End / burn integrity | 1 | 2 |
| Token extraction | 1 | 5 |
| **Total** | **17** | **44** (242 checks) |
