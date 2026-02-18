/// MPF Cage Validator - A self-custodial Merkle Patricia Forestry on Cardano.
///
/// This validator implements the "cage" pattern for managing NFTs with associated
/// on-chain data structures. A caged token is an NFT locked at this script's address
/// with a Merkle Patricia Forestry (MPF) root as part of its datum.
///
/// ## Minting Policy
///
/// When minting a new caged token, the validator ensures:
/// - The asset name is derived from a consumed UTxO (ensuring uniqueness)
/// - Exactly one token is minted
/// - The token is sent to this script's address
/// - The initial MPF root is empty
///
/// Alternatively, a token can be minted via `Migrating` to support contract
/// migration. In this case the MPF root may be non-empty (carried over from
/// the old validator) and uniqueness is guaranteed by atomically burning the
/// old token in the same transaction.
///
/// ## Spending Validator
///
/// The validator supports four operations:
///
/// - **Modify**: Owner updates the MPF by processing pending requests.
///   Requires proofs for each request being folded into the MPF.
///
/// - **Contribute**: Links a Request UTxO to a State UTxO, validating
///   that the request targets the correct token.
///
/// - **Retract**: Allows a request owner to reclaim their Request UTxO
///   if the token owner hasn't accepted it.
///
/// - **End**: Burns the caged token, destroying the cage entirely.
///
/// ## Data Flow
///
/// 1. User creates a caged token via `Minting` (empty MPF root)
/// 2. Others submit requests as separate UTxOs with `RequestDatum`
/// 3. Owner accepts requests via `Modify`, updating the MPF root
/// 4. Request owners can `Retract` unprocessed requests
/// 5. Owner can `End` the cage when done
///
/// ## Combined Minting + Spending Validator
///
/// This file defines a single `validator mpfCage` that handles BOTH
/// minting and spending. Because the same script hash is used for both:
/// - The minting policy can enforce tokens go to this script's address
///   (by checking `targetScriptHash == policyId`)
/// - The spending validator can verify token identity using the policy ID
///
/// This is a key architectural decision: it means caged tokens can ONLY
/// exist at this script address, and only this script can authorize
/// spending them.
///
/// ## Comprehensive Test Plan
///
/// ### Minting Tests
/// - Happy path: mint with valid OutputReference, correct output -> success
/// - Missing input: OutputReference not consumed -> fail
/// - Wrong quantity: mint 2 tokens -> fail
/// - Wrong address: token sent to different script -> fail
/// - Wrong address: token sent to wallet -> fail
/// - Non-empty initial root -> fail
/// - Multiple outputs -> should use head (first output)
///
/// ### Modify Tests
/// - Happy path: one request, one proof, root updates correctly -> success
/// - Multiple requests: fold in order, all proofs consumed -> success
/// - Wrong proof: MPF verification fails -> fail
/// - Missing owner signature -> fail
/// - Token moves to different address -> fail (payment credential check)
/// - Owner changes in output datum -> success (ownership transfer)
/// - No requests in inputs -> root stays the same, still succeeds
/// - Requests targeting different token -> skipped (not consumed from proofs)
/// - Interleaved requests (some for this token, some for others) -> only
///   matching ones consume proofs
///
/// ### Contribute Tests
/// - Happy path: request targets correct token -> success
/// - Wrong token: request targets different token -> fail
/// - State UTxO reference not in inputs -> fail (extractToken fails)
///
/// ### Retract Tests
/// - Happy path: requestOwner signs -> success
/// - Wrong signer: someone else signs -> fail
/// - No datum -> fail
///
/// ### End Tests
/// - Happy path: owner signs, token burned in mint field -> success
/// - Missing owner signature -> fail
/// - Token not in mint field -> fail
/// - Mint field has different token -> fail
///
/// ### Edge Cases
/// - Spending UTxO with no datum -> fail (expect Some(datum))
/// - Burning redeemer in minting policy -> True (but spending validator
///   still validates via End)
/// - Using wrong redeemer for datum type (e.g., Modify on RequestDatum) -> fail

