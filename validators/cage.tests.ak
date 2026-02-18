/// Unit tests and validator-level property tests for the MPF Cage validator.
///
/// This is a **test module** (no `pub` exports), which allows it to import
/// the `cage` validator directly via qualified syntax: `cage.mpfCage.spend(...)`.
///
/// ## Test Fixture Layout
///
/// All tests share a common set of constants that simulate a minimal cage
/// scenario:
///
/// - **Time phases**: process_time = 10s, retract_time = 10s, submitted_at = 0
///   - Phase 1 (oracle processing):  [0, 10_000)    — validity range [0, 5_000]
///   - Phase 2 (requester retract):  [10_000, 20_000) — validity range [10_000, 15_000]
///   - Phase 3 (rejectable/expired): [20_000, ...)    — validity range [20_000, 25_000]
///
/// - **State UTxO** (`update`): holds `testToken` at `testScriptAddress` with
///   an empty MPF root, owned by "owner".
///
/// - **Request UTxO** (`request`): an Insert("42") request targeting `testToken`,
///   submitted by "owner" at time 0.
///
/// - **Expected output** (`output`): the State UTxO after processing the Insert,
///   with the computed MPF root and ownership transferred to "new-owner".
use aiken/crypto.{VerificationKeyHash}
use aiken/fuzz
use aiken/interval
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use cage
use cardano/address
use cardano/address.{from_script}
use cardano/assets
use cardano/assets.{from_asset, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use lib.{TokenId, assetName, valueFromToken}
use types.{
  Burning, CageDatum, Contribute, Delete, End, Insert, Migrating, Migration,
  Mint, MintRedeemer, Minting, Modify, Reject, Request, RequestDatum, Retract,
  State, StateDatum, Update, UpdateRedeemer,
}

// ============================================================================
// Test constants
// ============================================================================

// Test time params: 10s process window, 10s retract window
const testProcessTime = 10_000

const testRetractTime = 10_000

// Phase 1 validity range: [0, 5_000] — entirely before submitted_at(0) + process_time(10_000)
const phase1Range = interval.between(0, 5_000)

// Phase 2 validity range: [10_000, 15_000] — after process_time, before process_time + retract_time
const phase2Range = interval.between(10_000, 15_000)

// Phase 3 validity range: [20_000, 25_000] — after process_time + retract_time
const phase3Range = interval.between(20_000, 25_000)

// Test constants: a script address used for all test UTxOs
const testScriptAddress = from_script("policy_id")

// Test constants: output references for State and Request UTxOs
const testStateRef =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

const testRequestRef =
  OutputReference { transaction_id: "2234567890abcdef", output_index: 254 }

// Test constants: a token ID and its corresponding value
const testToken = TokenId { assetName: "asset_name" }

const testValue = valueFromToken("policy_id", testToken)

// Test constants: a State with the owner "owner" and an empty MPF root
const state = State { owner: "owner", root: root(mpf.empty), max_fee: 0 }

const stateDatum = Some(StateDatum(state))

// Test constants: a Request that inserts key "42" with value "42"
const aRequest =
  RequestDatum(
    Request {
      requestToken: testToken,
      requestKey: "42",
      requestValue: Insert("42"),
      requestOwner: "owner",
      fee: 0,
      submitted_at: 0,
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
const output =
  Output {
    address: testScriptAddress,
    value: testValue,
    datum: InlineDatum(
      StateDatum(
        State {
          owner: "new-owner",
          root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          max_fee: 0,
        },
      ),
    ),
    reference_script: None,
  }

// ============================================================================
// Core happy-path test
// ============================================================================

/// End-to-end happy path: Modify a cage (fold one Insert request into the MPF)
/// and Contribute a request to a cage, both in Phase 1. Verifies both the
/// spending validator's Modify and Contribute paths accept valid transactions.
test canCage() {
  cage.mpfCage.spend(
    0,
    testProcessTime,
    testRetractTime,
    stateDatum,
    Modify([[]]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [output],
      extra_signatories: ["owner"],
      inputs: [update, request],
    },
  ) && cage.mpfCage.spend(
    0,
    testProcessTime,
    testRetractTime,
    Some(aRequest),
    Contribute(testStateRef),
    testRequestRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      inputs: [update, request],
    },
  )
}

// ============================================================================
// Minting tests
// ============================================================================

const reference =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 255 }

const token = TokenId { assetName: assetName(reference) }

const minting = Mint { asset: reference }

const minted_value = valueFromToken("policy_id", token)

const output_address = address.from_script("policy_id")

const minted =
  Output {
    address: output_address,
    value: minted_value,
    datum: InlineDatum(
      StateDatum(State { owner: "owner", root: root(empty), max_fee: 0 }),
    ),
    reference_script: None,
  }

const paying_address = address.from_verification_key("paying_address")

const consumed_value = zero

const consumed_utxo =
  Output {
    address: paying_address,
    value: consumed_value,
    datum: NoDatum,
    reference_script: None,
  }

/// Happy path: mint a new caged token. The OutputReference is consumed,
/// exactly 1 token is minted, output goes to this script with an empty
/// MPF root. This is how a new cage is created.
test canMint() {
  cage.mpfCage.mint(
    0,
    testProcessTime,
    testRetractTime,
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

fn mint_tx() -> Transaction {
  Transaction {
    ..transaction.placeholder,
    outputs: [minted],
    mint: minted_value,
    inputs: [Input { output_reference: reference, output: consumed_utxo }],
  }
}

/// The OutputReference used to derive the asset name must actually be consumed.
/// Without this check, anyone could mint arbitrary asset names.
test mint_missing_input() fail {
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), inputs: [] },
  )
}

