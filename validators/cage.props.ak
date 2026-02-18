/// Phase property tests (fuzz) — mirror Lean theorems in MpfsCage/Phases.lean.
///
/// These property tests verify the time-gated phase system that governs
/// who can act on a request and when. The cage lifecycle is divided into
/// three mutually exclusive phases:
///
/// ```
///   submitted_at          +process_time    +retract_time
///       |--- Phase 1 ---------|--- Phase 2 ---|--- Phase 3 --->
///       Oracle processes       Requester       Cage owner
///       requests (Modify)      can Retract     can Reject
/// ```
///
/// **Phase 1** (oracle processing): The oracle folds requests into the MPF.
///   Contribute is allowed (linking requests to a cage).
///
/// **Phase 2** (requester retract): Only the requester can act — they may
///   Retract their unprocessed request and reclaim their ADA.
///
/// **Phase 3** (rejectable): The retract window has expired. The cage owner
///   can Reject expired requests. Additionally, any request with a dishonest
///   `submitted_at` (in the future) is rejectable in any phase.
///
/// These fuzz tests verify, for randomly generated parameters, that:
/// 1. The phases never overlap (mutual exclusion).
/// 2. Honest requests in Phase 1 or 2 are never rejectable (safety).
/// 3. Every point in time falls into at least one phase (coverage).
///
/// Each property mirrors a machine-checked Lean 4 theorem. The Lean proofs
/// provide mathematical certainty; the fuzz tests validate the Aiken
/// implementation matches the formal specification.
///
/// **Fuzzer ranges**: `submitted_at` in [0, 100k], `process_time` in [1, 50k],
/// `retract_time` in [1, 50k], validity range start in [0, 200k] with span
/// in [1, 50k]. These cover a wide range of realistic and edge-case timing
/// configurations.
use aiken/fuzz
use aiken/interval
use cage.{in_phase1, in_phase2, is_rejectable}

/// **Lean: phase1_phase2_exclusive**
///
/// No validity range can satisfy both `in_phase1` and `in_phase2` simultaneously.
///
/// Phase 1 requires the range to be entirely before `submitted_at + process_time`.
/// Phase 2 requires it to be entirely after `submitted_at + process_time - 1`.
/// These conditions are contradictory: a range cannot be both before and after
/// the same boundary.
///
/// If this property failed, a transaction could be valid in both phases,
/// allowing the oracle to Modify AND the requester to Retract the same
/// request — a double-spend.
test prop_phase1_phase2_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000))),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  !(p1 && p2)
}

/// **Lean: phase1_phase3_exclusive**
///
/// Phase 1 and Phase 3 (rejectable via expiry) are mutually exclusive.
///
/// Phase 1 requires the range to be entirely before `submitted_at + process_time`.
/// Phase 3 (expiry path of `is_rejectable`) requires the range to be entirely
/// after `submitted_at + process_time + retract_time - 1`.
/// Since `process_time >= 1` and `retract_time >= 1`, there is always a gap
/// (Phase 2) between them.
///
/// If this property failed, the oracle could process a request that was
/// simultaneously rejectable — the cage owner could reject it and pocket
/// the fee while the oracle's work was wasted.
test prop_phase1_phase3_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000))),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p3 =
    interval.is_entirely_after(
      range,
      submitted_at + process_time + retract_time - 1,
    )
  !(p1 && p3)
}

/// **Lean: phase2_phase3_exclusive**
///
/// Phases 2 and 3 are mutually exclusive.
///
/// Phase 2 requires the range to be entirely before
/// `submitted_at + process_time + retract_time`.
/// Phase 3 requires it to be entirely after
/// `submitted_at + process_time + retract_time - 1`.
/// A range cannot be both before and after the same boundary.
///
/// If this property failed, a requester could Retract their request while
/// the cage owner simultaneously Rejects it — a race condition that would
/// let both parties claim the same ADA.
test prop_phase2_phase3_exclusive(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000))),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let range = interval.between(lo, lo + span)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  let p3 =
    interval.is_entirely_after(
      range,
      submitted_at + process_time + retract_time - 1,
    )
  !(p2 && p3)
}