use aiken/collection/list
use aiken/collection/list.{find, foldl, has, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/interval
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, Proof, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/assets
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{TokenId, assetName, quantity, tokenFromValue}
use types.{
  Burning, CageDatum, Contribute, Delete, End, Insert, Migrating, Migration, Mint,
  MintRedeemer, Minting, Modify, Reject, Request, RequestDatum, Retract, State,
  StateDatum, Update, UpdateRedeemer,
}

/// The main validator for caged MPF tokens.
///
/// This validator serves as both a minting policy and a spending validator,
/// using the same script hash for both purposes. This ensures that minted
/// tokens can only be sent to this script's address.
///
/// ## How Both Roles Interact
///
/// When a token is minted, the minting policy (`mint`) checks that the
/// output goes to `policyId` (itself). When the token is spent, the
/// spending validator (`spend`) runs because the UTxO is at this script's
/// address. The `else(_)` handler rejects any other purpose (e.g.,
/// withdrawal, certify).
validator mpfCage(_version: Int, process_time: Int, retract_time: Int) {
  /// Minting policy: validates creation and destruction of caged tokens.
  ///
  /// - `Minting`: Creates a new caged token with an empty MPF root.
  ///   Delegates to `validateMint` which enforces all invariants.
  /// - `Burning`: Returns `True` unconditionally. This is safe because
  ///   the spending validator (`End` redeemer) handles the actual burn
  ///   validation (owner signature + token in mint field). The minting
  ///   policy only needs to authorize the policy ID usage.
  ///
  /// ## Why Burning is Unconditional
  /// The Cardano ledger requires the minting policy to run whenever tokens
  /// are minted or burned. For burning, the real security comes from the
  /// spending validator: the State UTxO holding the token must be spent
  /// (requiring the `End` redeemer and owner's signature). The minting
  /// policy just needs to not block the burn.
  mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) {
    trace @"minting": redeemer
    when redeemer is {
      Minting(mint) -> {
        trace "minting": mint
        validateMint(mint, policyId, tx)
      }
      Migrating(migration) -> {
        trace "migrating": migration
        validateMigration(migration, policyId, tx)
      }
      Burning -> True
    }
  }

  /// Spending validator: validates operations on caged UTxOs.
  ///
  /// This is the main entry point for all spending operations. It receives:
  /// - `maybeDatum`: The datum attached to the UTxO being spent (always
  ///   expected to be `Some`; `None` causes immediate failure)
  /// - `redeemer`: The operation to perform (Retract, Contribute, Modify, End)
  /// - `self`: The output reference of the UTxO being spent
  /// - `tx`: The full transaction context
  ///
  /// ## Dispatch Logic
  ///
  /// The validator first unwraps the datum, then dispatches based on redeemer:
  ///
  /// 1. **Retract**: Expects `RequestDatum`. Checks requestOwner signed.
  /// 2. **Contribute**: Expects `RequestDatum`. Checks requestToken matches
  ///    the token at the given OutputReference.
  /// 3. **Modify/End**: Expects `StateDatum`. Checks state owner signed.
  ///    Then further dispatches:
  ///    - Modify: Validates MPF root update with proofs
  ///    - End: Validates token is being burned
  ///
  /// ## Security: Datum-Redeemer Type Safety
  ///
  /// The `expect` pattern matches enforce that the correct datum type is
  /// used with each redeemer. For example:
  /// - `Retract` does `expect RequestDatum(request) = datum` which fails
  ///   if the datum is `StateDatum`
  /// - `Modify`/`End` does `expect StateDatum(state) = datum` which fails
  ///   if the datum is `RequestDatum`
  ///
  /// This means you cannot retract a State UTxO or modify a Request UTxO.
  ///
  /// ## The Wildcard Branch
  ///
  /// The `_ -> { ... }` branch handles both `Modify` and `End` because
  /// they share the same pre-conditions (StateDatum + owner signature +
  /// token extraction). Inside this branch, a second `when` dispatches
  /// to the specific validation. The final `_ -> fail` catches any
  /// redeemer variant that shouldn't reach this branch (defensive coding).
  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    self: OutputReference,
    tx: Transaction,
  ) {
    // Fail if the UTxO has no datum. All cage UTxOs must have inline datums.
    // This guards against accidentally sending ADA to the script without a datum.
    expect Some(datum) = maybeDatum
    // Dispatch based on redeemer type
    when redeemer is {
      Retract -> {
        // --- RETRACT PATH ---
        // Only valid for Request UTxOs during Phase 2 (retract window).
        expect RequestDatum(request) = datum
        let Request { requestOwner, submitted_at, .. } = request
        let Transaction { extra_signatories, validity_range, .. } = tx
        expect has(extra_signatories, requestOwner)
        // Phase 2: retract window is open
        expect
          in_phase2(validity_range, submitted_at, process_time, retract_time)
        True
      }
      Contribute(tokenRef) -> {
        // --- CONTRIBUTE PATH ---
        // Valid for Request UTxOs in Phase 1 or when rejectable.
        expect RequestDatum(request) = datum
        validRequest(request, tokenRef, tx, process_time, retract_time)
      }
      _ -> {
        // --- MODIFY / END PATH ---
        // Both Modify and End operate on State UTxOs and require the
        // state owner's signature.
        //
        // Fail if datum is not a StateDatum
        expect StateDatum(state) = datum
        // Fail if the state owner hasn't signed the transaction.
        // This is the authorization check -- only the cage owner can
        // modify the MPF state or end the cage.
        expect validateOwnership(state, tx)
        // Extract the caged token from the input being spent.
        // This gives us the Input (for address checks later) and the
        // TokenId (for identifying which token is being operated on).
        let (input, tokenId) = extractToken(self, tx)
        when redeemer is {
          Modify(proofs) ->
            validRootUpdate(
              state,
              input,
              tokenId,
              tx,
              proofs,
              process_time,
            )
          Reject ->
            validReject(
              state,
              input,
              tokenId,
              tx,
              process_time,
              retract_time,
            )
          End -> {
            expect address.Script(policyId) =
              input.output.address.payment_credential
            validateEnd(policyId, tokenId, tx)
          }
          // Defensive: should never reach here since Retract and Contribute
          // are handled above. Included for exhaustiveness.
          _ -> fail
        }
      }
    }
  }

  /// Reject any other script purpose (withdraw, certify, etc.)
  ///
  /// The cage validator only handles minting and spending. Any other
  /// script purpose is unconditionally rejected. This prevents the
  /// script from being used as a staking or governance validator.
  else(_) {
    fail
  }
}