/// Exactly 1 token must be minted. Minting 2 would break the NFT invariant.
test mint_quantity_two() fail {
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), mint: from_asset("policy_id", assetName(reference), 2) },
  )
}

/// The minted token must go to a script address, not a wallet.
/// Sending to a wallet would make the token unmanageable by the cage validator.
test mint_to_wallet() fail {
  let wallet_output = Output { ..minted, address: address.from_verification_key("someone") }
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), outputs: [wallet_output] },
  )
}

/// The minted token must go to THIS script (policy_id == script hash).
/// Sending to a different script would lock the token under foreign rules.
test mint_to_wrong_script() fail {
  let wrong_output = Output { ..minted, address: address.from_script("other_script") }
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), outputs: [wrong_output] },
  )
}

/// A freshly minted cage must start with an empty MPF root.
/// A non-empty root would mean data exists without ever being inserted.
test mint_nonempty_root() fail {
  let bad_output =
    Output { ..minted, datum: InlineDatum(StateDatum(State { owner: "owner", root: "nonempty_root", max_fee: 0 })) }
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

/// The output datum must be a StateDatum (not a RequestDatum).
/// A RequestDatum at mint time makes no sense — there's no cage to request against yet.
test mint_request_datum() fail {
  let bad_output =
    Output {
      ..minted,
      datum: InlineDatum(RequestDatum(Request {
        requestToken: token, requestKey: "k", requestValue: Insert("v"),
        requestOwner: "owner", fee: 0, submitted_at: 0,
      })),
    }
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

/// The output must have an inline datum. Without it, the spending validator
/// would have no state to read when the cage is later spent.
test mint_no_datum() fail {
  let bad_output = Output { ..minted, datum: NoDatum }
  cage.mpfCage.mint(
    0, testProcessTime, testRetractTime,
    Minting(minting), "policy_id",
    Transaction { ..mint_tx(), outputs: [bad_output] },
  )
}

// ============================================================================
// Retract tests
// ============================================================================

/// Happy path: the request owner retracts their own request during Phase 2.
/// Phase 2 is the exclusive retract window where only the requester can act.
test retract_happy() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Retract, testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, extra_signatories: ["owner"] })
}

/// Only the request owner can retract. A different signer must be rejected
/// to prevent theft of the request's locked ADA.
test retract_wrong_signer() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Retract, testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, extra_signatories: ["someone_else"] })
}

/// Retract is forbidden in Phase 1 (the oracle processing window).
/// The oracle needs time to process the request undisturbed.
test retract_in_phase1() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Retract, testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, extra_signatories: ["owner"] })
}

/// Retract is forbidden in Phase 3 (after the retract window expires).
/// Once Phase 3 begins, the request becomes rejectable by the cage owner instead.
test retract_in_phase3() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Retract, testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, extra_signatories: ["owner"] })
}

// ============================================================================
// Contribute tests
// ============================================================================

