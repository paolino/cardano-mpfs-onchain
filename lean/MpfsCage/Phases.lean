/-!
# MPFS Cage — Time-Phase Logic

Formal model of the three-phase request lifecycle from the
cardano-mpfs-onchain Aiken validators.

## Phases

Given `submitted_at`, `process_time`, and `retract_time` (all positive):

- **Phase 1** (oracle processes): `[submitted_at, submitted_at + process_time)`
- **Phase 2** (requester retracts): `[submitted_at + process_time, submitted_at + process_time + retract_time)`
- **Phase 3** (oracle rejects): `[submitted_at + process_time + retract_time, +∞)`

Additionally, a request with `submitted_at` in the future (dishonest)
is always rejectable.

A transaction's validity range `[lo, hi)` must fall entirely within
one phase.
-/

/-- A validity range represented as a closed-open interval `[lo, hi)`.
    Mirrors Cardano's `ValidityRange` (slot-based). -/
structure ValidityRange where
  lo : Int
  hi : Int
  valid : lo < hi

/-- Phase parameters for the cage validator. -/
structure PhaseParams where
  processTime : Int
  retractTime : Int
  processPos : 0 < processTime
  retractPos : 0 < retractTime

/-- The validity range ends strictly before `bound`.
    Mirrors Aiken's `interval.is_entirely_before`. -/
def isEntirelyBefore (vr : ValidityRange) (bound : Int) : Prop :=
  vr.hi ≤ bound

/-- The validity range starts at or after `bound + 1`.
    Mirrors Aiken's `interval.is_entirely_after(range, bound)`.
    In Aiken, `is_entirely_after(range, x)` means `range.lo > x`,
    i.e. `range.lo ≥ x + 1`. -/
def isEntirelyAfter (vr : ValidityRange) (bound : Int) : Prop :=
  bound + 1 ≤ vr.lo

-- ============================================================
-- Phase predicates (matching Aiken implementation)
-- ============================================================

/-- Phase 1: oracle processing window.
    `vr` is entirely before `submitted_at + process_time`. -/
def inPhase1 (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) : Prop :=
  isEntirelyBefore vr (submittedAt + p.processTime)

/-- Phase 2: requester retract window.
    `vr` is entirely after `submitted_at + process_time - 1`
    AND entirely before `submitted_at + process_time + retract_time`. -/
def inPhase2 (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) : Prop :=
  isEntirelyAfter vr (submittedAt + p.processTime - 1) ∧
  isEntirelyBefore vr (submittedAt + p.processTime + p.retractTime)

/-- A request is rejectable when either:
    - Phase 3: retract window expired, OR
    - Dishonest: `submitted_at` is in the future. -/
def isRejectable (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) : Prop :=
  isEntirelyAfter vr (submittedAt + p.processTime + p.retractTime - 1) ∨
  isEntirelyBefore vr submittedAt

-- ============================================================
-- Security properties
-- ============================================================

/-- Phases 1 and 2 are mutually exclusive:
    no validity range can be in both phases simultaneously. -/
theorem phase1_phase2_exclusive
    (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) :
    inPhase1 vr submittedAt p → inPhase2 vr submittedAt p → False := by
  intro h1 h2
  unfold inPhase1 isEntirelyBefore at h1
  unfold inPhase2 isEntirelyAfter at h2
  obtain ⟨h2a, _⟩ := h2
  -- h1 : vr.hi ≤ submittedAt + p.processTime
  -- h2a : submittedAt + p.processTime - 1 + 1 ≤ vr.lo
  -- i.e. submittedAt + p.processTime ≤ vr.lo
  -- But vr.lo < vr.hi (from vr.valid), so
  -- submittedAt + p.processTime ≤ vr.lo < vr.hi ≤ submittedAt + p.processTime
  -- Contradiction.
  have hlo := vr.valid  -- vr.lo < vr.hi
  omega

/-- Phase 1 and Phase 3 (part of rejectable) are mutually exclusive. -/
theorem phase1_phase3_exclusive
    (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) :
    inPhase1 vr submittedAt p →
    isEntirelyAfter vr (submittedAt + p.processTime + p.retractTime - 1) →
    False := by
  intro h1 h3
  unfold inPhase1 isEntirelyBefore at h1
  unfold isEntirelyAfter at h3
  have hlo := vr.valid
  have hrt := p.retractPos
  omega

/-- Phase 2 and Phase 3 are mutually exclusive. -/
theorem phase2_phase3_exclusive
    (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams) :
    inPhase2 vr submittedAt p →
    isEntirelyAfter vr (submittedAt + p.processTime + p.retractTime - 1) →
    False := by
  intro h2 h3
  unfold inPhase2 isEntirelyBefore isEntirelyAfter at h2
  unfold isEntirelyAfter at h3
  obtain ⟨h2a, h2b⟩ := h2
  have hlo := vr.valid
  have hpt := p.processPos
  have hrt := p.retractPos
  omega

/-- A honest request (submitted_at ≤ vr.lo) in Phase 1 is NOT rejectable. -/
theorem phase1_honest_not_rejectable
    (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams)
    (honest : submittedAt ≤ vr.lo) :
    inPhase1 vr submittedAt p → isRejectable vr submittedAt p → False := by
  intro h1 hr
  unfold isRejectable at hr
  cases hr with
  | inl h3 => exact phase1_phase3_exclusive vr submittedAt p h1 h3
  | inr hdishonest =>
    unfold isEntirelyBefore at hdishonest
    -- hdishonest: vr.hi ≤ submittedAt
    -- honest: submittedAt ≤ vr.lo
    -- vr.lo < vr.hi (valid)
    -- so submittedAt ≤ vr.lo < vr.hi ≤ submittedAt → contradiction
    have hlo := vr.valid
    omega

/-- Phase 2 with honest timestamp is not rejectable. -/
theorem phase2_honest_not_rejectable
    (vr : ValidityRange) (submittedAt : Int) (p : PhaseParams)
    (honest : submittedAt ≤ vr.lo) :
    inPhase2 vr submittedAt p → isRejectable vr submittedAt p → False := by
  intro h2 hr
  unfold isRejectable at hr
  cases hr with
  | inl h3 => exact phase2_phase3_exclusive vr submittedAt p h2 h3
  | inr hdishonest =>
    unfold isEntirelyBefore at hdishonest
    have hlo := vr.valid
    omega

/-- For any point in time (single-slot validity range) with honest
    timestamp, exactly one phase applies.

    A validity range that straddles a phase boundary won't match any
    phase — the validator rejects such transactions. This theorem
    shows the phases cover all time for well-formed (single-slot)
    ranges. -/
theorem phase_coverage_point
    (t : Int) (submittedAt : Int) (p : PhaseParams)
    (_honest : submittedAt ≤ t) :
    let vr : ValidityRange := ⟨t, t + 1, by omega⟩
    inPhase1 vr submittedAt p ∨
    inPhase2 vr submittedAt p ∨
    isRejectable vr submittedAt p := by
  simp only
  unfold inPhase1 inPhase2 isRejectable isEntirelyBefore isEntirelyAfter
  simp only
  have hpt := p.processPos
  have hrt := p.retractPos
  omega
