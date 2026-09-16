# WES2 hint-cascade repair — decision log

Newest first within each section. "Settled" = decided by Richard/review in the
v1–v5 thread and not to be re-asked. "Plan v6" = technical choices made in
this plan, open to review.

## Settled product decisions (carried from v1–v5)

* S-01 Next set consumes the previous set's current final actual-or-hint
  mix. Anchoring later sets to immutable plan/Set 1 intent was **rejected**.
* S-02 A set's own stale generated hints never feed its own regeneration.
* S-03 Formulas/inverses unchanged this release; replacement is a separate task.
* S-04 WES2 actuals > explicit BB3 prescriptions > generated hints.
* S-05 Previous set's **entered** RIR > 2.5 alone grants heavier weights.
* S-06 Recursive memoised accepted-hint view is the accepted direction.
* S-07 Replace contaminated baseline RIR cue with a current-context in-memory
  reference.
* S-08 Timed Set 2+ consumes actual-or-hint seconds/weight.
* S-09 Shared BB3 day panel uses the corrected cascade.
* S-10 Invalid text: keep last valid model value while typing; restore on
  blur/Done/exit; never manufacture zero or accept a hint.
* S-11 Saved structure wins; planned sets need manual re-adding; prescriptions
  positional after deletion.
* S-12 Durable Undo **now** for deleted sets and deleted exercises (incl. only
  set). G2: add set / replace / move circuit / template / delete-all stay
  session-local, stated honestly.
* S-13 G1: additive `wes2OpReceipts` approved in principle; unsafe pruning not
  approved.
* S-14 Needs-attention recovery sheet and Not-saved marker accepted.
* S-15 Release includes version bump and verified signed AAB via
  `/goodlift-release`; Richard uploads and phone-tests.
* S-16 (2026-09-16) `wes2OpReceipts` may carry a revision, row hashes and a
  bounded change log, approved in principle, on three conditions: they may
  only permit a concurrent edit when identity and history establish
  compatibility; missing or expired history falls back to a visible conflict;
  hashes never substitute for set identity; pruning the log never removes
  durable replay protection. (PLAN §9.3, §10.2)
* S-17 (2026-09-16) Genuinely unresolved legacy draft values are retained as
  separate *Not saved* recovery items, shown apart from active entries and
  excluded from the cascade. Ordinary entries — including offline entries
  awaiting sync — drive hints immediately. A recovery value restored onto a
  safely identified set becomes an actual and drives hints immediately,
  without waiting for server confirmation. Nothing is ever displayed as an
  ordinary entry while the cascade calculates from something else.
  (PLAN §9.5a, §13)
* S-18 (2026-09-16) Final verification must exercise the real screen and
  runner and prove each set consumes the previous set's final displayed
  actual/hint combination; existing passing suites do not substitute.
  (PLAN §15, `wes2_screen_cascade_e2e_test.dart`)

## Rejected designs (evidence only)

* v1: free-result-only acceptance comparison; leaving deleted-set
  resurrection and offline BB3 provenance; baseline RIR cue; global-optimum
  claim; tests detached from screen orchestration.
* v3: restore-by-count/value equality with queue resequencing (U5, identical
  sets, same-index removals, backoff overtaking, stale ack, media ordering,
  maintenance, only-set route).
* v4: receipt pruning 30 d/100; count-only conflicts; id-protected removal with
  index-based later patches; mutation-on-old-shadow; replaying reindexed v1
  rows; shadow creation discarding draft values; maintenance gap-as-crash.
* v5: before/after signatures and content-token retargeting (unique content,
  missing content, return-to-pre, id-only signatures, preparing record in live
  process).

## Plan v6 technical decisions

* D-001 Hint matching uses **formatted-text equality** with the widget
  formatters (weight 3 dp stripped, RIR 1 dp, reps exact) instead of
  ±0.0005/±0.05. Evidence: `0.15→"0.1"`, `2.55→"2.5"` (PROBES.md).
* D-002 Input builder removes all model hints; prescriptions come only from a
  separate positional store with explicit source.
* D-003 Set N centre: constraint / inverse at constrained or `previousOrSame`
  weight / validated fallback (prev reps else 8); inputs validated before the
  inverse because `NaN.clamp(1,45) == 45`.
* D-004 Set 1 fallback E1RM from `view(0, ∅)` of the same pass (or stored pure
  Set 1 context offline).
* D-005 Recompute is forward-only from the edited set; earlier finals reused.
* D-006 Replay evidence = per-stream max-applied-seq checkpoint in the
  document (never pruned). Stream = installationId|actorUid.
* D-007 Concurrency/identity: setId → whole-row equality with authoring frame →
  logged structural token rebase (P-META) → else conflict. No content
  retargeting.
* D-008 Destructive ops validate full removed content.
* D-009 Shadow updated only from transaction results or fresh (non-cache)
  reads not overtaken by a confirmation (`commitCounter`).
* D-010 Negative RIR remains accepted (unchanged range); only syntax/finiteness
  tightened.
* D-011 Decimal-only syntax: `1e3`, hex and whitespace-only-number forms are
  invalid (previously `double.tryParse`/`int.tryParse` accepted them).
* D-012 The acceptance gate covers all supported Set 1 progression models. An
  I1 violation is recorded here as a concrete counterexample and resolved on
  its merits (make the raw computation independent of the irrelevant entries,
  or an explicit reviewed rule for that model) — never by weakening
  accepted-hint behaviour, narrowing the model set, or changing the E1RM
  formula/inverse.