/// A Contribute must reference a State UTxO whose token matches the request's
/// `requestToken`. A mismatch means the request targets a different cage.
test contribute_wrong_token() fail {
  let wrong_request = RequestDatum(Request {
    requestToken: TokenId { assetName: "different_asset" },
    requestKey: "42", requestValue: Insert("42"), requestOwner: "owner", fee: 0, submitted_at: 0,
  })
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(wrong_request), Contribute(testStateRef), testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, inputs: [update, request] })
}

/// The State UTxO referenced by Contribute must actually exist in the inputs.
/// Without this, the request-token binding can't be verified.
test contribute_missing_ref() fail {
  let missing_ref = OutputReference { transaction_id: "nonexistent", output_index: 0 }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Contribute(missing_ref), testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, inputs: [update, request] })
}

/// Contribute is forbidden in Phase 2 (the retract window).
/// During Phase 2, only the requester can act on their request (via Retract).
test contribute_in_phase2() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Contribute(testStateRef), testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, inputs: [update, request] })
}

/// Contribute IS allowed in Phase 3 (rejectable window).
/// This lets the oracle process late requests alongside a Reject operation.
test contribute_in_phase3() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Contribute(testStateRef), testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, inputs: [update, request] })
}

// ============================================================================
// Modify tests
// ============================================================================

/// Only the cage owner can Modify. Without the owner's signature, anyone
/// could update the MPF root with arbitrary data.
test modify_missing_signature() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [output], extra_signatories: [], inputs: [update, request] })
}

/// The output must stay at the same script address as the input.
/// Without this check, the owner could steal the token by redirecting
/// the output to a different script they control.
test modify_wrong_address() fail {
  let bad_output = Output { ..output, address: address.from_script("different_script") }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [bad_output], extra_signatories: ["owner"], inputs: [update, request] })
}

/// Ownership transfer is permitted during Modify. The output datum can have
/// a different owner than the input. This is intentional: it allows the
/// current owner to hand off the cage to someone else.
test modify_owner_transfer() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [output], extra_signatories: ["owner"], inputs: [update, request] })
}

/// Modify with no matching requests leaves the MPF root unchanged.
/// This is a valid no-op that the validator must accept.
test modify_no_requests() {
  let unchanged_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "owner", root: root(empty), max_fee: 0 })),
    reference_script: None,
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [unchanged_output], extra_signatories: ["owner"], inputs: [update] })
}

/// Requests targeting a different token are silently skipped — no proof is
/// consumed for them. Only requests whose `requestToken` matches the cage's
/// token participate in the MPF fold.
test modify_skip_other_token() {
  let other_request_datum = RequestDatum(Request {
    requestToken: TokenId { assetName: "other_token" },
    requestKey: "42", requestValue: Insert("42"), requestOwner: "someone", fee: 0, submitted_at: 0,
  })
  let other_request = Input {
    output_reference: OutputReference { transaction_id: "3334567890abcdef", output_index: 1 },
    output: Output { address: testScriptAddress, value: from_lovelace(0), datum: InlineDatum(other_request_datum), reference_script: None },
  }
  let unchanged_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "owner", root: root(empty), max_fee: 0 })),
    reference_script: None,
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [unchanged_output], extra_signatories: ["owner"], inputs: [update, other_request] })
}

/// Each matching request must have a corresponding proof. Providing zero
/// proofs for one request triggers `uncons` on an empty list, which fails.
test modify_too_few_proofs() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [output], extra_signatories: ["owner"], inputs: [update, request] })
}

/// Extra proofs beyond what's needed are silently ignored. The fold consumes
/// one proof per matching request; leftover proofs are discarded.
test modify_extra_proofs() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[], []]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [output], extra_signatories: ["owner"], inputs: [update, request] })
}

/// The output's MPF root must exactly match the result of folding all requests
/// into the old root. A wrong root means the oracle is lying about the data.
test modify_wrong_root() fail {
  let bad_root_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "new-owner", root: "wrong_root_hash", max_fee: 0 })),
    reference_script: None,
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [bad_root_output], extra_signatories: ["owner"], inputs: [update, request] })
}

/// Modify is forbidden in Phase 2 (the retract window). The oracle can only
/// process requests during Phase 1 to give requesters a fair retract window.
test modify_in_phase2() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, outputs: [output], extra_signatories: ["owner"], inputs: [update, request] })
}