/// Extract the token from a transaction input by its output reference.
///
/// Finds the input matching the given output reference and extracts the
/// single token from its value. Fails if the input is not found or
/// doesn't contain exactly one non-ADA token.
///
/// ## How It Works
/// 1. Search `tx.inputs` for an input whose `output_reference` matches `what`
/// 2. Extract the single non-ADA token from that input's value via `tokenFromValue`
/// 3. Return the (Input, TokenId) pair
///
/// ## Failure Modes
/// - `expect Some(input)` fails if the output reference is not in the inputs
/// - `expect Some(tokenId)` fails if the input doesn't contain exactly one
///   non-ADA token (e.g., ADA-only, or multiple NFTs)
///
/// ## Usage
/// Called in the spending validator's Modify/End path to identify which
/// caged token is being operated on. The returned `Input` is also used
/// by `validRootUpdate` to check the output address matches.
///
/// ## Test Hints
/// - Input with exactly one NFT -> returns (input, tokenId)
/// - Input with no NFT -> fails
/// - Input with multiple NFTs -> fails
/// - Output reference not in inputs -> fails
pub fn extractToken(what: OutputReference, tx: Transaction) {
  expect Some(input) =
    find(tx.inputs, fn(input) { input.output_reference == what })
  expect Some(tokenId) = tokenFromValue(input.output.value)
  (input, tokenId)
}

/// Validate that the token is being burned.
///
/// Checks that the mint field contains the token with quantity -1 under the
/// given policy ID. Uses `quantity` to look up the specific token, which
/// works even when the mint field contains additional policies (e.g., during
/// migration where a new token is minted under a different policy).
///
/// ## Test Hints
/// - Mint field contains the token with quantity -1 -> success
/// - Mint field contains a different token -> fail
/// - Mint field is empty -> fail
/// - Mint field has additional policies (migration) -> still succeeds
fn validateEnd(policyId, tokenId, tx) {
  let Transaction { mint, .. } = tx
  expect Some(q) = quantity(policyId, mint, tokenId)
  expect q == -1
  True
}

