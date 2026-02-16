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

use aiken/collection/list.{find, foldl, has, head}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, Proof, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use aiken/fuzz
use cardano/address.{from_script}
use cardano/address
use cardano/assets.{PolicyId, from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, find_input,
}
use lib.{TokenId, assetName, quantity, tokenFromValue, valueFromToken}
use types.{
  Burning, CageDatum, Contribute, Delete, End, Insert, Mint, MintRedeemer, Minting,
  Modify, Request, RequestDatum, Retract, State, StateDatum, Update, UpdateRedeemer,
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
validator mpfCage {
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
        // Only valid for Request UTxOs. Allows the request creator to
        // reclaim their UTxO (and its ADA) if the cage owner hasn't
        // processed the request yet.
        //
        // Fail if datum is not a RequestDatum (e.g., if someone tries
        // to Retract a State UTxO, this expect will fail)
        expect RequestDatum(request) = datum
        // Extract the request owner's verification key hash
        let Request { requestOwner, .. } = request
        let Transaction { extra_signatories, .. } = tx
        // Fail if the request owner hasn't signed the transaction.
        // This ensures only the original request creator can retract.
        // Note: no other checks are needed -- the request UTxO is simply
        // consumed, and its ADA goes wherever the transaction specifies.
        expect has(extra_signatories, requestOwner)
        True
      }
      Contribute(tokenRef) -> {
        // --- CONTRIBUTE PATH ---
        // Valid for Request UTxOs. This is a permissionless operation
        // that validates a request targets the correct caged token.
        //
        // The `tokenRef` is the OutputReference of the State UTxO that
        // holds the caged NFT. The validator looks up this input and
        // extracts the token to compare against the request's target.
        //
        // Fail if datum is not a RequestDatum
        expect RequestDatum(request) = datum
        // Validate that the request's target token matches the actual
        // token at tokenRef. This prevents requests from being applied
        // to the wrong cage.
        validRequest(request, tokenRef, tx)
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
          Modify(proofs) -> validRootUpdate(state, input, tokenId, tx, proofs)
          End -> validateEnd(tokenId, tx)
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
/// Checks that the mint field contains the same token as the one being spent.
/// The minting policy and ledger ensure the quantity is exactly -1.
///
/// ## How It Works
/// 1. Extract the single non-ADA token from the transaction's mint field
///    (the mint field acts like a Value, with negative quantities for burns)
/// 2. Compare the extracted token ID with the token from the State UTxO
/// 3. If they match, the burn is valid
///
/// ## Why This Is Sufficient
/// The Cardano ledger enforces that if a token appears in the mint field
/// with quantity -1, then that many tokens are destroyed. The minting
/// policy (`Burning` redeemer) has already been invoked and approved.
/// Combined with `validateOwnership` (called before this function), we
/// know the cage owner authorized the burn.
///
/// ## What About tokenFromValue on the Mint Field?
/// The mint field is treated as a Value, but it contains only minted/burned
/// tokens (no ADA). `tokenFromValue` removes the ADA policy ("") and expects
/// exactly one remaining policy with one asset name. For a valid End
/// transaction, the mint field should contain exactly one burned token.
///
/// ## Test Hints
/// - Mint field contains the same token (quantity -1) -> success
/// - Mint field contains a different token -> fail
/// - Mint field is empty -> fail (tokenFromValue returns None)
/// - Mint field contains multiple tokens -> fail (tokenFromValue returns None)
/// - Mint field contains the token with quantity -2 -> tokenFromValue still
///   succeeds (it ignores quantity), but the ledger would reject the tx
fn validateEnd(tokenId, tx) {
  let Transaction { mint, .. } = tx
  // Extract the single token from the mint field. Fails if there isn't
  // exactly one non-ADA token being minted/burned.
  expect Some(mintToken) = tokenFromValue(mint)
  // Ensure the burned token is the same as the one in the State UTxO.
  // This prevents burning a different token while keeping the caged one.
  expect tokenId == mintToken
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
fn validRequest(request: Request, tokenRef: OutputReference, tx: Transaction) {
  let Request { requestToken, .. } = request
  let (_input, tokenId) = extractToken(tokenRef, tx)
  expect requestToken == tokenId
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
fn mkUpdate(tokenId) {
  fn(input: Input, acc: (MerklePatriciaForestry, List<Proof>)) -> (
    MerklePatriciaForestry,
    List<Proof>,
  ) {
    when input.output.datum is {
      InlineDatum(datum) ->
        // Try to interpret the datum as a CageDatum with a RequestDatum variant.
        // If the datum is not a CageDatum or is a StateDatum, the `if` fails
        // and we skip this input (fall through to `else -> acc`).
        if datum is RequestDatum(request): CageDatum {
          let Request { requestToken, requestKey, requestValue, .. } = request
          // Only process requests that target THIS specific caged token.
          // Requests for other tokens are silently skipped.
          if requestToken == tokenId {
            let (root, proofs) = acc
            // Consume the next proof from the list. If no proofs remain,
            // this fails and the entire transaction is rejected. This
            // enforces the invariant: one proof per matching request.
            let proof, proofsTail <- uncons(proofs)
            // Apply the MPF operation using the consumed proof.
            // Each mpf.* function verifies the proof against the current
            // root and returns the new root. If the proof is invalid
            // (doesn't match the current trie state), it fails.
            let newRoot =
              when requestValue is {
                Insert(value) -> mpf.insert(root, requestKey, value, proof)
                Delete(value) -> mpf.delete(root, requestKey, value, proof)
                Update(oldValue, newValue) ->
                  mpf.update(root, requestKey, proof, oldValue, newValue)
              }
            (newRoot, proofsTail)
          } else {
            // Request targets a different token -- skip without consuming a proof
            acc
          }
        } else {
          // Datum is not a RequestDatum (e.g., StateDatum or foreign datum) -- skip
          acc
        }
      // Input has no inline datum (e.g., NoDatum or DatumHash) -- skip
      _ -> acc
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
) {
  let Transaction { outputs, inputs, .. } = tx
  let State { root, .. } = state
  // Get the first output and extract the new state from its datum.
  // The transaction builder must put the State UTxO as the first output.
  expect Some(output) = head(outputs)
  expect InlineDatum(state) = output.datum
  expect StateDatum(State { root: newRoot, .. }) = state

  // Fold all transaction inputs, applying matching requests to the MPF.
  // Starting state: current MPF root + all proofs.
  // After fold: computed new root + remaining (unconsumed) proofs.
  let (expectedNewRoot, _) =
    inputs |> foldl((mpf.from_root(root), proofs), mkUpdate(tokenId))
  // Verify the output's claimed root matches our computation.
  // mpf.root() extracts the raw ByteArray hash from the MerklePatriciaForestry.
  expect (mpf.root(expectedNewRoot) == newRoot)?
  // Ensure the token stays at the same script address.
  // Compares payment credentials (script hashes) between input and output.
  // This prevents redirecting the State UTxO to a different address.
  expect
    output.address.payment_credential == input.output.address.payment_credential
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
  expect StateDatum(State { root: tokenRoot, owner: _ }) = tokenState
  // The initial MPF root must be the hash of an empty trie.
  // `root(empty)` computes this known constant value.
  expect tokenRoot == root(empty)
  True
}

// ============================================================================
// Tests
// ============================================================================

// Test constants: a script address used for all test UTxOs
const testScriptAddress = from_script("counter_cage")

// Test constants: output references for State and Request UTxOs
const testStateRef =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

const testRequestRef =
  OutputReference { transaction_id: "2234567890abcdef", output_index: 254 }

// Test constants: a token ID and its corresponding value
const testToken = TokenId { assetName: "asset_name" }

const testValue = valueFromToken("policy_id", testToken)

// Test constants: a State with the owner "owner" and an empty MPF root
const state = State { owner: "owner", root: root(mpf.empty) }

const stateDatum = Some(StateDatum(state))

// Test constants: a Request that inserts key "42" with value "42"
const aRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      requestValue: Insert("42"),
      requestOwner: "owner",
    },
  )

// Test constants: the State UTxO input (holds the token + state datum)
const update =
  Input {
    output_reference: testStateRef,
    output: Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(stateDatum),
      reference_script: None,
    },
  }

// Test constants: the Request UTxO input (holds ADA + request datum)
const request =
  Input {
    output_reference: testRequestRef,
    output: Output {
      address: testScriptAddress,
      value: from_lovelace(0),
      datum: InlineDatum(aRequest),
      reference_script: None,
    },
  }

// Test constants: the expected output after Modify with the Insert request.
// The root hash is pre-computed: it's the MPF root after inserting key "42"
// with value "42" into an empty trie.
// Note: the owner is changed to "new-owner" to demonstrate ownership transfer.
const output =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          owner: "new-owner",
          root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
        },
      ),
    ),
    reference_script: None,
  }