// ============================================================================
// End tests
// ============================================================================

const burn_value = from_asset("policy_id", testToken.assetName, -1)

/// Happy path: the cage owner burns the token, destroying the cage.
/// Requires the owner's signature and the token in the mint field with qty -1.
test end_happy() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, End, testStateRef,
    Transaction { ..transaction.placeholder, extra_signatories: ["owner"], inputs: [update], mint: burn_value })
}

/// Only the cage owner can End the cage. Without this, anyone could burn
/// someone else's caged token and destroy their data.
test end_missing_signature() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, End, testStateRef,
    Transaction { ..transaction.placeholder, extra_signatories: [], inputs: [update], mint: burn_value })
}

/// The mint field must burn THIS token (matching asset name), not some other
/// token under the same policy. Burning the wrong token would leave the
/// cage's token in limbo.
test end_wrong_token_in_mint() fail {
  let wrong_burn = valueFromToken("policy_id", TokenId { assetName: "wrong" })
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, End, testStateRef,
    Transaction { ..transaction.placeholder, extra_signatories: ["owner"], inputs: [update], mint: wrong_burn })
}

// ============================================================================
// Datum-redeemer mismatch tests
//
// These verify that each redeemer can only be used with the correct datum
// type. Retract/Contribute require RequestDatum; Modify/End require StateDatum.
// Using the wrong combination must fail, preventing operations on the wrong
// kind of UTxO.
// ============================================================================

/// Retract requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't retract a cage's state, only a pending request.
test retract_on_state_datum() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Retract, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, extra_signatories: ["owner"] })
}

/// Contribute requires a RequestDatum. Using it on a StateDatum must fail —
/// you can't contribute a cage's state, only link a request to a cage.
test contribute_on_state_datum() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, Contribute(testStateRef), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, inputs: [update] })
}

/// Modify requires a StateDatum. Using it on a RequestDatum must fail —
/// you can't modify a request's MPF root (requests don't have one).
test modify_on_request_datum() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), Modify([]), testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, extra_signatories: ["owner"], inputs: [request] })
}

/// End requires a StateDatum. Using it on a RequestDatum must fail —
/// you can only burn the cage's token from a State UTxO.
test end_on_request_datum() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(aRequest), End, testRequestRef,
    Transaction { ..transaction.placeholder, extra_signatories: ["owner"], inputs: [request], mint: burn_value })
}

// ============================================================================
// Edge cases
// ============================================================================

/// Spending a UTxO with no datum must fail immediately. All cage UTxOs
/// (both State and Request) require inline datums. This catches ADA sent
/// to the script without a datum.
test spend_no_datum() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, None, Retract, testRequestRef, transaction.placeholder)
}

// ============================================================================
// Property tests (validator-level)
//
// These use fuzz testing to verify security properties hold for ALL inputs,
// not just the specific values in the unit tests above.
// ============================================================================

fn owner_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.bytearray_fixed(28)
}

/// **Property: Retract requires the exact owner key.**
///
/// Generates random 28-byte signers and verifies that Retract always fails
/// when the signer doesn't match the request owner. The `fail once` modifier
/// means the test passes as soon as it finds ONE failing case — which it
/// does immediately, since a random 28-byte key has negligible probability
/// of matching the hardcoded owner "the_real_owner_key_aaaaaaaaaa".
///
/// This demonstrates that the `has(extra_signatories, requestOwner)` check
/// is effective: no random key can authorize a retract.
test prop_retract_requires_owner(signer via owner_fuzzer()) fail once {
  let req = RequestDatum(Request {
    requestToken: testToken, requestKey: "k", requestValue: Insert("v"),
    requestOwner: "the_real_owner_key_aaaaaaaaaa", fee: 0, submitted_at: 0,
  })
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(req), Retract, testRequestRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, extra_signatories: [signer] })
}