/// **Lean: phase1_honest_not_rejectable**
///
/// An honest request (submitted_at <= range_start) in Phase 1 can never
/// be rejected.
///
/// "Honest" means the requester didn't lie about their submission time —
/// `submitted_at` is at or before the validity range start. Under this
/// assumption, if the request is in Phase 1 (oracle is still processing),
/// `is_rejectable` must return false.
///
/// This is a critical safety property: it guarantees that honest requesters
/// who submitted during the processing window can never have their requests
/// prematurely rejected. The oracle has the full `process_time` window to
/// fold the request into the MPF without interference.
///
/// The fuzzer clamps `submitted_at` to `min(submitted_at, lo)` to enforce
/// the honesty precondition.
test prop_phase1_honest_not_rejectable(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000))),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  // Enforce honesty: submitted_at <= lo
  let honest_submitted = if submitted_at <= lo { submitted_at } else { lo }
  let range = interval.between(lo, lo + span)
  let p1 = in_phase1(range, honest_submitted, process_time)
  let rej =
    is_rejectable(range, honest_submitted, process_time, retract_time)
  !(p1 && rej)
}

/// **Lean: phase2_honest_not_rejectable**
///
/// An honest request in Phase 2 (retract window) can never be rejected.
///
/// Same honesty assumption as above. If a request is in Phase 2, the
/// requester has the exclusive right to Retract it. The cage owner cannot
/// Reject it during this window.
///
/// This protects requesters from a race: without this property, the cage
/// owner could Reject a request during the retract window, stealing the
/// requester's chance to reclaim their full ADA (rejection only refunds
/// ADA minus fee, while retraction returns everything).
test prop_phase2_honest_not_rejectable(
  params via fuzz.tuple(
    fuzz.tuple(fuzz.int_between(0, 100_000), fuzz.int_between(1, 50_000)),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.tuple(fuzz.int_between(0, 200_000), fuzz.int_between(1, 50_000))),
  ),
) {
  let ((submitted_at, process_time), (retract_time, (lo, span))) = params
  let honest_submitted = if submitted_at <= lo { submitted_at } else { lo }
  let range = interval.between(lo, lo + span)
  let p2 =
    in_phase2(range, honest_submitted, process_time, retract_time)
  let rej =
    is_rejectable(range, honest_submitted, process_time, retract_time)
  !(p2 && rej)
}

/// **Lean: phase_coverage_point**
///
/// For any single-slot validity range [t, t+1) with an honest timestamp
/// (submitted_at = 0), at least one of {Phase 1, Phase 2, rejectable} holds.
///
/// This is the completeness property: the three phases cover the entire
/// timeline with no gaps. At every point in time, some action is available
/// for an honest request — it's either being processed (Phase 1), retractable
/// (Phase 2), or rejectable (Phase 3).
///
/// Without this property, there could be "dead zones" where a request is
/// stuck: the oracle can't process it, the requester can't retract it, and
/// the cage owner can't reject it — locking the ADA forever.
///
/// Uses a point range [t, t+1) rather than an arbitrary range because
/// coverage for intervals follows from coverage for points (if every point
/// is covered, every interval touching that point is in at least one phase).
test prop_phase_coverage_point(
  params via fuzz.tuple(
    fuzz.int_between(0, 100_000),
    fuzz.tuple(fuzz.int_between(1, 50_000), fuzz.int_between(1, 50_000)),
  ),
) {
  let (t, (process_time, retract_time)) = params
  // honest: submitted_at = 0 <= t (always true since t >= 0)
  let submitted_at = 0
  let range = interval.between(t, t + 1)
  let p1 = in_phase1(range, submitted_at, process_time)
  let p2 = in_phase2(range, submitted_at, process_time, retract_time)
  let rej = is_rejectable(range, submitted_at, process_time, retract_time)
  p1 || p2 || rej
}
