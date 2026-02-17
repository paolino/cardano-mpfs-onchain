/-
  Formal specification of the MPF Cage validators.

  This file extracts the essential safety properties of the on-chain
  validators as Lean 4 propositions. It is a *specification* — it
  defines the abstract model and states what must hold, without
  providing machine-checked proofs (those would require a Plutus
  semantics formalisation).

  The properties map 1-to-1 to the 16 categories in
  `docs/architecture/properties.md` and the 67 Aiken inline tests.
-/

-- ============================================================================
-- Abstract types
-- ============================================================================

/-- 28-byte Ed25519 public-key hash. -/
opaque def VKH := ByteArray

/-- 32-byte hash (SHA2-256 or Blake2b-256). -/
opaque def Hash := ByteArray

/-- Arbitrary-length byte string used as MPF keys and values. -/
abbrev Bytes := ByteArray

/-- A POSIX timestamp in milliseconds. -/
abbrev POSIXTime := Int

/-- A time interval `[lo, hi]` representing `tx.validity_range`. -/
structure Interval where
  lo : POSIXTime
  hi : POSIXTime

/-- An unspent transaction output reference. -/
structure OutputReference where
  txId : Hash
  index : Nat

/-- Asset name (derived from SHA2-256 of an OutputReference). -/
abbrev AssetName := Hash

/-- Policy ID (= script hash for a combined minting+spending validator). -/
abbrev PolicyId := Hash

/-- Token identity — asset name only; policy ID is always the script's own. -/
structure TokenId where
  assetName : AssetName

-- ============================================================================
-- On-chain data structures
-- ============================================================================

/-- MPF modification operations. -/
inductive Operation where
  | Insert  (value : Bytes)
  | Delete  (value : Bytes)
  | Update  (oldValue newValue : Bytes)

/-- State datum — attached to the UTxO holding the MPF token. -/
structure State where
  owner  : VKH
  root   : Hash       -- current MPF root (Blake2b-256)
  maxFee : Nat        -- max lovelace fee per request

/-- Request datum — attached to pending modification request UTxOs. -/
structure Request where
  requestToken : TokenId
  requestOwner : VKH
  requestKey   : Bytes
  requestValue : Operation
  fee          : Nat
  submittedAt  : POSIXTime

/-- Datum discriminator for UTxOs at the script address. -/
inductive CageDatum where
  | RequestDatum (r : Request)
  | StateDatum   (s : State)

-- ============================================================================
-- Redeemers
-- ============================================================================

inductive MintRedeemer where
  | Minting    (asset : OutputReference)
  | Migrating  (oldPolicy : PolicyId) (tokenId : TokenId)
  | Burning

/-- Abstract Merkle proof (opaque — verified by the MPF library). -/
opaque def Proof := Unit

inductive SpendRedeemer where
  | End
  | Contribute (stateRef : OutputReference)
  | Modify     (proofs : List Proof)
  | Retract
  | Reject

-- ============================================================================
-- Transaction model (abstract)
-- ============================================================================

structure TxInput where
  ref     : OutputReference
  value   : Nat             -- lovelace
  datum   : Option CageDatum
  address : PolicyId        -- payment credential (script hash)
  token   : Option TokenId  -- single non-ADA token, if any

structure TxOutput where
  value   : Nat
  datum   : Option CageDatum
  address : PolicyId
  token   : Option TokenId

structure Transaction where
  inputs          : List TxInput
  outputs         : List TxOutput
  mint            : PolicyId → TokenId → Int   -- (policy, token) → quantity
  extraSignatories : List VKH
  validityRange   : Interval

-- ============================================================================
-- Validator parameters (immutable per deployment)
-- ============================================================================

structure ValidatorParams where
  version     : Nat
  processTime : Nat        -- Phase 1 duration (ms)
  retractTime : Nat        -- Phase 2 duration (ms)

-- ============================================================================
-- Phase predicates
-- ============================================================================

/-- The entire validity range falls before the deadline. -/
def Interval.isEntirelyBefore (vr : Interval) (deadline : POSIXTime) : Prop :=
  vr.hi < deadline

/-- The entire validity range falls at or after the threshold. -/
def Interval.isEntirelyAfter (vr : Interval) (threshold : POSIXTime) : Prop :=
  vr.lo > threshold