// Test: Modify + Contribute in a single test.
//
// This test verifies two things:
// 1. A Modify transaction with one Insert request and one proof (empty proof [])
//    correctly updates the MPF root from empty to the expected hash.
// 2. A Contribute transaction validates that the request's target token matches
//    the actual token at the referenced State UTxO.
//
// The test uses && to combine both assertions. Both must pass for the test to succeed.
test canCage() {
  mpfCage.spend(
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  ) && mpfCage.spend(
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction { ..transaction.placeholder, inputs: [update, request] },
  )
}

// Test constants for minting: reuse testStateRef as the consumed OutputReference
const reference =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

// The token's asset name is derived from the OutputReference hash
const token = TokenId { assetName: assetName(reference) }

// The Mint redeemer pointing to the consumed OutputReference
const minting = Mint { asset: reference}

// The value containing exactly 1 of the minted token
const minted_value = valueFromToken("policy_id", token)

// The output address must be the script address with the same policy ID
const output_address = address.from_script("policy_id")

// The expected output: token at the script address with empty MPF root
const minted =
  Output {
    address: output_address,
    value: minted_value,
    datum: InlineDatum(
      StateDatum(State { owner: "owner", root: root(empty) }),
    ),
    reference_script: None,
  }

// The wallet address that owns the consumed UTxO (source of uniqueness)
const paying_address = address.from_verification_key("paying_address")

