/-!
# MPFS Cage — Token Handling Logic

Formal model of the token manipulation functions from the
cardano-mpfs-onchain Aiken `lib.ak` module.

## Functions Modelled

- `fromAsset`: Construct a value with a single token entry.
- `valueFromToken`: Construct a value with quantity 1 of a token.
- `tokenFromValue`: Extract the single non-ADA token from a value.
- `quantity`: Look up the quantity of a specific token in a value.

## Design

Values are modelled as flat association lists of `(PolicyId, AssetName, Int)`.
This mirrors Aiken's nested `Dict<PolicyId, Dict<AssetName, Int>>` but
flattened for proof simplicity — the theorems target individual function
round-trips and look-ups, not the full dictionary algebra.
-/

abbrev PolicyId := String
abbrev AssetName := String

/-- A single entry in a value: policy, asset name, and quantity. -/
structure TokenEntry where
  policy : PolicyId
  asset : AssetName
  qty : Int
  deriving DecidableEq, Repr

/-- A value is a list of token entries. -/
def Value := List TokenEntry

/-- Construct a value with a single token entry. -/
def fromAsset (p : PolicyId) (a : AssetName) (q : Int) : Value :=
  [⟨p, a, q⟩]

/-- Construct a value with exactly 1 of the specified token.
    Mirrors Aiken's `from_asset(policyId, assetName, 1)`. -/
def valueFromToken (p : PolicyId) (a : AssetName) : Value :=
  fromAsset p a 1

/-- Extract the single non-ADA token's asset name from a value.
    Returns `none` unless there is exactly one entry with a
    non-empty (non-ADA) policy ID. Mirrors Aiken's `tokenFromValue`. -/
def tokenFromValue (v : Value) : Option AssetName :=
  match v.filter (fun e => e.policy ≠ "") with
  | [e] => some e.asset
  | _   => none

/-- Look up the quantity of a specific token in a value.
    Returns `some qty` if exactly one entry matches the given
    policy and asset name, `none` otherwise.
    Mirrors Aiken's `quantity(policyId, value, TokenId)`. -/
def quantity (p : PolicyId) (a : AssetName) (v : Value) : Option Int :=
  match v.filter (fun e => e.policy == p && e.asset == a) with
  | [e] => some e.qty
  | _   => none

-- ============================================================
-- Theorems
-- ============================================================

/-- `valueFromToken` and `tokenFromValue` are inverses for single-token
    values with a non-ADA policy (`p ≠ ""`).

    This is the foundation of cage NFT identity: after minting via
    `valueFromToken`, the cage validator uses `tokenFromValue` on spending
    UTxOs to recover the token. If the round-trip failed, the validator
    could not match a cage UTxO back to its token — Modify, Retract, and
    End operations would all break.

    Mirrors Aiken test `tokenFromValue_roundtrip`. -/
theorem valueFromToken_roundtrip
    (p : PolicyId) (a : AssetName) (hp : p ≠ "") :
    tokenFromValue (valueFromToken p a) = some a := by
  simp [valueFromToken, fromAsset, tokenFromValue, List.filter, hp]

/-- A value containing only ADA (the empty-string policy) has no
    extractable token.

    On Cardano, every UTxO carries ADA. The cage validator must
    distinguish "ADA + one NFT" (a cage UTxO) from "ADA only" (not
    a cage). Without this property, a plain ADA UTxO at the script
    address could be mistaken for a cage, letting an attacker spend
    it as if it held a token.

    Mirrors Aiken test `tokenFromValue_ada_only`. -/
theorem tokenFromValue_ada_only (a : AssetName) (q : Int) :
    tokenFromValue (fromAsset "" a q) = none := by
  simp [fromAsset, tokenFromValue, List.filter]

/-- A value with two different non-ADA policies has no unambiguously
    extractable token.

    Cage UTxOs must hold exactly one NFT (under the cage policy). If
    a UTxO somehow contained tokens from two policies, `tokenFromValue`
    cannot decide which is the cage NFT, so it returns `none`. The
    validator then rejects the transaction, preventing token confusion
    between different cage instances or foreign policies.

    Mirrors Aiken test `tokenFromValue_multi_policy`. -/