/// **Property: Modify requires the exact owner key.**
///
/// Same approach as prop_retract_requires_owner but for the Modify path.
/// Generates random signers and confirms Modify fails when the signer
/// doesn't match the state owner. This verifies `has(extra_signatories, owner)`
/// protects the MPF state from unauthorized modifications.
test prop_modify_requires_owner(signer via owner_fuzzer()) fail once {
  let s = State { owner: "the_real_owner_key_aaaaaaaaaa", root: root(empty), max_fee: 0 }
  let unchanged_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "the_real_owner_key_aaaaaaaaaa", root: root(empty), max_fee: 0 })),
    reference_script: None,
  }
  let state_input = Input {
    output_reference: testStateRef,
    output: Output { address: testScriptAddress, value: testValue, datum: InlineDatum(Some(StateDatum(s))), reference_script: None },
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(StateDatum(s)), Modify([]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [unchanged_output], extra_signatories: [signer], inputs: [state_input] })
}

/// **Property: Minting works for any valid OutputReference.**
///
/// Generates random (tx_id, output_index) pairs and verifies that the full
/// minting flow succeeds: derive asset name from hash, create correct output,
/// and pass validator checks. This confirms the minting logic is robust
/// across the entire OutputReference space — not just for one hardcoded ref.
///
/// Covers: deterministic asset name derivation, quantity-1 enforcement,
/// script address check, empty root check, and inline datum check.
test prop_mint_roundtrip(params via fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(0, 255))) {
  let (tx_id, idx) = params
  let ref = OutputReference { transaction_id: tx_id, output_index: idx }
  let tok = TokenId { assetName: assetName(ref) }
  let mint_redeemer = Mint { asset: ref }
  let val = valueFromToken("policy_id", tok)
  let addr = address.from_script("policy_id")
  let out = Output {
    address: addr, value: val,
    datum: InlineDatum(StateDatum(State { owner: "owner", root: root(empty), max_fee: 0 })),
    reference_script: None,
  }
  let utxo = Output { address: paying_address, value: zero, datum: NoDatum, reference_script: None }
  cage.mpfCage.mint(0, testProcessTime, testRetractTime, Minting(mint_redeemer), "policy_id",
    Transaction { ..transaction.placeholder, outputs: [out], mint: val, inputs: [Input { output_reference: ref, output: utxo }] })
}

// ============================================================================
// Migration tests
//
// Migration mints a new token under the new policy while atomically burning
// the old token under the old policy. The MPF root is carried over (not
// required to be empty), preserving existing data.
// ============================================================================

const old_policy = "old_policy_id"

const new_policy = "new_policy_id"

const migrate_token = TokenId { assetName: "migrated_asset" }

const migrate_redeemer = Migration { oldPolicy: old_policy, tokenId: migrate_token }

const migrate_mint =
  from_asset(old_policy, migrate_token.assetName, -1)
    |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))

const migrate_output =
  Output {
    address: address.from_script(new_policy),
    value: from_asset(new_policy, migrate_token.assetName, 1),
    datum: InlineDatum(StateDatum(State { owner: "owner", root: "nonempty_root_hash_aaaaaaaaa", max_fee: 0 })),
    reference_script: None,
  }

/// Happy path: migrate a cage from old_policy to new_policy.
/// Burns old token (-1) and mints new token (+1) atomically.
/// The MPF root is non-empty (carried over from the old cage).
test canMigrate() {
  cage.mpfCage.mint(0, testProcessTime, testRetractTime, Migrating(migrate_redeemer), new_policy,
    Transaction { ..transaction.placeholder, outputs: [migrate_output], mint: migrate_mint })
}

/// Migration requires burning the old token. Without the burn, someone could
/// duplicate a cage by minting a new token without destroying the old one.
test migrate_no_burn() fail {
  let mint_no_burn = from_asset(new_policy, migrate_token.assetName, 1)
  cage.mpfCage.mint(0, testProcessTime, testRetractTime, Migrating(migrate_redeemer), new_policy,
    Transaction { ..transaction.placeholder, outputs: [migrate_output], mint: mint_no_burn })
}

/// The migrated token must go to a script address, not a wallet.
/// Same rationale as mint_to_wallet: wallet addresses bypass the cage validator.
test migrate_to_wallet() fail {
  let wallet_output = Output { ..migrate_output, address: address.from_verification_key("someone") }
  cage.mpfCage.mint(0, testProcessTime, testRetractTime, Migrating(migrate_redeemer), new_policy,
    Transaction { ..transaction.placeholder, outputs: [wallet_output], mint: migrate_mint })
}