// The consumed UTxO (any value works, even zero)
const consumed_value = zero

const consumed_utxo =
  Output {
    address: paying_address,
    value: consumed_value,
    datum: NoDatum,
    reference_script: None,
  }

// Test: Minting a new caged token.
//
// Verifies that the minting policy accepts a valid mint transaction where:
// - The OutputReference is consumed (present in inputs)
// - Exactly 1 token is minted
// - The output goes to the correct script address
// - The output datum has an empty MPF root
test canMint() {
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction {
      ..transaction.placeholder,
      outputs: [minted],
      mint: minted_value,
      inputs: [Input { output_reference: reference, output: consumed_utxo }],
    },
  )
}

// ============================================================================
// Minting failure tests
// ============================================================================

// Helper: valid mint transaction (reusable base for failure tests)
fn mint_tx() -> Transaction {
  Transaction {
    ..transaction.placeholder,
    outputs: [minted],
    mint: minted_value,
    inputs: [Input { output_reference: reference, output: consumed_utxo }],
  }
}

test mint_missing_input() fail {
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), inputs: [] },
  )
}

test mint_quantity_two() fail {
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction {
      ..mint_tx(),
      mint: from_asset("policy_id", assetName(reference), 2),
    },
  )
}

test mint_to_wallet() fail {
  let wallet_output =
    Output { ..minted, address: address.from_verification_key("someone") }
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [wallet_output] },
  )
}

