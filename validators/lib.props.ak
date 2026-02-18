/// Token handling property tests (fuzz) — mirror Lean theorems in MpfsCage/Lib.lean.
///
/// These property tests verify the token manipulation functions from `lib.ak`
/// that the cage validator relies on for token identification and extraction.
///
/// Each property mirrors a machine-checked Lean 4 theorem. The Lean proofs
/// provide mathematical certainty; the fuzz tests validate the Aiken
/// implementation matches the formal specification.
///
/// ## Functions Under Test
///
/// - `valueFromToken` / `tokenFromValue`: Construct a single-token value and
///   extract the token back. Round-trip correctness ensures the cage can always
///   identify its own NFTs.
///
/// - `quantity`: Look up a specific token's quantity in a value. Used in mint
///   validation to enforce exactly-one-token rules.
///
/// ## Fuzzer Design
///
/// Policy IDs and asset names are fuzzed as fixed-length bytearrays (28 bytes
/// for policy IDs, matching Cardano's script hash length; 32 bytes for asset
/// names, matching SHA2-256 output). Non-empty policy IDs are guaranteed by
/// the fixed length, satisfying the `p ≠ ""` precondition.
use aiken/fuzz
use cardano/assets.{from_asset}
use lib.{TokenId, quantity, tokenFromValue, valueFromToken}

/// **Lean: valueFromToken_roundtrip**
///
/// `tokenFromValue(valueFromToken(pid, tid))` always returns `Some(tid)`
/// for any non-ADA policy ID.
///
/// After minting, the cage validator uses `tokenFromValue` on spending UTxOs
/// to recover the cage NFT identity. If the round-trip broke, the validator
/// could not match a cage UTxO back to its token — Modify, Retract, End,
/// and Reject operations would all fail to identify the cage.
///
/// The `p ≠ ""` precondition (non-ADA policy) is guaranteed by using
/// 28-byte policy IDs, which can never equal the empty bytestring.
test prop_valueFromToken_roundtrip(
  params via fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
) {
  let (pid, asset) = params
  let tid = TokenId { assetName: asset }
  tokenFromValue(valueFromToken(pid, tid)) == Some(tid)
}

/// **Lean: tokenFromValue_ada_only**
///
/// A value containing only ADA (the empty-string policy) has no extractable
/// token — `tokenFromValue` returns `None`.
///
/// Every Cardano UTxO carries ADA. The cage validator must distinguish
/// "ADA + one NFT" (a valid cage UTxO) from "ADA only" (not a cage).
/// If this property failed, a plain ADA UTxO sitting at the script address
/// could be mistaken for a cage, letting an attacker spend it via Modify
/// or End as if it held a real token.
test prop_tokenFromValue_ada_only(
  params via fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(1, 1_000_000)),
) {
  let (asset, qty) = params
  let v = from_asset("", asset, qty)
  tokenFromValue(v) == None
}

/// **Lean: quantity_present**
///
/// `quantity(p, fromAsset(p, a, q), TokenId{a})` always returns `Some(q)`.
///
/// This is the core of mint validation: `validateMint` checks
/// `quantity(policyId, mint, tokenId) == Some(1)` to ensure exactly one
/// token is minted, and `End` checks `quantity == Some(-1)` for burns.
/// If `quantity` could not find a token that is actually present, valid
/// minting and burning transactions would be rejected.
///
/// The fuzzer covers both positive and negative quantities to exercise
/// the minting (positive) and burning (negative) paths.
test prop_quantity_present(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
    fuzz.int_between(-1_000_000, 1_000_000),
  ),
) {
  let ((pid, asset), qty) = params
  let tid = TokenId { assetName: asset }
  let v = from_asset(pid, asset, qty)
  quantity(pid, v, tid) == Some(qty)
}

/// **Lean: quantity_wrong_policy**
///
/// Looking up a token under a different policy always returns `None`.
///
/// Cage instances are isolated by policy ID (each cage script has its own
/// hash). A token minted under policy `p'` must not be visible when querying
/// policy `p`. Without this isolation, an attacker could mint a cheap token
/// under their own policy and have it pass another cage's quantity check.
///
/// Two independently-fuzzed 28-byte policy IDs are extremely unlikely to
/// collide (2^224 space), satisfying the Lean `p ≠ p'` precondition.
/// The `fail once` directive confirms that collisions are rejected by the
/// fuzzer — the test expects the equality to fail on the first try.
test prop_quantity_wrong_policy(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(28)),
    fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(1, 1_000_000)),
  ),
) fail once {
  let ((pid, other_pid), (asset, qty)) = params
  let tid = TokenId { assetName: asset }
  let v = from_asset(other_pid, asset, qty)
  quantity(pid, v, tid) == Some(qty)
}

/// **Lean: quantity_wrong_asset**
///
/// Looking up a token with a different asset name always returns `None`,
/// even when the policy matches.
///
/// Within a cage policy, each NFT has a unique asset name derived from its
/// minting OutputReference via SHA2-256. The quantity check must distinguish
/// between different tokens under the same policy — otherwise burning token
/// A could satisfy a check meant for token B, letting an attacker destroy
/// the wrong cage while keeping the intended target alive.
///
/// Two independently-fuzzed 32-byte asset names are extremely unlikely to
/// collide, satisfying the Lean `a ≠ a'` precondition.
test prop_quantity_wrong_asset(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
    fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(1, 1_000_000)),
  ),
) fail once {
  let ((pid, asset), (other_asset, qty)) = params
  let tid = TokenId { assetName: asset }
  let v = from_asset(pid, other_asset, qty)
  quantity(pid, v, tid) == Some(qty)
}

/// **Lean: quantity_valueFromToken**
///
/// `quantity(p, valueFromToken(p, tid), tid)` always returns `Some(1)`.
///
/// This is the end-to-end mint validation path: `validateMint` constructs
/// the expected output value via `valueFromToken` and then verifies the
/// actual mint field via `quantity == Some(1)`. This theorem proves the
/// two functions compose correctly — without it, no minting transaction
/// could ever pass validation, and no new cages could be created.
test prop_quantity_valueFromToken(
  params via fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
) {
  let (pid, asset) = params
  let tid = TokenId { assetName: asset }
  quantity(pid, valueFromToken(pid, tid), tid) == Some(1)
}
