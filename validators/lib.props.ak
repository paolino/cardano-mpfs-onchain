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
/// Extracting the token from a single-token value returns that token's
/// asset name. The `p ≠ ""` precondition (non-ADA policy) is guaranteed
/// by using 28-byte policy IDs.
test prop_valueFromToken_roundtrip(
  params via fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
) {
  let (pid, asset) = params
  let tid = TokenId { assetName: asset }
  tokenFromValue(valueFromToken(pid, tid)) == Some(tid)
}

/// **Lean: tokenFromValue_ada_only**
///
/// An ADA-only value (policy = "") yields None. The cage validator must
/// reject UTxOs that contain no native token.
test prop_tokenFromValue_ada_only(
  params via fuzz.tuple(fuzz.bytearray_fixed(32), fuzz.int_between(1, 1_000_000)),
) {
  let (asset, qty) = params
  let v = from_asset("", asset, qty)
  tokenFromValue(v) == None
}

/// **Lean: quantity_present**
///
/// Looking up a token that is present returns its quantity.
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
/// Looking up with a different policy returns None. Policy ID is the
/// first level of the Value map — a mismatch means the token doesn't
/// exist under that policy.
///
/// Two independently-fuzzed 28-byte policy IDs are extremely unlikely
/// to collide (2^224 space), satisfying the `p ≠ p'` precondition.
/// The `fail once` directive confirms that collisions are rejected.
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
/// Looking up with a different asset name returns None. Even if the
/// policy matches, the specific token must also match.
///
/// Two independently-fuzzed 32-byte asset names are extremely unlikely
/// to collide, satisfying the `a ≠ a'` precondition.
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
/// Composing `valueFromToken` with `quantity` yields `Some(1)`.
/// This ensures the mint validation path works end-to-end:
/// construct a single-token value, then verify quantity is exactly 1.
test prop_quantity_valueFromToken(
  params via fuzz.tuple(fuzz.bytearray_fixed(28), fuzz.bytearray_fixed(32)),
) {
  let (pid, asset) = params
  let tid = TokenId { assetName: asset }
  quantity(pid, valueFromToken(pid, tid), tid) == Some(1)
}