/-- Phase 1: oracle-exclusive processing window.
    `[submittedAt, submittedAt + processTime)` -/
def inPhase1 (vr : Interval) (submittedAt : POSIXTime) (p : ValidatorParams) : Prop :=
  vr.isEntirelyBefore (submittedAt + p.processTime)

/-- Phase 2: requester-exclusive retract window.
    `[submittedAt + processTime, submittedAt + processTime + retractTime)` -/
def inPhase2 (vr : Interval) (submittedAt : POSIXTime) (p : ValidatorParams) : Prop :=
  vr.isEntirelyAfter (submittedAt + p.processTime - 1) ∧
  vr.isEntirelyBefore (submittedAt + p.processTime + p.retractTime)

/-- A request is rejectable when it is in Phase 3 or has a dishonest
    (future) `submittedAt`. -/
def isRejectable (vr : Interval) (submittedAt : POSIXTime) (p : ValidatorParams) : Prop :=
  vr.isEntirelyAfter (submittedAt + p.processTime + p.retractTime - 1) ∨
  vr.isEntirelyBefore submittedAt

-- ============================================================================
-- Abstract MPF operations
-- ============================================================================

/-- Apply an operation to an MPF root using a proof. Returns the new root.
    We treat this as an axiom — correctness is guaranteed by the
    `aiken-lang/merkle-patricia-forestry` library. -/
axiom mpfApply (root : Hash) (key : Bytes) (op : Operation) (proof : Proof) : Hash

/-- The well-known root hash of the empty trie. -/
axiom emptyRoot : Hash

-- ============================================================================
-- Derived predicates
-- ============================================================================

def isSigner (tx : Transaction) (vkh : VKH) : Prop :=
  vkh ∈ tx.extraSignatories

def assetName (ref : OutputReference) : AssetName :=
  sorry  -- SHA2-256(ref.txId ++ bigEndian16(ref.index))

-- ============================================================================
-- 1. Token uniqueness
-- ============================================================================

/-- Determinism: same OutputReference always yields the same AssetName. -/
theorem assetName_deterministic (ref : OutputReference) :
    assetName ref = assetName ref := rfl

/-- Collision resistance: distinct OutputReferences yield distinct
    AssetNames (by SHA2-256 collision resistance). -/
axiom assetName_injective :
    ∀ r₁ r₂ : OutputReference, assetName r₁ = assetName r₂ → r₁ = r₂

-- ============================================================================
-- 2. Minting integrity
-- ============================================================================

/-- A Minting transaction is valid iff all four conditions hold. -/
structure ValidMint (policyId : PolicyId) (tx : Transaction)
    (asset : OutputReference) : Prop where
  /-- The referenced UTxO is consumed. -/
  consumed  : ∃ i ∈ tx.inputs, i.ref = asset
  /-- Exactly one token is minted. -/
  quantity  : tx.mint policyId ⟨assetName asset⟩ = 1
  /-- First output goes to this script. -/
  toScript  : ∃ o ∈ tx.outputs, tx.outputs.head? = some o ∧ o.address = policyId
  /-- Output datum is StateDatum with empty root. -/
  emptyInit : ∃ o ∈ tx.outputs, tx.outputs.head? = some o ∧
              o.datum = some (CageDatum.StateDatum ⟨·, emptyRoot, ·⟩)

-- ============================================================================
-- 3. Ownership & authorization
-- ============================================================================

/-- Oracle operations require the state owner's signature. -/
def oracleAuthorized (state : State) (tx : Transaction) : Prop :=
  isSigner tx state.owner

/-- Retract requires the request owner's signature. -/
def retractAuthorized (request : Request) (tx : Transaction) : Prop :=
  isSigner tx request.requestOwner

-- ============================================================================
-- 4. Token confinement
-- ============================================================================

/-- After Modify or Reject the token stays at the same script address. -/
def tokenConfined (input : TxInput) (output : TxOutput) : Prop :=
  output.address = input.address

-- ============================================================================
-- 5. Ownership transfer
-- ============================================================================

/-- The owner field in the output datum is unchecked during Modify —
    the current owner can transfer to a new key. -/
def ownerTransferAllowed (inputState outputState : State) : Prop :=
  True  -- no constraint on outputState.owner

