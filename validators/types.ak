/// Core type definitions for the MPF Cage validator.
///
/// This module defines the data structures used for:
/// - Minting and burning caged tokens
/// - Managing state updates via the Merkle Patricia Forestry
/// - Processing contribution requests from other users
///
/// ## Cage Pattern Overview
///
/// A "caged" token is an NFT locked at a script address with an associated
/// Merkle Patricia Forestry (MPF) root. The owner can update the MPF by
/// accepting requests from other users, enabling collaborative data structures
/// on-chain.
///
/// ## Two-UTxO Architecture
///
/// The cage script manages two fundamentally different kinds of UTxOs,
/// distinguished by their datum type:
///
/// 1. **State UTxOs** (`StateDatum`): Hold the caged NFT and the current
///    MPF root hash. Only one State UTxO exists per caged token. The owner
///    field determines who can perform `Modify` and `End` operations.
///
/// 2. **Request UTxOs** (`RequestDatum`): Created by users who want to
///    contribute data to someone else's caged token. They do NOT hold the
///    NFT -- they sit at the same script address with a different datum.
///    The `requestToken` field links the request to a specific caged token.
///
/// ## Lifecycle
///
/// ```
/// Mint  -->  State UTxO (empty root)
///                |
///                |  <-- Request UTxOs arrive (from contributors)
///                |
///                v
///            Modify (folds requests into MPF, updates root)
///                |
///                v
///            State UTxO (updated root)
///                |
///                v
///             End (burns the NFT)
/// ```
///
/// Request UTxOs that are not yet accepted can be reclaimed by their
/// creator via the `Retract` redeemer.
///
/// ## Test Planning Notes
///
/// The types themselves don't have validation logic, but tests should
/// verify that:
/// - All datum variants can be serialized/deserialized as inline datums
/// - Pattern matching on `CageDatum` correctly distinguishes `RequestDatum`
///   from `StateDatum`
/// - The `Operation` variants carry the right payloads (Insert has 1 value,
///   Delete has 1 value, Update has 2 values)
/// - `MintRedeemer` and `UpdateRedeemer` cover all action types exhaustively

use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{Proof}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference}
use lib.{TokenId}

/// Parameters for minting a new caged token.
///
/// The `asset` field is an `OutputReference` that serves a dual purpose:
/// 1. Its hash becomes the asset name (via `lib.assetName`), guaranteeing
///    uniqueness since an output reference can only be consumed once.
/// 2. The referenced UTxO must be consumed in the minting transaction,
///    enforced by `validateMint` in `cage.ak`. This prevents replaying
///    the same mint parameters in a future transaction.
///
/// ## Test Hints
/// - Mint with a valid consumed output reference -> should succeed
/// - Mint with an output reference NOT in the transaction inputs -> should fail
/// - Mint twice with the same output reference -> second must fail (UTxO already spent)
pub type Mint {
  /// The output reference used to derive the asset name (via hash).
  /// This must be one of the transaction inputs to ensure uniqueness.
  asset: OutputReference,
}

/// Parameters for migrating a caged token from an old validator to a new one.
///
/// During migration, the old token is burned (under `oldPolicy`) and a new
/// token is minted (under the new policy) in the same transaction. The
/// `tokenId` is preserved across migration (same asset name).
///
/// Uniqueness of the new token is guaranteed by the atomic burn of the old
/// one -- no `OutputReference` consumption is needed.
pub type Migration {
  /// The policy ID of the old validator whose token is being burned.
  oldPolicy: PolicyId,
  /// The token identity (asset name) being migrated.
  tokenId: TokenId,
}