/// Validate that the state owner has signed the transaction.
///
/// Checks that the owner's verification key hash is in the transaction's
/// extra signatories list.
///
/// ## How It Works
/// The `extra_signatories` field contains the list of public key hashes
/// that have signed this transaction. By checking that the state's `owner`
/// is in this list, we confirm the cage owner has authorized this operation.
///
/// ## Security
/// This is the primary authorization mechanism for the cage. Without the
/// owner's signature:
/// - Cannot Modify the MPF state
/// - Cannot End the cage (burn the token)
///
/// Note that Retract uses `requestOwner` (not state owner) and Contribute
/// is permissionless -- neither calls this function.
///
/// ## Test Hints
/// - Owner's key hash in extra_signatories -> True
/// - Owner's key hash NOT in extra_signatories -> fail (expect fails)
/// - Empty extra_signatories -> fail
fn validateOwnership(state: State, tx: Transaction) {
  let Transaction { extra_signatories, .. } = tx
  let State { owner, .. } = state
  expect has(extra_signatories, owner)
  True
}

/// Validate that a request matches the token being updated.
///
/// Ensures the request's target token matches the token at the given
/// output reference. This prevents requests from being applied to
/// the wrong caged token.
///
/// ## How It Works
/// 1. Extract the request's target token (`requestToken`) from the datum
/// 2. Look up the State UTxO at `tokenRef` and extract its caged token
/// 3. Compare: `requestToken == tokenId`
///
/// ## Why This Matters
/// Without this check, a malicious actor could create a request claiming
/// to target token A, then submit a Contribute transaction pointing at
/// token B. The Modify transaction would then apply the request's operation
/// to token B's MPF, which the request creator never intended (or
/// deliberately exploited).
///
/// ## Permissionless Design
/// Note that anyone can submit a Contribute transaction -- there's no
/// signature check here. This is intentional: the contribution step just
/// validates the request-token binding, it doesn't change any state.
/// The actual request UTxO is consumed, but its data is preserved in the
/// transaction for the Modify step.
///
/// ## Test Hints
/// - requestToken matches token at tokenRef -> True
/// - requestToken differs from token at tokenRef -> fail
/// - tokenRef not in inputs -> fail (extractToken fails)
fn validRequest(
  request: Request,
  tokenRef: OutputReference,
  tx: Transaction,
  process_time: Int,
  retract_time: Int,
) {
  let Request { requestToken, submitted_at, .. } = request
  let (_input, tokenId) = extractToken(tokenRef, tx)
  expect requestToken == tokenId
  let Transaction { validity_range, .. } = tx
  // Phase 1 or rejectable (NOT Phase 2 — requester-exclusive)
  expect
    in_phase1(validity_range, submitted_at, process_time)
      || is_rejectable(
          validity_range,
          submitted_at,
          process_time,
          retract_time,
        )
  True
}

/// Helper to deconstruct a non-empty list with continuation.
///
/// Calls the continuation function with the head and tail of the list.
/// Fails on an empty list.
///
/// ## Usage in the Validator
/// Used by `mkUpdate` to consume one proof from the proofs list for each
/// matching request. The continuation-passing style allows chaining the
/// remaining proofs through the fold.
///
/// ## Why Not Use list.head + list.tail?
/// Using `uncons` with pattern matching is more idiomatic in Aiken and
/// avoids dealing with `Option` return types. It also provides a clean
/// failure mode: if there aren't enough proofs, the empty-list branch
/// triggers `fail`, which aborts the validator.
///
/// ## Test Hints
/// - Non-empty list -> calls cont(head, tail)
/// - Empty list -> fails (transaction is rejected)
/// - Single element list -> cont(elem, [])
fn uncons(list: List<a>, cont: fn(a, List<a>) -> b) -> b {
  when list is {
    [] -> fail
    [x, ..xs] -> cont(x, xs)
  }
}

/// Check if the validity range is entirely within Phase 1 (oracle processing).
/// Phase 1: from submitted_at to submitted_at + process_time (exclusive).
pub fn in_phase1(validity_range, submitted_at, process_time) -> Bool {
  interval.is_entirely_before(validity_range, submitted_at + process_time)
}

/// Check if the validity range is entirely within Phase 2 (requester retract).
/// Phase 2: from submitted_at + process_time to
///          submitted_at + process_time + retract_time (exclusive).
pub fn in_phase2(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  interval.is_entirely_after(
    validity_range,
    submitted_at + process_time - 1,
  )
    && interval.is_entirely_before(
        validity_range,
        submitted_at + process_time + retract_time,
      )
}