-- ============================================================================
-- 6. State integrity (MPF root)
-- ============================================================================

/-- The output root equals the result of folding all matching request
    operations over the input root. -/
def rootIntegrity
    (inputRoot : Hash)
    (requests : List (Request × Proof))
    (outputRoot : Hash) : Prop :=
  outputRoot = requests.foldl
    (fun root (req, proof) => mpfApply root req.requestKey req.requestValue proof)
    inputRoot

-- ============================================================================
-- 7. Proof consumption
-- ============================================================================

/-- Exactly one proof is consumed per matching request.
    Too few proofs → failure. Extra proofs are silently ignored. -/
def proofConsumption
    (matchingRequests : List Request)
    (proofs : List Proof) : Prop :=
  matchingRequests.length ≤ proofs.length

-- ============================================================================
-- 8. Request binding
-- ============================================================================

/-- A Contribute validates that the request's target token matches the
    actual token at the referenced state UTxO. -/
def requestBound (request : Request) (stateToken : TokenId) : Prop :=
  request.requestToken = stateToken

-- ============================================================================
-- 9. Datum-redeemer type safety
-- ============================================================================

/-- Each redeemer expects a specific datum constructor. -/
def datumRedeemerCompat : SpendRedeemer → CageDatum → Prop
  | .Retract,       .RequestDatum _ => True
  | .Contribute _,  .RequestDatum _ => True
  | .Modify _,      .StateDatum _   => True
  | .End,           .StateDatum _   => True
  | .Reject,        .StateDatum _   => True
  | _,              _               => False

-- ============================================================================
-- 10. Datum presence
-- ============================================================================

/-- Every cage UTxO must carry a datum. UTxOs with `None` are unspendable. -/
def datumPresent (datum : Option CageDatum) : Prop :=
  datum.isSome

-- ============================================================================
-- 11. End / burn integrity
-- ============================================================================

/-- End requires the mint field to contain exactly -1 of the caged token. -/
def burnIntegrity (policyId : PolicyId) (tokenId : TokenId) (tx : Transaction) : Prop :=
  tx.mint policyId tokenId = -1

-- ============================================================================
-- 12. Token extraction
-- ============================================================================

/-- `tokenFromValue` returns `Some` iff the value contains exactly one
    non-ADA policy with exactly one asset name. -/
-- (Modelled abstractly via the TxInput.token field.)

-- ============================================================================
-- 13. Time-gated phases (exclusivity)
-- ============================================================================

/-- Phases are mutually exclusive: no validity range can satisfy two phases. -/
theorem phase_exclusivity (vr : Interval) (sa : POSIXTime) (p : ValidatorParams)
    (hpt : 0 < p.processTime) (hrt : 0 < p.retractTime) :
    ¬(inPhase1 vr sa p ∧ inPhase2 vr sa p) := by
  intro ⟨h1, h2lo, _⟩
  -- inPhase1 says vr.hi < sa + pt, inPhase2 says vr.lo > sa + pt - 1
  -- Since vr.lo ≤ vr.hi, we get sa + pt - 1 < vr.lo ≤ vr.hi < sa + pt
  -- i.e. sa + pt - 1 < sa + pt which is trivially true, but we also need
  -- vr.lo ≤ vr.hi which gives the contradiction.
  sorry  -- requires Interval well-formedness axiom (lo ≤ hi)

/-- Phase 2 and rejectability (Phase 3 branch) are mutually exclusive. -/
theorem phase2_reject_exclusive (vr : Interval) (sa : POSIXTime) (p : ValidatorParams) :
    ¬(inPhase2 vr sa p ∧
      vr.isEntirelyAfter (sa + p.processTime + p.retractTime - 1)) := by
  intro ⟨⟨_, h2hi⟩, h3lo⟩
  -- h2hi: vr.hi < sa + pt + rt
  -- h3lo: vr.lo > sa + pt + rt - 1, i.e. vr.lo ≥ sa + pt + rt
  -- Since lo ≤ hi: sa + pt + rt ≤ vr.lo ≤ vr.hi < sa + pt + rt → contradiction
  sorry

-- ============================================================================
-- 14. Reject (DDoS protection)
-- ============================================================================