/// Redeemer for the minting policy.
///
/// The minting policy handles three cases:
/// - `Minting`: Full validation is applied (see `validateMint` in `cage.ak`).
/// - `Migrating`: Mints a token with a carried-over (possibly non-empty) root,
///   validated by `validateMigration` in `cage.ak`. Requires the old token to
///   be burned atomically in the same transaction.
/// - `Burning`: No additional validation beyond what the ledger enforces.
///   The ledger already ensures the minting policy script runs, so the fact
///   that we reach the `Burning` branch means the policy was invoked. The
///   spending validator's `End` redeemer handles ensuring the token is
///   actually being burned (checks the mint field for quantity -1).
///
/// ## Security Note
/// `Burning` returning `True` unconditionally is safe because:
/// 1. You can only burn tokens you possess (they must be in a transaction input).
/// 2. The `End` spending validator ensures the State UTxO owner signed the tx.
/// 3. The `End` validator checks the mint field contains the token being burned.
pub type MintRedeemer {
  /// Mint a new caged token with the given parameters
  Minting(Mint)
  /// Migrate a caged token from an old validator to this one
  Migrating(Migration)
  /// Burn an existing caged token (no additional validation)
  Burning
}

/// Redeemer for spending caged UTxOs.
///
/// This redeemer is used by the spending validator in `cage.ak`. The four
/// variants correspond to four distinct operations, each requiring a
/// different datum type on the UTxO being spent:
///
/// | Redeemer       | Required Datum  | Who Can Execute         | Purpose                        |
/// |----------------|-----------------|-------------------------|--------------------------------|
/// | `End`          | `StateDatum`    | State owner             | Burn the caged NFT             |
/// | `Contribute`   | `RequestDatum`  | Anyone (permissionless) | Link a request to a State UTxO |
/// | `Modify`       | `StateDatum`    | State owner             | Fold requests into MPF         |
/// | `Retract`      | `RequestDatum`  | Request owner           | Reclaim an unprocessed request |
/// | `Reject`       | `StateDatum`    | State owner             | Discard expired/dishonest reqs |
///
/// ## Test Hints
/// - Using `End` on a `RequestDatum` UTxO -> should fail (expects StateDatum)
/// - Using `Retract` on a `StateDatum` UTxO -> should fail (expects RequestDatum)
/// - Using `Modify` without owner signature -> should fail
/// - Using `Contribute` with a request targeting a different token -> should fail
/// - Using `Retract` without request owner signature -> should fail
pub type UpdateRedeemer {
  /// Destroy the caged token (burns the NFT). Requires State datum.
  /// The spending validator checks that the mint field contains the
  /// same token with quantity -1, and that the state owner signed.
  End
  /// Validate that a Request UTxO targets the correct caged token.
  /// The `OutputReference` points to the State UTxO that holds the
  /// caged token. This is a permissionless operation: anyone can
  /// submit a `Contribute` transaction to link their request.
  ///
  /// ## Why Contribute Exists
  /// The `Contribute` step validates that a request targets the right
  /// token BEFORE the owner processes it. Without this, a request
  /// could claim to target token A but actually be applied to token B.
  /// By requiring the request UTxO to be spent with `Contribute` first
  /// (which checks `requestToken == tokenId`), the system ensures
  /// request-token binding is validated on-chain.
  Contribute(OutputReference)
  /// Update the MPF state by processing input requests. Requires State datum.
  /// The `List<Proof>` must contain exactly one Merkle proof per request
  /// being folded into the MPF, in the same order as the request inputs
  /// appear in the transaction's input list.
  ///
  /// ## How the Proof List Works
  /// The validator iterates over ALL transaction inputs. For each input
  /// that contains a `RequestDatum` targeting this token, it consumes
  /// one proof from the list. Non-request inputs (or requests targeting
  /// other tokens) are skipped without consuming a proof.
  ///
  /// ## Test Hints
  /// - Modify with correct proofs -> root should update correctly
  /// - Modify with wrong proof -> should fail (MPF proof verification)
  /// - Modify with too few proofs -> should fail (uncons on empty list)
  /// - Modify with too many proofs -> proofs remain unconsumed (no check currently)
  /// - Modify with no requests in inputs -> root stays the same
  Modify(List<Proof>)
  /// Allow the request owner to reclaim their Request UTxO. Requires Request datum.
  /// Only the `requestOwner` (from the Request datum) can sign this transaction.
  /// This lets contributors withdraw unprocessed requests and recover their ADA.
  ///
  /// ## Test Hints
  /// - Retract signed by requestOwner -> should succeed
  /// - Retract signed by someone else -> should fail
  /// - Retract on an already-processed request -> impossible (UTxO already consumed)
  Retract
  /// Discard requests that are past their retract window (Phase 3) or have
  /// a dishonest (future) `submitted_at` timestamp. Requires State datum.
  /// The oracle keeps the fee and refunds the remaining lovelace.
  /// The MPF root MUST NOT change during a Reject operation.
  Reject
}