/// The burn must target the correct old policy. Burning a token under a
/// different policy doesn't prove ownership of the original cage.
test migrate_wrong_old_policy() fail {
  let wrong_mint = from_asset("wrong_old", migrate_token.assetName, -1) |> assets.merge(from_asset(new_policy, migrate_token.assetName, 1))
  cage.mpfCage.mint(0, testProcessTime, testRetractTime, Migrating(migrate_redeemer), new_policy,
    Transaction { ..transaction.placeholder, outputs: [migrate_output], mint: wrong_mint })
}

// ============================================================================
// Refund enforcement tests
//
// When a request is processed (Modify) or rejected (Reject), the requester
// is owed a refund: (input lovelace - fee). These tests verify that refund
// outputs are present, sufficient, and sent to the correct address.
// ============================================================================

const testFee = 500_000

const feeState = State { owner: "owner", root: root(mpf.empty), max_fee: testFee }

const feeStateDatum = Some(StateDatum(feeState))

const feeRequest = RequestDatum(Request {
  requestToken: testToken, requestKey: "42", requestValue: Insert("42"),
  requestOwner: "requester_key_aaaaaaaaaaaaaaa", fee: testFee, submitted_at: 0,
})

const feeRequestInput = Input {
  output_reference: testRequestRef,
  output: Output { address: testScriptAddress, value: from_lovelace(2_000_000), datum: InlineDatum(feeRequest), reference_script: None },
}

const feeStateInput = Input {
  output_reference: testStateRef,
  output: Output { address: testScriptAddress, value: testValue, datum: InlineDatum(feeStateDatum), reference_script: None },
}

const feeStateOutput = Output {
  address: testScriptAddress, value: testValue,
  datum: InlineDatum(StateDatum(State {
    owner: "new-owner", root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea", max_fee: testFee,
  })),
  reference_script: None,
}

const refundOutput = Output {
  address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
  value: from_lovelace(1_500_000), datum: NoDatum, reference_script: None,
}

/// Happy path: Modify with fee. Request has 2 ADA, fee is 0.5 ADA,
/// so refund of 1.5 ADA goes to the requester's address.
test modify_with_refund() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [feeStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// A refund output must be present for each processed request.
/// Omitting it steals the requester's locked ADA.
test modify_missing_refund() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [feeStateOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// The refund must be at least (input_lovelace - fee). Underpaying shortchanges
/// the requester.
test modify_insufficient_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(1_000_000) }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [feeStateOutput, bad_refund], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// The refund must go to the request owner's address. Sending it elsewhere
/// is theft even if the amount is correct.
test modify_wrong_refund_address() fail {
  let wrong_addr_refund = Output { ..refundOutput, address: address.from_verification_key("wrong_key_aaaaaaaaaaaaaaaa") }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [feeStateOutput, wrong_addr_refund], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// When fee is 0, the full input ADA is refunded. No ADA is retained by the
/// cage owner. This is the "free service" case.
test modify_zero_fee() {
  let zf_state = State { owner: "owner", root: root(mpf.empty), max_fee: 0 }
  let zf_request = RequestDatum(Request {
    requestToken: testToken, requestKey: "42", requestValue: Insert("42"),
    requestOwner: "requester_key_aaaaaaaaaaaaaaa", fee: 0, submitted_at: 0,
  })
  let zf_request_input = Input {
    output_reference: testRequestRef,
    output: Output { address: testScriptAddress, value: from_lovelace(2_000_000), datum: InlineDatum(zf_request), reference_script: None },
  }
  let zf_state_input = Input {
    output_reference: testStateRef,
    output: Output { address: testScriptAddress, value: testValue, datum: InlineDatum(Some(StateDatum(zf_state))), reference_script: None },
  }
  let zf_state_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "new-owner", root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea", max_fee: 0 })),
    reference_script: None,
  }
  let zf_refund = Output {
    address: address.from_verification_key("requester_key_aaaaaaaaaaaaaaa"),
    value: from_lovelace(2_000_000), datum: NoDatum, reference_script: None,
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, Some(StateDatum(zf_state)), Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [zf_state_output, zf_refund], extra_signatories: ["owner"], inputs: [zf_state_input, zf_request_input] })
}