theorem tokenFromValue_multi_policy
    (p1 p2 : PolicyId) (a1 a2 : AssetName) (q1 q2 : Int)
    (hp1 : p1 ≠ "") (hp2 : p2 ≠ "") :
    tokenFromValue (⟨p1, a1, q1⟩ :: ⟨p2, a2, q2⟩ :: []) = none := by
  simp [tokenFromValue, List.filter, hp1, hp2]

/-- A value with two different asset names under the same policy has
    no unambiguously extractable token.

    Even within a single policy, each cage NFT has a unique asset name
    (derived from its minting OutputReference). A UTxO holding two
    assets under one policy is ambiguous — which token does this cage
    belong to? Returning `none` forces the validator to reject, preventing
    an attacker from bundling tokens to confuse Modify or End logic.

    Mirrors Aiken test `tokenFromValue_multi_asset`. -/
theorem tokenFromValue_multi_asset
    (p : PolicyId) (a1 a2 : AssetName) (q1 q2 : Int)
    (hp : p ≠ "") :
    tokenFromValue (⟨p, a1, q1⟩ :: ⟨p, a2, q2⟩ :: []) = none := by
  simp [tokenFromValue, List.filter, hp]

/-- Looking up a token that is present in a value returns its quantity.

    This is the core of mint validation: `validateMint` checks
    `quantity(policyId, mint, tokenId) == Some(1)` to ensure exactly
    one token is minted. If `quantity` failed to find a present token,
    valid minting transactions would be rejected.

    Mirrors Aiken test `quantity_present`. -/
theorem quantity_present
    (p : PolicyId) (a : AssetName) (q : Int) :
    quantity p a (fromAsset p a q) = some q := by
  simp [fromAsset, quantity, List.filter]

/-- Looking up a token under the wrong policy returns `none`.

    Cage instances are isolated by policy ID (each cage script has its
    own hash). A token minted under policy `p'` must not be visible
    when querying policy `p`. Without this, an attacker could create
    a cheap token under their own policy and have it pass the quantity
    check of a different cage's validator.

    Mirrors Aiken test `quantity_wrong_policy`. -/
theorem quantity_wrong_policy
    (p p' : PolicyId) (a : AssetName) (q : Int)
    (hne : p ≠ p') :
    quantity p a (fromAsset p' a q) = none := by
  simp only [fromAsset, quantity, List.filter]
  simp [show (p' == p) = false from by
    simp [BEq.beq]; exact fun h => hne h.symm]

/-- Looking up a token with the wrong asset name returns `none`.

    Within a cage policy, each NFT has a unique asset name derived from
    its minting OutputReference. The quantity check must distinguish
    between different tokens under the same policy — otherwise burning
    token A could satisfy a check meant for token B, allowing an
    attacker to destroy the wrong cage.

    Mirrors Aiken test `quantity_wrong_asset`. -/
theorem quantity_wrong_asset
    (p : PolicyId) (a a' : AssetName) (q : Int)
    (hne : a ≠ a') :
    quantity p a (fromAsset p a' q) = none := by
  simp only [fromAsset, quantity, List.filter]
  simp [show (a' == a) = false from by
    simp [BEq.beq]; exact fun h => hne h.symm]

/-- The mint validation path works end-to-end: constructing a
    single-token value with `valueFromToken` and then querying its
    quantity yields exactly `some 1`.

    This composes `valueFromToken` (used to build the expected mint
    output) with `quantity` (used to verify the actual mint field).
    `validateMint` relies on both — it constructs the expected value
    and checks `quantity == Some(1)`. If the composition failed, no
    minting transaction could ever pass validation.

    Mirrors Aiken test `quantity_valueFromToken`. -/
theorem quantity_valueFromToken
    (p : PolicyId) (a : AssetName) :
    quantity p a (valueFromToken p a) = some 1 := by
  simp [valueFromToken, quantity_present]