/// The state of a caged token, stored as inline datum.
///
/// This represents the current owner and MPF root of the caged token.
/// A State value lives inside a `StateDatum` wrapper as part of a `CageDatum`.
///
/// ## Ownership Model
/// The `owner` field is a `VerificationKeyHash`, meaning only a single
/// key holder controls the cage. There is no multi-sig or script-based
/// ownership -- the owner must directly sign transactions that `Modify`
/// or `End` the cage.
///
/// ## Root Hash
/// The `root` field is a raw `ByteArray` (32 bytes for SHA2-256) representing
/// the MPF root hash. It starts as `root(empty)` when freshly minted, or can
/// be non-empty when migrated from an old validator. It is updated each time
/// `Modify` processes requests.
///
/// ## Owner Mutability
/// Note that the `Modify` validator does NOT check that the owner field is
/// preserved between input and output. This means the owner can transfer
/// ownership of the cage by changing the `owner` field in the output datum.
/// This is a feature, not a bug -- it enables ownership transfer.
///
/// ## Test Hints
/// - Verify owner can change during Modify (ownership transfer)
/// - Verify root must match computed MPF root after folding requests
/// - Verify initial root is `root(empty)` after minting
pub type State {
  /// The verification key hash of the token owner.
  /// Only the owner can modify the MPF state or end the cage.
  owner: VerificationKeyHash,
  /// The current Merkle Patricia Forestry root hash.
  /// This commits to all key-value pairs stored in the MPF.
  root: ByteArray,
  /// The maximum fee (in lovelace) the oracle charges per request.
  /// Requesters must agree to this fee by recording it in their Request datum.
  max_fee: Int,
}

/// Operations that can be performed on the MPF.
///
/// Each operation modifies the MPF in a specific way and requires
/// a corresponding proof to validate the transition. The proof
/// demonstrates that the operation is valid given the current MPF state.
///
/// These operations map directly to the `merkle_patricia_forestry` library
/// functions: `mpf.insert`, `mpf.delete`, and `mpf.update`.
///
/// ## Proof Requirements
///
/// Each operation requires a Merkle proof that demonstrates:
/// - `Insert(value)`: The key does NOT exist in the current trie.
///   The proof shows the absence of the key, and after insertion
///   the new root includes the key-value pair.
/// - `Delete(value)`: The key EXISTS with the given value.
///   The proof shows the key's current value, and after deletion
///   the new root excludes the key.
/// - `Update(old, new)`: The key EXISTS with value `old`.
///   The proof shows the key's current value, and after update
///   the new root maps the key to `new`.
///
/// ## Test Hints
/// - Insert on empty MPF with valid proof -> should succeed
/// - Insert on key that already exists -> should fail (MPF library rejects)
/// - Delete on non-existent key -> should fail
/// - Delete with wrong expected value -> should fail
/// - Update with wrong old value -> should fail
/// - Multiple operations in sequence (Insert then Update on same key across
///   two separate Modify transactions) -> should succeed
pub type Operation {
  /// Insert a new key-value pair. Fails if key already exists.
  /// The ByteArray is the value to associate with the request's key.
  Insert(ByteArray)
  /// Delete an existing key-value pair. The ByteArray is the expected
  /// current value -- must match what's in the MPF or the proof fails.
  Delete(ByteArray)
  /// Update an existing key's value. First ByteArray is the expected
  /// current value (old_value), second is the new value (new_value).
  /// Both must be correct for the proof to verify.
  Update(ByteArray, ByteArray)
}