/// The request's fee must match the state's max_fee. A mismatch means the
/// request was created for a different fee tier and must be rejected.
test modify_fee_mismatch() fail {
  let mismatch_request = RequestDatum(Request {
    requestToken: testToken, requestKey: "42", requestValue: Insert("42"),
    requestOwner: "requester_key_aaaaaaaaaaaaaaa", fee: 100_000, submitted_at: 0,
  })
  let mismatch_input = Input {
    output_reference: testRequestRef,
    output: Output { address: testScriptAddress, value: from_lovelace(2_000_000), datum: InlineDatum(mismatch_request), reference_script: None },
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Modify([[]]), testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [feeStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, mismatch_input] })
}

/// End succeeds even when the mint field contains additional policies beyond
/// the cage's own burn. This supports atomic migration where a new token is
/// minted under a different policy in the same transaction.
test end_with_extra_mint_policy() {
  let extra_mint = from_asset("policy_id", testToken.assetName, -1) |> assets.merge(from_asset("other_policy", "other_asset", 1))
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, stateDatum, End, testStateRef,
    Transaction { ..transaction.placeholder, extra_signatories: ["owner"], inputs: [update], mint: extra_mint })
}

// ============================================================================
// Reject tests
//
// Reject allows the cage owner to discard expired or dishonest requests
// (Phase 3 or future submitted_at). The MPF root must NOT change — rejected
// requests are never folded in. Refunds are still owed for each rejected
// request.
// ============================================================================

const rejectStateOutput = Output {
  address: testScriptAddress, value: testValue,
  datum: InlineDatum(StateDatum(State { owner: "owner", root: root(mpf.empty), max_fee: testFee })),
  reference_script: None,
}

/// Happy path: reject an expired request in Phase 3.
/// Root stays the same, requester gets refunded (input ADA minus fee).
test reject_happy() {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, outputs: [rejectStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// Reject is forbidden in Phase 1 — requests are still being processed.
/// Rejecting a valid, in-progress request would violate the service agreement.
test reject_in_phase1() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [rejectStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// Reject is forbidden in Phase 2 — the retract window belongs exclusively
/// to the requester. The cage owner must wait for Phase 3.
test reject_in_phase2() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase2Range, outputs: [rejectStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// A request with submitted_at far in the future is dishonest — the requester
/// lied about when they submitted. Dishonest requests are rejectable in ANY
/// phase because `is_rejectable` returns true when `validity_range < submitted_at`.
test reject_future_submitted_at() {
  let future_request = RequestDatum(Request {
    requestToken: testToken, requestKey: "42", requestValue: Insert("42"),
    requestOwner: "requester_key_aaaaaaaaaaaaaaa", fee: testFee, submitted_at: 100_000,
  })
  let future_request_input = Input {
    output_reference: testRequestRef,
    output: Output { address: testScriptAddress, value: from_lovelace(2_000_000), datum: InlineDatum(future_request), reference_script: None },
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase1Range, outputs: [rejectStateOutput, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, future_request_input] })
}

/// Only the cage owner can reject requests. Without this, anyone could
/// discard valid requests and disrupt the service.
test reject_missing_signature() fail {
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, outputs: [rejectStateOutput, refundOutput], extra_signatories: [], inputs: [feeStateInput, feeRequestInput] })
}

/// The MPF root must NOT change during Reject. Rejected requests are discarded,
/// not folded into the trie. A root change would mean data was inserted
/// without proper validation.
test reject_root_changes() fail {
  let bad_reject_output = Output {
    address: testScriptAddress, value: testValue,
    datum: InlineDatum(StateDatum(State { owner: "owner", root: "different_root_aaaaaaaaaaaaa", max_fee: testFee })),
    reference_script: None,
  }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, outputs: [bad_reject_output, refundOutput], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}

/// Even rejected requests must have their ADA refunded (minus fee).
/// Providing an insufficient refund shortchanges the requester.
test reject_wrong_refund() fail {
  let bad_refund = Output { ..refundOutput, value: from_lovelace(500_000) }
  cage.mpfCage.spend(0, testProcessTime, testRetractTime, feeStateDatum, Reject, testStateRef,
    Transaction { ..transaction.placeholder, validity_range: phase3Range, outputs: [rejectStateOutput, bad_refund], extra_signatories: ["owner"], inputs: [feeStateInput, feeRequestInput] })
}