/// Check if a request is rejectable: Phase 3 (retract expired) or
/// dishonest (submitted_at is in the future).
pub fn is_rejectable(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  // Phase 3: retract window expired
  interval.is_entirely_after(
    validity_range,
    submitted_at + process_time + retract_time - 1,
  )
    // OR dishonest: submitted_at is in the future
    || interval.is_entirely_before(validity_range, submitted_at)
}

/// Create an update function for folding requests into the MPF.
///
/// Returns a function suitable for use with `foldl` that processes each
/// transaction input. For inputs containing a Request targeting the given
/// token, it applies the request's operation to the MPF using the next
/// proof from the accumulator.
///
/// ## Parameters
/// - `tokenId`: The TokenId of the caged token being modified
///
/// ## Returns
/// A function `(Input, (MPF, List<Proof>)) -> (MPF, List<Proof>)` where:
/// - The `Input` is a transaction input being examined
/// - The first element of the tuple is the current MPF state
/// - The second element is the remaining proofs to consume
///
/// ## How the Fold Works (step by step)
///
/// For each input in the transaction:
///
/// 1. **Check datum type**: Does the input have an `InlineDatum`?
///    - No -> skip (return accumulator unchanged)
///
/// 2. **Check datum content**: Is it a `RequestDatum(request)`?
///    - No -> skip (return accumulator unchanged)
///
/// 3. **Check token match**: Does `requestToken == tokenId`?
///    - No -> skip (return accumulator unchanged)
///    - This is how requests for OTHER tokens are filtered out
///
/// 4. **Consume a proof**: Pop the next proof from the proofs list via `uncons`
///    - If no proofs remain, `uncons` fails -> transaction rejected
///
/// 5. **Apply the operation**: Based on `requestValue`:
///    - `Insert(value)` -> `mpf.insert(root, key, value, proof)`
///    - `Delete(value)` -> `mpf.delete(root, key, value, proof)`
///    - `Update(old, new)` -> `mpf.update(root, key, proof, old, new)`
///    Each of these MPF functions will fail if the proof is invalid.
///
/// 6. **Return**: Updated (newRoot, remainingProofs)
///
/// ## Important: Input Ordering
/// The fold processes inputs in the order they appear in `tx.inputs`.
/// The proofs list must match this order. If inputs are reordered, the
/// proofs would be applied to the wrong requests, causing proof
/// verification failures.
///
/// ## Important: Non-Request Inputs Are Skipped
/// The State UTxO itself is also in the inputs list, but it has a
/// `StateDatum`, not a `RequestDatum`, so it's skipped. Any other
/// inputs (e.g., wallet UTxOs for fees) have no inline datum or a
/// non-CageDatum datum, so they're also skipped.
///
/// ## Security: Type Coercion Safety
/// The `if datum is RequestDatum(request): CageDatum` syntax attempts
/// to parse the inline datum as a `CageDatum`. If the datum is from
/// a completely different script and happens to parse as a CageDatum,
/// it would be processed. In practice this is harmless because:
/// - The requestToken check filters out irrelevant requests
/// - MPF proof verification would fail for fabricated data
///
/// ## Test Hints
/// - One matching request with valid proof -> MPF updated
/// - Non-matching request (different token) -> skipped, no proof consumed
/// - Input with no datum -> skipped
/// - Input with non-CageDatum -> skipped
/// - Multiple matching requests -> proofs consumed in order
/// - Request with Insert on existing key -> mpf.insert fails
/// - Request with Delete on non-existent key -> mpf.delete fails
/// - Request with Update with wrong old value -> mpf.update fails
fn mkUpdate(tokenId, max_fee, process_time, validity_range) {
  fn(
    input: Input,
    acc: (
      MerklePatriciaForestry,
      List<Proof>,
      List<Pair<VerificationKeyHash, Int>>,
    ),
  ) -> (
    MerklePatriciaForestry,
    List<Proof>,
    List<Pair<VerificationKeyHash, Int>>,
  ) {
    when input.output.datum is {
      InlineDatum(datum) ->
        if datum is RequestDatum(request): CageDatum {
          let Request {
            requestToken,
            requestKey,
            requestValue,
            requestOwner,
            fee,
            submitted_at,
          } = request
          if requestToken == tokenId {
            // Fee must match the state's max_fee
            expect fee == max_fee
            // Request must be in Phase 1
            expect in_phase1(validity_range, submitted_at, process_time)
            let (root, proofs, refunds) = acc
            let proof, proofsTail <- uncons(proofs)
            let newRoot =
              when requestValue is {
                Insert(value) -> mpf.insert(root, requestKey, value, proof)
                Delete(value) -> mpf.delete(root, requestKey, value, proof)
                Update(oldValue, newValue) ->
                  mpf.update(root, requestKey, proof, oldValue, newValue)
              }
            // Compute refund: input lovelace minus fee
            let inputLovelace = assets.lovelace_of(input.output.value)
            let refundAmount = inputLovelace - fee
            let newRefunds =
              if refundAmount > 0 {
                [Pair(requestOwner, refundAmount), ..refunds]
              } else {
                refunds
              }
            (newRoot, proofsTail, newRefunds)
          } else {
            acc
          }
        } else {
          acc
        }
      _ -> acc
    }
  }
}

