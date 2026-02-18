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

/-- Round-trip: extracting the token from a single-token value
    returns that token's asset name.
    Mirrors Aiken test `tokenFromValue_roundtrip`. -/
theorem valueFromToken_roundtrip
    (p : PolicyId) (a : AssetName) (hp : p ≠ "") :
    tokenFromValue (valueFromToken p a) = some a := by
  simp [valueFromToken, fromAsset, tokenFromValue, List.filter, hp]

/-- ADA-only value (policy = "") yields `none`.
    Mirrors Aiken test `tokenFromValue_ada_only`. -/
theorem tokenFromValue_ada_only (a : AssetName) (q : Int) :
    tokenFromValue (fromAsset "" a q) = none := by
  simp [fromAsset, tokenFromValue, List.filter]

/-- Two different non-ADA policies yield `none`.
    Mirrors Aiken test `tokenFromValue_multi_policy`. -/
theorem tokenFromValue_multi_policy
    (p1 p2 : PolicyId) (a1 a2 : AssetName) (q1 q2 : Int)
    (hp1 : p1 ≠ "") (hp2 : p2 ≠ "") :
    tokenFromValue (⟨p1, a1, q1⟩ :: ⟨p2, a2, q2⟩ :: []) = none := by
  simp [tokenFromValue, List.filter, hp1, hp2]

/-- Same policy, two assets yield `none`.
    Mirrors Aiken test `tokenFromValue_multi_asset`. -/
theorem tokenFromValue_multi_asset
    (p : PolicyId) (a1 a2 : AssetName) (q1 q2 : Int)
    (hp : p ≠ "") :
    tokenFromValue (⟨p, a1, q1⟩ :: ⟨p, a2, q2⟩ :: []) = none := by
  simp [tokenFromValue, List.filter, hp]

/-- Looking up a token that is present returns its quantity.
    Mirrors Aiken test `quantity_present`. -/
theorem quantity_present
    (p : PolicyId) (a : AssetName) (q : Int) :
    quantity p a (fromAsset p a q) = some q := by
  simp [fromAsset, quantity, List.filter]

/-- Looking up with the wrong policy returns `none`.
    Mirrors Aiken test `quantity_wrong_policy`. -/
theorem quantity_wrong_policy
    (p p' : PolicyId) (a : AssetName) (q : Int)
    (hne : p ≠ p') :
    quantity p a (fromAsset p' a q) = some q → False := by
  simp [fromAsset, quantity, List.filter]
  intro h
  simp [show (p' == p) = false from by
    simp [BEq.beq]; exact fun h => hne h.symm] at h

/-- Composing `valueFromToken` with `quantity` yields `some 1`.
    Mirrors the combination of Aiken tests for `valueFromToken`
    and `quantity`. -/
theorem quantity_valueFromToken
    (p : PolicyId) (a : AssetName) :
    quantity p a (valueFromToken p a) = some 1 := by
  simp [valueFromToken, quantity_present]