/// A request to modify a caged token's MPF.
///
/// Requests are created by users who want to contribute data to
/// someone else's caged token. The token owner can then accept
/// the request by including it in a Modify transaction.
///
/// ## Request Lifecycle
///
/// 1. **Creation**: A user creates a UTxO at the cage script address
///    with a `RequestDatum(Request { ... })` inline datum. The UTxO
///    typically holds only ADA (no NFT).
///
/// 2. **Contribution**: The request UTxO is spent with `Contribute(tokenRef)`
///    redeemer, which validates that `requestToken` matches the token
///    at `tokenRef`. This step is permissionless.
///
/// 3. **Processing**: The request UTxO appears as an input in a `Modify`
///    transaction. The validator reads the `requestKey` and `requestValue`,
///    applies the operation to the MPF using the provided proof, and
///    advances the root hash.
///
/// 4. **Retraction** (alternative to 2-3): If the owner hasn't processed
///    the request, the request creator can spend it with `Retract`,
///    which only requires `requestOwner`'s signature.
///
/// ## Linking Mechanism
/// The `requestToken` field is a `TokenId` (just an asset name). It must
/// match the asset name of the caged NFT. The policy ID is implicit --
/// it's the cage script's own policy ID.
///
/// ## Test Hints
/// - Request targeting token A processed in Modify for token A -> should succeed
/// - Request targeting token A included in Modify for token B -> should be skipped
///   (mkUpdate checks requestToken == tokenId and skips non-matching requests)
/// - Request with Insert("foo") for key "bar" -> inserts key "bar" with value "foo"
/// - Two requests for same key in same Modify tx -> depends on order and operation
///   type (e.g., Insert then Delete would insert then immediately delete)
pub type Request {
  /// The token this request targets (by asset name).
  /// Must match the TokenId of the caged NFT for the request to be processed.
  requestToken: TokenId,
  /// The owner of this request (can reclaim via Retract).
  /// This is the VerificationKeyHash that must sign a Retract transaction.
  requestOwner: VerificationKeyHash,
  /// The key to insert/update/delete in the MPF.
  /// This is an arbitrary ByteArray that becomes a key in the Merkle trie.
  requestKey: ByteArray,
  /// The operation to perform on the key.
  /// See `Operation` type for details on Insert, Delete, and Update.
  requestValue: Operation,
  /// The fee (in lovelace) the requester agrees to pay.
  /// Must match `state.max_fee` at Modify time.
  fee: Int,
  /// The POSIXTime (in milliseconds) when the request was submitted.
  /// Used for time-gated phase enforcement: Phase 1 (oracle-only),
  /// Phase 2 (requester retract), Phase 3 (oracle reject/cleanup).
  submitted_at: Int,
}

/// Datum for UTxOs locked at the cage script address.
///
/// The cage script can hold two types of UTxOs:
/// - **State UTxOs** (`StateDatum`): contain the caged NFT and its MPF root.
///   There is exactly one State UTxO per caged token. It holds the NFT in
///   its value and the current MPF root in its datum.
/// - **Request UTxOs** (`RequestDatum`): contain pending requests to modify
///   a token's MPF. These hold only ADA (no NFT). Multiple Request UTxOs
///   can exist for the same caged token.
///
/// ## Dispatch Logic in the Spending Validator
///
/// The spending validator pattern-matches on the datum to determine
/// which operations are valid:
///
/// - `RequestDatum` + `Retract` -> owner reclaims request
/// - `RequestDatum` + `Contribute(ref)` -> validate request targets correct token
/// - `StateDatum` + `Modify(proofs)` -> fold requests into MPF
/// - `StateDatum` + `End` -> burn the caged NFT
///
/// Any other combination (e.g., `RequestDatum` + `End`) will fail because
/// the `expect` pattern match in the validator will not succeed.
///
/// ## Test Hints
/// - Construct transactions with mismatched datum/redeemer combinations
///   and verify they all fail
/// - Verify that inline datums round-trip correctly through serialization
pub type CageDatum {
  /// A pending request to modify someone's caged token
  RequestDatum(Request)
  /// The current state of a caged token
  StateDatum(State)
}