/// Verify that refund outputs match the expected refunds.
///
/// Walks the output list in parallel with the refunds list.
/// For each refund, checks that the output pays at least
/// the refund amount to the correct owner address.
fn verifyRefunds(
  outputs: List<Output>,
  refunds: List<Pair<VerificationKeyHash, Int>>,
) -> Bool {
  when refunds is {
    [] -> True
    [Pair(owner, amount), ..rest] -> {
      expect [output, ..remaining] = outputs
      expect address.VerificationKey(vkh) = output.address.payment_credential
      expect vkh == owner
      expect assets.lovelace_of(output.value) >= amount
      verifyRefunds(remaining, rest)
    }
  }
}

/// Validate that the MPF root was correctly updated.
///
/// This is the core validation for the `Modify` operation. It verifies
/// that the output's MPF root matches the result of folding all input
/// requests into the current MPF.
///
/// ## Parameters
/// - `state`: The current State from the input datum (has current root + owner)
/// - `input`: The Input being spent (the State UTxO, for address comparison)
/// - `tokenId`: The caged token's identifier
/// - `tx`: The full transaction context
/// - `proofs`: The list of Merkle proofs, one per request being processed
///
/// ## Algorithm
///
/// 1. **Extract output state**: Get the first output (`head(outputs)`) and
///    parse its inline datum as `StateDatum(State { root: newRoot, .. })`.
///    This is the claimed new state.
///
/// 2. **Compute expected root**: Fold over ALL transaction inputs using
///    `mkUpdate(tokenId)`. Starting from `(mpf.from_root(root), proofs)`,
///    each matching Request consumes a proof and updates the MPF.
///
/// 3. **Verify root**: Compare `mpf.root(expectedNewRoot) == newRoot`.
///    If they don't match, the transaction is rejected.
///
/// 4. **Verify address preservation**: The output's payment credential must
///    match the input's payment credential. This ensures the token stays
///    at the same script address (prevents stealing the token by sending
///    it to a different address).
///
/// ## Important: head(outputs)
/// The validator only checks the FIRST output. This means the transaction
/// builder must place the new State UTxO as the first output. Other outputs
/// (e.g., change, fee) can follow.
///
/// ## Important: Owner Not Checked
/// The validator does NOT verify that the owner field is preserved. The
/// output datum can have a different `owner` than the input. This enables
/// ownership transfer during a Modify operation.
///
/// ## Important: Unconsumed Proofs
/// After the fold, the remaining proofs list is discarded (`_`). This means
/// providing extra proofs does NOT cause failure. Only too few proofs
/// (when a matching request has no proof to consume) causes failure.
///
/// ## Security: Address Check
/// The `output.address.payment_credential == input.output.address.payment_credential`
/// check prevents a subtle attack: without it, the owner could Modify the
/// state and redirect the output to their wallet address, effectively
/// stealing the caged token.
///
/// ## Test Hints
/// - Correct root computation with one Insert request -> success
/// - Correct root computation with multiple requests -> success
/// - Wrong claimed root in output datum -> fail
/// - Output at different script address -> fail
/// - Output at wallet address -> fail
/// - Extra proofs provided -> success (extras ignored)
/// - Owner changed in output -> success
/// - Output is not first in outputs list -> depends on what's first
/// - No matching requests (empty fold) -> root unchanged, must match
fn validRootUpdate(
  state: State,
  input: Input,
  tokenId: TokenId,
  tx: Transaction,
  proofs: List<Proof>,
  process_time: Int,
) {
  let Transaction { outputs, inputs, validity_range, .. } = tx
  let State { root, max_fee, .. } = state
  expect Some(output) = head(outputs)
  expect InlineDatum(state) = output.datum
  expect StateDatum(State { root: newRoot, .. }) = state

  let (expectedNewRoot, _, refunds) =
    inputs
      |> foldl(
          (mpf.from_root(root), proofs, []),
          mkUpdate(tokenId, max_fee, process_time, validity_range),
        )
  expect (mpf.root(expectedNewRoot) == newRoot)?
  expect
    output.address.payment_credential == input.output.address.payment_credential

  // Verify refund outputs (starting after the State UTxO at index 0)
  expect [_, ..refundOutputs] = outputs
  let orderedRefunds = list.reverse(refunds)
  expect verifyRefunds(refundOutputs, orderedRefunds)
  True
}