test mint_to_wrong_script() fail {
  let wrong_output =
    Output { ..minted, address: address.from_script("other_script") }
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [wrong_output] },
  )
}

test mint_nonempty_root() fail {
  let bad_output =
    Output {
      ..minted,
      datum: InlineDatum(
        StateDatum(State { owner: "owner", root: "nonempty_root" }),
      ),
    }
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

test mint_request_datum() fail {
  let bad_output =
    Output {
      ..minted,
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: token,
            requestKey: "k",
            requestValue: Insert("v"),
            requestOwner: "owner",
          },
        ),
      ),
    }
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

test mint_no_datum() fail {
  let bad_output = Output { ..minted, datum: NoDatum }
  mpfCage.mint(
    Minting(minting),
    "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

// ============================================================================
// Retract tests
// ============================================================================

test retract_happy() {
  mpfCage.spend(
    Some(aRequest),
    Retract,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
    },
  )
}

test retract_wrong_signer() fail {
  mpfCage.spend(
    Some(aRequest),
    Retract,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["someone_else"],
    },
  )
}

// ============================================================================
// Contribute tests
// ============================================================================

test contribute_wrong_token() fail {
  let wrong_request =
    RequestDatum(
      Request {
        requestToken: TokenId { assetName: "different_asset" },
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "owner",
      },
    )
  mpfCage.spend(
    Some(wrong_request),
    Contribute(testStateRef),
    testRequestRef,
    Transaction { ..transaction.placeholder, inputs: [update, request] },
  )
}

test contribute_missing_ref() fail {
  let missing_ref =
    OutputReference { transaction_id: "nonexistent", output_index: 0 }
  mpfCage.spend(
    Some(aRequest),
    Contribute(missing_ref),
    testRequestRef,
    Transaction { ..transaction.placeholder, inputs: [update, request] },
  )
}

// ============================================================================
// Modify tests
// ============================================================================

test modify_missing_signature() fail {
  mpfCage.spend(
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [output],
      extra_signatories: [],
      inputs: [update, request],
    },
  )
}

test modify_wrong_address() fail {
  let bad_output =
    Output {
      ..output,
      address: address.from_script("different_script"),
    }
  mpfCage.spend(
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [bad_output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

test modify_owner_transfer() {
  // output already has owner: "new-owner", this should succeed
  mpfCage.spend(
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

test modify_no_requests() {
  // No request inputs -> root stays the same (empty MPF root)
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(State { owner: "owner", root: root(empty) }),
      ),
      reference_script: None,
    }
  mpfCage.spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [unchanged_output],
      extra_signatories: ["owner"],
      inputs: [update],
    },
  )
}

test modify_skip_other_token() {
  // Request for a different token — should be skipped, no proof consumed
  let other_request_datum =
    RequestDatum(
      Request {
        requestToken: TokenId { assetName: "other_token" },
        requestKey: "42",
        requestValue: Insert("42"),
        requestOwner: "someone",
      },
    )
  let other_request =
    Input {
      output_reference: OutputReference {
        transaction_id: "3334567890abcdef",
        output_index: 1,
      },
      output: Output {
        address: testScriptAddress,
        value: from_lovelace(0),
        datum: InlineDatum(other_request_datum),
        reference_script: None,
      },
    }
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(State { owner: "owner", root: root(empty) }),
      ),
      reference_script: None,
    }
  mpfCage.spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [unchanged_output],
      extra_signatories: ["owner"],
      inputs: [update, other_request],
    },
  )
}