* D-013 v1 queue rows are never SQL-rewritten; legacy reconciliation runs
  online, compares with the draft, and otherwise creates Needs-attention items.
* D-014 Holds store prior `deletedAt/suppressed`; rollback/Undo restore prior
  state rather than blanket un-suppressing.
* D-015 Structural Undo entries survive a successful reload (restore into
  current state); discarded on date/athlete change, dispose, overflow, restart.
* D-016 `raiseSetCount` keeps raise-only (`max`) semantics for blank sets.
* D-017 Conflict at a day's head pauses that day's later syncing (per brief:
  earliest unresolved per athlete/day).

## v6.1 corrections from review R1–R9 (2026-09-16)

* D-018 (R1) Undo-opportunity lifetime is durable and separate from "operation
  executing": records carry `sessionId`; ordinary maintenance never discards a
  `live` record of the current session; discard triggers are the closed list in
  PLAN §12.4. Holding the mutex does not protect a completed operation's Undo.
* D-019 (R1) `publishedAtMs` marks controller publication; an exception after
  the durable transition republishes from durable state instead of leaving a
  changed database behind an unchanged screen. Holds and media association
  survive.
* D-020 (R2) `everAttempted` is durable attempt evidence written inside the
  claim transaction. Cancellation of a queued removal is legal only when it is
  false, tested atomically against claiming. Attempted ops are never coalesced
  and never silently discarded; discarding one reconciles and then compensates.
* D-021 (R3) Document lineage = `epoch` equal to the creating op's durable
  `bootstrapId`; missing receipts are never proof of non-application. An
  attempted creating/destructive op meeting no receipts is
  `uncertainFirstWrite` (visible recovery).
* D-022 (R3) Stream identity carries an `era`; a restored/rolled-back outbox
  database is detected at first contact (`applied.seq >= nextSeq` under the
  same era) and rotates its era before writing, so new edits are never absorbed
  as already applied.
* D-023 (R4) Recorded history is consulted before any positional shortcut.
  Whole-row equality authorises only where no history exists at all
  (pre-bootstrap); the residual ABA limit is stated in PLAN §16. Every
  committing path — including `setId`-targeted writes — snapshots all rows
  before mutating and records `breaks[ex] = newRev` before refreshing
  `rowHash`.
* D-024 (R5) Legacy auto-conversion requires pre-state identity or pre-state
  row equality per operation. Post-state agreement with the draft is
  corroboration only. A no-op count guard is an unknown outcome, not an
  acknowledgement.
* D-025 (R6) A coalesced replacement is authored against the frame of the op it
  replaces, in one transaction that remaps every reference to the replaced seq.
* D-026 (R7) `resolveForDisplay` (target only) is separate from
  `resolveForCommit` (full prerequisites); commit prerequisites never demote a
  safely identified pending entry from the cascade.
* D-027 (R8) Shadow writes are guarded in the repository by `rev`, then
  `loadGen`, with `commitCounter`, checked and written in one local
  transaction.
* D-028 (R9) Predecessor agreement is asserted numerically on model values
  first, then provenance, then rendered text; actuals are never rounded and
  focused text is never restored early to satisfy a display assertion.
* D-029 An isolated protocol prototype under `docs/wes2-cascade/prototype/`
  models these transitions. It is a specification aid, never a production gate,
  and it already caught one defect in the first draft of D-023 (break stamped
  with the wrong revision; target row compared after mutation).

## Stage 1 implementation decisions (2026-09-16, as built)

* D-101 Scope decision from Richard: Stage 1 = hints only, on the EXISTING
  persistence architecture; Stage 2 = the specific reproduced Undo/offline
  failures. The v6.1 protocol is archived as background
  (`ARCHIVE_v6.1_protocol.md`), not a deliverable.
* D-102 `resolveRow` lives on the `Wes2HintService` **interface**, not only the
  implementation, so existing spies/doubles keep working and the controller
  does not narrow to a concrete type.
* D-103 `structureEstablished` on `Wes2ExerciseRow` marks session structure
  (saved row, add/remove set). The hint pass never grows such a row back to the
  planned count. Plan-only rows still take their initial count from the plan.
* D-104 The controller keeps `setHintService` (register only) alongside the new
  `applyHintContext` (register + resolve + notify once), so existing callers
  and tests are unaffected.
* D-105 The hint pass moved into `Wes2HintLoadRunner`, which owns the settings
  and type caches. The screen reads `_hintRunner.settings`; the settings sheet
  calls `invalidateSettings()` **before** awaiting, so a response already in
  flight cannot reinstate the old settings.
* D-106 `Wes2Screen` itself is still not pumped in tests (it builds its
  repository, local store and sync services internally). The runner, controller,
  service and row widget are all exercised for real; adding screen-level seams
  is deferred to Stage 2, which touches the same wiring.
* D-107 The all-model acceptance gate (4 progression models × history
  present/absent × 3 sets) found **no** I1 counterexample, so no model-specific
  rule was needed.
* D-108 Two existing tests were updated with written reasons (PLAN §S1-5): the
  same-value suppression assertion encoded the defect, and two reference models
  hard-coded the old rep centre. No cap, lock, legality or isolation assertion
  was weakened.

## Open

None. U-1 and U-2 were decided on 2026-09-16 — see S-16 and S-17 above and
PLAN.md §18. Implementation approval itself is still pending review of the
full plan.

## Incompatibilities discovered during implementation

(none yet — implementation not started)