/// Create a reject function for folding over inputs to collect refunds.
/// Like mkUpdate but: no proofs, no MPF operations, is_rejectable check.
fn mkReject(
  tokenId,
  max_fee,
  process_time,
  retract_time,
  validity_range,
) {
  fn(input: Input, refunds: List<Pair<VerificationKeyHash, Int>>) {
    when input.output.datum is {
      InlineDatum(datum) ->
        if datum is RequestDatum(request): CageDatum {
          let Request {
            requestToken,
            requestOwner,
            fee,
            submitted_at,
            ..
          } = request
          if requestToken == tokenId {
            expect fee == max_fee
            expect
              is_rejectable(
                validity_range,
                submitted_at,
                process_time,
                retract_time,
              )
            let inputLovelace = assets.lovelace_of(input.output.value)
            let refundAmount = inputLovelace - fee
            if refundAmount > 0 {
              [Pair(requestOwner, refundAmount), ..refunds]
            } else {
              refunds
            }
          } else {
            refunds
          }
        } else {
          refunds
        }
      _ -> refunds
    }
  }
}

/// Validate a Reject operation: discard expired/dishonest requests.
/// Root MUST NOT change. Refunds enforced for each rejected request.
fn validReject(
  state: State,
  input: Input,
  tokenId: TokenId,
  tx: Transaction,
  process_time: Int,
  retract_time: Int,
) {
  let Transaction { outputs, inputs, validity_range, .. } = tx
  let State { root, max_fee, .. } = state

  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(State { root: newRoot, .. }) = outState
  expect newRoot == root

  expect
    output.address.payment_credential == input.output.address.payment_credential

  let refunds =
    inputs
      |> foldl(
          [],
          mkReject(
            tokenId,
            max_fee,
            process_time,
            retract_time,
            validity_range,
          ),
        )

  expect [_, ..refundOutputs] = outputs
  let orderedRefunds = list.reverse(refunds)
  expect verifyRefunds(refundOutputs, orderedRefunds)
  True
}