test modify_too_few_proofs() fail {
  // One matching request but zero proofs
  mpfCage.spend(
    stateDatum,
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

test modify_extra_proofs() {
  // One matching request, two proofs — extra proof is ignored
  mpfCage.spend(
    stateDatum,
    Modify([[], []]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

test modify_wrong_root() fail {
  let bad_root_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(State { owner: "new-owner", root: "wrong_root_hash" }),
      ),
      reference_script: None,
    }
  mpfCage.spend(
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [bad_root_output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  )
}

// ============================================================================
// End tests
// ============================================================================

// End needs: owner signs + mint field contains the token being burned
const burn_value = valueFromToken("policy_id", testToken)

test end_happy() {
  mpfCage.spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: burn_value,
    },
  )
}

test end_missing_signature() fail {
  mpfCage.spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: [],
      inputs: [update],
      mint: burn_value,
    },
  )
}

test end_wrong_token_in_mint() fail {
  let wrong_burn = valueFromToken("policy_id", TokenId { assetName: "wrong" })
  mpfCage.spend(
    stateDatum,
    End,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [update],
      mint: wrong_burn,
    },
  )
}

// ============================================================================
// Datum-redeemer mismatch tests
// ============================================================================

test retract_on_state_datum() fail {
  mpfCage.spend(
    stateDatum,
    Retract,
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
    },
  )
}

test contribute_on_state_datum() fail {
  mpfCage.spend(
    stateDatum,
    Contribute(testStateRef),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      inputs: [update],
    },
  )
}

test modify_on_request_datum() fail {
  mpfCage.spend(
    Some(aRequest),
    Modify([]),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [request],
    },
  )
}

test end_on_request_datum() fail {
  mpfCage.spend(
    Some(aRequest),
    End,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [request],
      mint: burn_value,
    },
  )
}

// ============================================================================
// Edge cases
// ============================================================================

test spend_no_datum() fail {
  mpfCage.spend(
    None,
    Retract,
    testRequestRef,
    transaction.placeholder,
  )
}

// ============================================================================
// Property tests
// ============================================================================

fn owner_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.bytearray_fixed(28)
}

test prop_retract_requires_owner(
  signer via owner_fuzzer(),
) fail once {
  let req =
    RequestDatum(
      Request {
        requestToken: testToken,
        requestKey: "k",
        requestValue: Insert("v"),
        requestOwner: "the_real_owner_key_aaaaaaaaaa",
      },
    )
  mpfCage.spend(
    Some(req),
    Retract,
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: [signer],
    },
  )
}

test prop_modify_requires_owner(
  signer via owner_fuzzer(),
) fail once {
  let s = State { owner: "the_real_owner_key_aaaaaaaaaa", root: root(empty) }
  let unchanged_output =
    Output {
      address: testScriptAddress,
      value: testValue,
      datum: InlineDatum(
        StateDatum(State { owner: "the_real_owner_key_aaaaaaaaaa", root: root(empty) }),
      ),
      reference_script: None,
    }
  let state_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(Some(StateDatum(s))),
        reference_script: None,
      },
    }
  mpfCage.spend(
    Some(StateDatum(s)),
    Modify([]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      outputs: [unchanged_output],
      extra_signatories: [signer],
      inputs: [state_input],
    },
  )
}

test prop_mint_roundtrip(
  params via fuzz.tuple(
    fuzz.bytearray_fixed(32),
    fuzz.int_between(0, 255),
  ),
) {
  let (tx_id, idx) = params
  let ref = OutputReference { transaction_id: tx_id, output_index: idx }
  let tok = TokenId { assetName: assetName(ref) }
  let mint_redeemer = Mint { asset: ref }
  let val = valueFromToken("policy_id", tok)
  let addr = address.from_script("policy_id")
  let out =
    Output {
      address: addr,
      value: val,
      datum: InlineDatum(
        StateDatum(State { owner: "owner", root: root(empty) }),
      ),
      reference_script: None,
    }
  let utxo =
    Output {
      address: paying_address,
      value: zero,
      datum: NoDatum,
      reference_script: None,
    }
  mpfCage.mint(
    Minting(mint_redeemer),
    "policy_id",
    Transaction {
      ..transaction.placeholder,
      outputs: [out],
      mint: val,
      inputs: [Input { output_reference: ref, output: utxo }],
    },
  )
}