/-- A Reject transaction is valid iff all of the following hold. -/
structure ValidReject (p : ValidatorParams) (state : State)
    (stateInput : TxInput) (tx : Transaction)
    (requests : List (TxInput × Request)) : Prop where
  /-- Owner signed. -/
  auth      : oracleAuthorized state tx
  /-- Root unchanged. -/
  rootSame  : ∀ o ∈ tx.outputs, tx.outputs.head? = some o →
              ∃ s, o.datum = some (CageDatum.StateDatum s) ∧ s.root = state.root
  /-- Token confined. -/
  confined  : ∀ o ∈ tx.outputs, tx.outputs.head? = some o →
              o.address = stateInput.address
  /-- Each request is rejectable. -/
  rejectable : ∀ (pair : TxInput × Request), pair ∈ requests →
               isRejectable tx.validityRange pair.2.submittedAt p
  /-- Each request fee matches state max_fee. -/
  feeMatch  : ∀ (pair : TxInput × Request), pair ∈ requests →
              pair.2.fee = state.maxFee
  /-- Refunds: each requester receives inputLovelace - fee. -/
  refunds   : ∀ (pair : TxInput × Request), pair ∈ requests →
              ∃ o ∈ tx.outputs,
                o.address = sorry ∧  -- requestOwner's address
                o.value ≥ pair.1.value - pair.2.fee

-- ============================================================================
-- 15. Fee enforcement
-- ============================================================================

/-- During Modify, each request's fee must equal the state's max_fee,
    and the requester is refunded inputLovelace - fee. -/
structure FeeEnforced (state : State) (reqInput : TxInput)
    (request : Request) (tx : Transaction) : Prop where
  feeMatch : request.fee = state.maxFee
  refund   : ∃ o ∈ tx.outputs,
             o.value ≥ reqInput.value - request.fee

-- ============================================================================
-- 16. Migration
-- ============================================================================

/-- A Migration transaction is valid iff the old token is burned and a new
    token is minted, output goes to the new script, and carries a StateDatum. -/
structure ValidMigration (oldPolicy newPolicy : PolicyId)
    (tokenId : TokenId) (tx : Transaction) : Prop where
  oldBurned : tx.mint oldPolicy tokenId = -1
  newMinted : tx.mint newPolicy tokenId = 1
  toScript  : ∃ o ∈ tx.outputs, tx.outputs.head? = some o ∧ o.address = newPolicy
  hasDatum  : ∃ o ∈ tx.outputs, tx.outputs.head? = some o ∧
              ∃ s, o.datum = some (CageDatum.StateDatum s)

-- ============================================================================
-- Composite validator property
-- ============================================================================

/-- Top-level spend acceptance — the conjunction of all applicable properties
    depending on the redeemer. -/
def validSpend (p : ValidatorParams) (policyId : PolicyId)
    (datum : CageDatum) (redeemer : SpendRedeemer)
    (self : TxInput) (tx : Transaction) : Prop :=
  datumPresent (some datum) ∧
  datumRedeemerCompat redeemer datum ∧
  match redeemer, datum with
  | .Retract, .RequestDatum req =>
      retractAuthorized req tx ∧
      inPhase2 tx.validityRange req.submittedAt p
  | .Contribute stateRef, .RequestDatum req =>
      (∃ si ∈ tx.inputs, si.ref = stateRef ∧
       ∃ tid, si.token = some tid ∧ requestBound req tid) ∧
      (inPhase1 tx.validityRange req.submittedAt p ∨
       isRejectable tx.validityRange req.submittedAt p)
  | .Modify proofs, .StateDatum state =>
      oracleAuthorized state tx ∧
      (∃ o, tx.outputs.head? = some o ∧ tokenConfined self o) ∧
      True  -- + rootIntegrity + feeEnforced + proofConsumption (elided)
  | .Reject, .StateDatum state =>
      oracleAuthorized state tx ∧
      (∃ o, tx.outputs.head? = some o ∧ tokenConfined self o ∧
       ∃ s, o.datum = some (CageDatum.StateDatum s) ∧ s.root = state.root)
  | .End, .StateDatum state =>
      oracleAuthorized state tx ∧
      burnIntegrity policyId (sorry : TokenId) tx  -- token extracted from self
  | _, _ => False