/// Validate minting of a new caged token.
///
/// This function enforces all invariants for creating a new cage:
///
/// ## Parameters
/// - `minting`: The Mint redeemer containing the OutputReference for asset name
/// - `policyId`: This validator's own script hash (used as policy ID)
/// - `tx`: The full transaction context
///
/// ## Validation Steps (in order)
///
/// 1. **Compute asset name**: `assetName(asset)` hashes the OutputReference
///    to produce a unique 32-byte asset name.
///
/// 2. **Uniqueness source**: `find_input(inputs, asset)` checks that the
///    OutputReference is actually being consumed in this transaction.
///    Since a UTxO can only be spent once, this guarantees the same
///    asset name can never be minted again.
///    - If `asset` is not found in inputs -> `is_some` returns False -> fail
///
/// 3. **Quantity check**: `quantity(policyId, mint, tokenId)` looks up how
///    many tokens with this policy + asset name are in the mint field.
///    Must be exactly 1.
///    - If quantity is not 1 (e.g., 0, 2, -1) -> fail
///    - If token not in mint field at all -> None -> fail
///
/// 4. **Output destination**: The first output must go to this script's
///    address. Specifically:
///    a. `head(outputs)` gets the first output
///    b. `address.Script(targetScriptHash)` checks it's a script address
///    c. `targetScriptHash == policyId` checks it's THIS script
///    - If output goes to a wallet address -> fail
///    - If output goes to a different script -> fail
///
/// 5. **Initial datum**: The output must have an inline datum containing
///    `StateDatum(State { root: root(empty), owner: _ })`.
///    - The root must be `root(empty)` (empty MPF trie)
///    - The owner can be any VerificationKeyHash (chosen by the minter)
///    - If root is not empty -> fail
///    - If datum is not StateDatum -> fail
///    - If datum is not inline -> fail
///
/// ## Important: head(outputs)
/// Only the FIRST output is checked. The transaction can have additional
/// outputs (change, etc.) but the minted token must be in the first one.
///
/// ## Important: Owner is Unrestricted
/// The minting transaction can set any `owner` in the initial State datum.
/// This means Alice can mint a cage and immediately assign ownership to Bob.
///
/// ## Test Hints
/// - Happy path: valid OutputReference, quantity 1, correct address, empty root -> True
/// - OutputReference not in inputs -> fail
/// - Quantity 2 -> fail
/// - Quantity 0 -> fail
/// - Output to wallet address -> fail
/// - Output to different script -> fail
/// - Non-empty initial root -> fail
/// - Datum is RequestDatum instead of StateDatum -> fail
/// - No inline datum -> fail
/// - Asset name doesn't match hash of OutputReference -> impossible (computed internally)
pub fn validateMint(minting: Mint, policyId: PolicyId, tx: Transaction) {
  let Mint { asset } = minting
  let Transaction { outputs, mint, inputs, .. } = tx
  // Compute the unique asset name from the OutputReference hash
  let tokenId = TokenId { assetName: assetName(asset) }
  // Verify the OutputReference is consumed in this transaction.
  // This is the uniqueness guarantee: once spent, this UTxO can never
  // be used to mint the same asset name again.
  expect is_some(find_input(inputs, asset))
  // Verify exactly one token is minted with this policy + asset name.
  // The quantity function returns None if the token is absent, or
  // Some(n) with the quantity. We require exactly 1.
  expect
    when quantity(policyId, mint, tokenId) is {
      Some(quantity) -> quantity == 1
      None -> False
    }
  // Get the first output -- this must be the State UTxO with the caged token.
  expect Some(output) = head(outputs)
  // Verify the output goes to a script address (not a wallet)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  // Verify the output goes to THIS script (policy ID == script hash)
  expect targetScriptHash == policyId
  // Verify the output has an inline datum
  expect InlineDatum(tokenState) = output.datum
  // Verify the datum is a StateDatum with an empty MPF root.
  // The owner field is unconstrained (any VerificationKeyHash is fine).
  expect StateDatum(State { root: tokenRoot, owner: _, max_fee: _ }) = tokenState
  // The initial MPF root must be the hash of an empty trie.
  // `root(empty)` computes this known constant value.
  expect tokenRoot == root(empty)
  True
}

/// Validate migration of a caged token from an old validator.
///
/// This function mints a new token under the new policy while verifying
/// that the old token is burned atomically. The MPF root is carried over
/// (no empty root check), preserving the existing data.
///
/// Uniqueness is guaranteed by the burn: the old token can only be burned
/// once, so this migration mint can only succeed once.
pub fn validateMigration(
  migration: Migration,
  policyId: PolicyId,
  tx: Transaction,
) {
  let Migration { oldPolicy, tokenId } = migration
  let Transaction { outputs, mint, .. } = tx
  // Verify the old token is burned (quantity -1 under old policy)
  expect
    when quantity(oldPolicy, mint, tokenId) is {
      Some(qty) -> qty == -1
      None -> False
    }
  // Verify exactly one new token is minted (quantity +1 under new policy)
  expect
    when quantity(policyId, mint, tokenId) is {
      Some(qty) -> qty == 1
      None -> False
    }
  // Standard boot checks (same as validateMint, minus root check)
  expect Some(output) = head(outputs)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  expect targetScriptHash == policyId
  expect InlineDatum(tokenState) = output.datum
  expect StateDatum(State { root: _, owner: _, max_fee: _ }) = tokenState
  True
}


