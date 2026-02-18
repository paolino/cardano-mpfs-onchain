/// Unit tests and property tests for the token handling library (lib.ak).
///
/// These test the foundational functions that the cage validator relies on:
///
/// - **assetName**: Derives a unique, deterministic NFT name from an OutputReference
///   via SHA2-256. Uniqueness is critical — if two different OutputReferences
///   produced the same asset name, an attacker could mint duplicate caged tokens.
///
/// - **tokenFromValue**: Extracts the single non-ADA token from a Value.
///   Used to identify which caged token a UTxO belongs to. Must return None
///   for ambiguous cases (multiple tokens, ADA-only).
///
/// - **quantity**: Looks up how many of a specific token exist in a Value.
///   Used to verify exactly 1 token is minted or exactly -1 is burned.
use aiken/fuzz
use cardano/assets
use cardano/assets.{from_asset}
use cardano/transaction.{OutputReference}
use lib.{TokenId, assetName, quantity, tokenFromValue, valueFromToken}

// ============================================================================
// assetName tests
// ============================================================================

const ref_a =
  OutputReference { transaction_id: "tx_aaaaaa", output_index: 0 }

const ref_b =
  OutputReference { transaction_id: "tx_bbbbbb", output_index: 0 }

const ref_c =
  OutputReference { transaction_id: "tx_aaaaaa", output_index: 1 }

/// Same OutputReference always produces the same hash. This is the basic
/// determinism requirement — without it, minting and later spending would
/// disagree on the token's identity.
test assetName_deterministic() {
  assetName(ref_a) == assetName(ref_a)
}

/// Different transaction IDs produce different asset names. Since tx IDs
/// are the first 32 bytes of the hash input, any change propagates through
/// SHA2-256.
test assetName_different_txid() {
  assetName(ref_a) != assetName(ref_b)
}

/// Different output indices produce different asset names. The index is
/// encoded as 2 big-endian bytes appended to the tx ID, so even index 0
/// vs 1 yields a completely different hash.
test assetName_different_index() {
  assetName(ref_a) != assetName(ref_c)
}

/// **Property: assetName is deterministic for all OutputReferences.**
///
/// Generates random (tx_id, output_index) pairs across the full space
/// (32-byte tx IDs, indices 0-65535) and verifies that hashing the same
/// OutputReference twice always yields the same result. This is a sanity
/// check on SHA2-256 determinism — it should never fail, but catching a
/// hypothetical non-determinism bug here would prevent catastrophic token
/// identity confusion.
test prop_assetName_deterministic(
  params via fuzz.tuple(
    fuzz.bytearray_fixed(32),
    fuzz.int_between(0, 65535),
  ),
) {
  let (tx_id, idx) = params
  let ref = OutputReference { transaction_id: tx_id, output_index: idx }
  assetName(ref) == assetName(ref)
}

// ============================================================================
// tokenFromValue tests
// ============================================================================

const test_policy = "test_policy_id"

const test_asset = "test_asset_name"

/// A Value with exactly one non-ADA token returns Some(TokenId).
/// This is the normal case for cage UTxOs.
test tokenFromValue_single_nft() {
  let v = from_asset(test_policy, test_asset, 1)
  tokenFromValue(v) == Some(TokenId { assetName: test_asset })
}

/// A Value with only ADA (no native tokens) returns None.
/// Cage UTxOs must always contain their NFT — an ADA-only UTxO is not a cage.
test tokenFromValue_ada_only() {
  let v = from_asset("", "", 2_000_000)
  tokenFromValue(v) == None
}

/// A Value with tokens under two different policies returns None.
/// Ambiguous: which token is the caged one? The validator rejects this.
test tokenFromValue_multi_policy() {
  let v =
    from_asset("policy_a", "asset", 1)
      |> assets.merge(from_asset("policy_b", "asset", 1))
  tokenFromValue(v) == None
}

/// A Value with two different asset names under the same policy returns None.
/// Also ambiguous — a cage UTxO should hold exactly one NFT.
test tokenFromValue_multi_asset() {
  let v =
    from_asset(test_policy, "asset_a", 1)
      |> assets.merge(from_asset(test_policy, "asset_b", 1))
  tokenFromValue(v) == None
}

/// Round-trip: constructing a Value with `valueFromToken` and extracting
/// with `tokenFromValue` returns the original TokenId. This confirms the
/// two functions are inverses for single-token values.
test tokenFromValue_roundtrip() {
  let pid = "my_policy"
  let tid = TokenId { assetName: "my_asset" }
  tokenFromValue(valueFromToken(pid, tid)) == Some(tid)
}

// ============================================================================
// quantity tests
// ============================================================================

const q_policy = "q_policy"

const q_token = TokenId { assetName: "q_asset" }

/// Looking up a token that exists in the Value returns its quantity.
test quantity_present() {
  let v = from_asset(q_policy, "q_asset", 1)
  quantity(q_policy, v, q_token) == Some(1)
}

/// Looking up the right asset name under the wrong policy returns None.
/// Policy ID is the first level of the Value map — a mismatch means the
/// token doesn't exist under that policy.
test quantity_wrong_policy() {
  let v = from_asset("other_policy", "q_asset", 1)
  quantity(q_policy, v, q_token) == None
}

/// Looking up the right policy with the wrong asset name returns None.
/// Asset name is the second level — even if the policy matches, the
/// specific token must also match.
test quantity_wrong_asset() {
  let v = from_asset(q_policy, "other_asset", 1)
  quantity(q_policy, v, q_token) == None
}

/// Composing valueFromToken with quantity yields Some(1).
/// Mirrors Lean theorem `quantity_valueFromToken`.
test quantity_valueFromToken() {
  let pid = "my_policy"
  let tid = TokenId { assetName: "my_asset" }
  quantity(pid, valueFromToken(pid, tid), tid) == Some(1)
}
