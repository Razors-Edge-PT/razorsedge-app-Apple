# ARCHIVE — v6.1 persistence protocol (NOT APPROVED FOR IMPLEMENTATION)

Kept for reference only. The 2026-09-16 scope decision limits Stage 2 to the
smallest repairs for the specific reproduced failures listed in NEXT.md; the
general protocol below (stream eras, document epochs, shadows, structural
logs, legacy reconciliation) is background material, not a deliverable.
Sections 3-7 (the hint contract) were implemented in Stage 1 and are now
described in PLAN.md.

---

# WES2 live hint cascade + durable structural edits — consolidated plan (v6.1)

Status: **PLAN FOR REVIEW. Nothing implemented.** Implementation approval
pending. v6.1 corrects the persistence, migration, rendering and structural
Undo mechanics raised in review R1–R9; the hint contract, recursive
acceptance, inverse centre, parsing, prescriptions, offline modes, Set 1 scope,
production-screen gate and release requirements are unchanged from v6.
Companion files: `DECISIONS.md` (decision log), `PROBES.md` (evidence),
`NEXT.md` (resume point), `prototype/protocol_prototype_test.dart` (isolated
specification model of the corrected transitions — **not** production code and
not a production gate). Rejected earlier designs are evidence only.
§19 maps each review point to the sections and named regressions that answer
it.

---

## 0. Repository and recovery state (verified 2026-09-16)

* `origin/main` = `abdaa477`, `pubspec.yaml` version `1.7.31+101`
  (historical; the release version is decided at release time, §17).
* Main checkout `C:\Projects\RE-test` on `main`: untracked `android/build/`,
  a modified `.docx` and an Office lock file — **not ours; untouched.**
* Other worktrees: `RE-final` (detached, 52 behind), `RE-profile`
  (`feature/profile-showcase-v2`), `RE-repair`
  (`fix/wes2-set-video-release-blockers`, 0 ahead / 55 behind, i.e. merged).
  None contains cascade work. Untouched.
* The planned `C:\Projects\RE-wes2-cascade` / `fix/wes2-live-hint-cascade`
  did **not** exist. Created from `origin/main` today. No `AGENTS.md` exists.
* Implemented so far: **nothing.** Uncommitted in the new worktree: only
  `docs/wes2-cascade/**` (this plan, logs, recovered probes, repro file).
* Surviving scratch probes from lost session `848fba5c` were found in its
  scratchpad and copied to `docs/wes2-cascade/recovered-probes/`. They are
  throwaway and are not gates. Re-run results: `PROBES.md`.

## 1. Scope

In scope (one release):

1. Hint cascade contract (§3) incl. limited Set 1 post-processing, BB3 day
   panel, timed sets, text entry, async orchestration, set structure,
   offline hint context.
2. Durable persistence protocol for WES2 execution data (§8–§11): ordering,
   identity, replay evidence, authoritative shadow, conflicts, v1 migration,
   unsaved legacy values.
3. Durable Undo for **deleted sets and deleted exercises** (incl. removing
   the only set) with media recovery (§12).

Out of scope (explicit): formula/inverse changes; progression redesign;
durable Undo for add set / replace exercise / move circuit / template
replacement / delete-all (G2 — their session-local snapshot Undo remains,
limitations in §16); eager setId minting on legacy sets; BB3-planned-row set
removal (still blocked with its existing snackbar); `PeriodizationModelUtils`
changes (none planned; if one becomes necessary I stop and ask); unrelated
refactors/formatting; the coach-recap deployment.

## 2. Evidence (details in PROBES.md)

Screenshot evidence (transcribed, never re-derived): Curl S1 22.5×9@0.5
(29.5), S2 weight 22.5 hinted 24 reps @2 (42.0), S3 20×17@2.5 (41.1). Triceps
S4 40×7@0.5 (48.8) → S5 36×25@0.5 (66.6). Historical top sets do not
establish the edit sequence and are not a target.

Reproduced today on unmodified code: D1–D8, D3 via literal fixtures, the
accepted 40×10 RIR flip in both orders, non-finite parsing, hintOrigin loss
(D11), non-durable Undo, localSeq collapse, `saveSetId` DI, zero-window media
purge, and the v1 queue failures (C→100 lost, B+C removals both lost, backoff
overtaking, in-flight ack deleting newer intent). D9 (async race) and D10
(timed) are confirmed by code reading (`WES2_screen.dart:690-875`,
`WES2_hint_service.dart:762-781`); their production-path reproductions are
implementation step A0 (they need the extracted runner/widget harness).

---

## 3. Hint cascade

### 3.1 Data separation

| Kind | Where | Lifetime |
|---|---|---|
| **Actual** | `Wes2FieldState.actualValue` (+ `origin typed/completed`) | execution data |
| **Prescription** | new `Wes2Prescriptions` per exercise, positional list of `{weight?, reps?, rir?, velocity?, planNote?}` + `exercisePlanNote` + `source` (`server`, `firestoreCache`, `localStored`) | controller map `_prescriptions[exerciseId]`; persisted locally only (§7) |
| **Derived hint** | `hintValue` with `hintOrigin modelHint`, cue flags, new in-memory `rirReferenceHint` | recomputed; never an input |

A prescription is displayed as a hint with `hintOrigin bb3Hint`, exactly as
today, but its *source of truth* is `_prescriptions`, never a row's current
`hintValue`. Generated hints and schema-1 draft hints (missing origin) never
become prescriptions.

### 3.2 One input builder

`Wes2HintInput.build(row, prescriptions)` (new, `lib/wes2_hint_input.dart`)
is the **only** way to build service input, used by edit, clear, load,
refresh, add/remove/restore set, replace, template, undo, recovery and the
settings/history runner:

* each set `i < row.setCount`: `actualValue` copied **unconditionally** (no
  suppression, equal-to-hint values included, RIR 0 included, velocity
  included), `setId`, `executionNote` copied;
* prescription `i` (if any) injected as `hintValue` + `hintOrigin bb3Hint`;
* no model hints, no cue flags, no `planNote` from row hints (plan notes come
  from prescriptions).

Removed: `_baselineHintRows`, `captureBaselineHintRows`,
`_rowWithCurrentActualsOverBaseline`, `_sameAsHint*`, `applyModelHints`,
`baselineRirHintFor` (callers updated). This removes D1, D2, D4, D5, D7.

### 3.3 Resolution algorithm (per row, per pass)

Context `C` fixed for the pass: settings map + settings generation, history
snapshot generation, block dates, week/session index, uid, date, exercise
types, prescriptions. Pass entry point:
`Wes2CascadeResolver.resolveRow(input, C, {fromSet = 0, previous})`.

```
prev := (fromSet == 0) ? null : final(fromSet-1)   // earlier finals reused verbatim
for i in fromSet ..< setCount:
    E    := entered fields of set i among {weight, reps, rir}   // mask + values
    memo := {}                                                    // per set i, this pass only
    V    := view(i, E)                                            // §3.4
    final(i) := V.hints/cues with ALL actuals of set i attached   // incl. velocity, notes, setId
    prev := final(i)
return row(final(0..n-1))
```

* `raw(i, E)` = service per-set computation for set `i` whose input carries
  only the actuals in `E` plus prescription `i`, with predecessor `prev`
  (Set 1 path when `i == 0`). All snapping, caps, drop gating, late RIR solve,
  timed handling, cue flags and `_mergeDouble/_mergeInt` happen inside raw.
* Predecessor handed to set `i+1` is `final(i)` — per field
  `actual ?? hint`; RIR actual provenance preserved separately
  (`rir.actualValue` stays distinguishable from `rir.hintValue`), so the cap
  permission (`Wes2SetNSolver.mayIncrease`) only sees entered RIR.
* Hypothetical subviews exist only inside `view`; they never feed `prev`.
* Forward-only: an edit at set `k` recomputes `fromSet = k`; sets `< k` are
  reused object-for-object (test asserts identity).
* Deterministic: output is a pure function of (input, C). No own hint, no
  previous pass output, no edit order enters it.

### 3.4 Accepted-hint view

```
view(i, E):
  if memo[E] exists: return memo[E]
  for f in [weight, reps, rir] where f ∈ E:            // fixed order
      S := view(i, E \ {f})
      if matches(f, E[f], S.hint[f]):
          memo[E] := S.hints + S.cues (remaining fields), actuals E attached
          return memo[E]
  memo[E] := raw(i, E)
  return memo[E]
```

`matches` corresponds to the widget formatter exactly (verified in PROBES.md):

* weight: `fmtWeight(actual) == fmtWeight(hint)` (`toStringAsFixed(3)`,
  trailing zeros stripped);
* reps: `actual == hint`;
* RIR: `actual.toStringAsFixed(1) == hint.toStringAsFixed(1)`.

The earlier ±0.0005 / ±0.05 tolerances are **replaced**: `0.15` displays
`0.1` and `2.55` displays `2.5`, so a symmetric tolerance accepts values the
user never saw. Hint `null` never matches.

Consequences, all tested:

* 40×10@2 counterexample (target 56.8): `view({w:40, r:10})` → f=weight:
  `view({r:10})` has weight hint 40 → reuse its RIR hint 2 (no late solve).
  Reps-first order reaches the same memo. S3 sees 40×10@2 ⇒ 35×13@2.
* Accepting displayed `1.3` for internal 1.25 matches (same text); actual
  1.3 then feeds downstream — a legitimate change (§3.9).
* Entered RIR 2.5 vs 3.0 on the predecessor: both are actuals; only 3.0
  (> 2.5) opens heavier candidates. A *hinted* 3.0 never does.
* BB3 reps lock accepted: prescription reps is already a constraint, so
  typing it produces the same constraint set; view reuse keeps cues stable.

**I1 (supporting invariant).** With RIR not entered and not both weight and
reps entered, raw's RIR hint does not depend on this set's weight/reps
entries. Set N: RIR hint = `constrainedRir ?? inherited/plan RIR`, independent
by construction; the late RIR solve (both entered) is the exception. Set 1:
RIR comes from `BB3HintService`/plan — **I1 must be verified per progression
model** (probe4 covered Linear Classic only). Under I1, when several subviews
match they differ only in which entered field they hint, and their remaining
visible hints/cues agree; the field order is then only a tie-break, not the
proof. Tests guard I1 and ambiguous agreement exhaustively (§15, H-VIEW-*).
The acceptance gate runs across **all supported Set 1 progression models**. If
a model violates I1, the concrete counterexample (model, fixture, entry set,
the two disagreeing subviews and their hints) is recorded in DECISIONS.md and
resolved on its merits — by making the affected raw computation independent of
the irrelevant entries, or by an explicit, reviewed rule for that model. It is
**not** resolved by weakening accepted-hint behaviour (no reverting to
"accepting re-solves the set"), by narrowing the tested model set, or by
touching the E1RM formula/inverse.

### 3.5 Set N rep centre (D3)

Replace `preferredRep = own hint → plan reps → prev reps → 8` with:

| Case | Centre | Source tag |
|---|---|---|
| reps constrained (actual or BB3) | `creps` | `constraint` |
| weight constrained | `round(reverseCalculateReps(target, toAbs(cwt), thisRir))` | `inverse` / `clamp` |
| joint search | `W0 = grid.previousOrSame(prevWeight)`; `round(reverseCalculateReps(target, toAbs(W0), thisRir))` | `inverse` / `clamp` |
| invalid: `target`, `toAbs(w)` not finite or ≤ 0, `W0` null, result not finite | valid `prevReps > 0` else 8 | `fallback` |

Inputs are validated **before** calling the inverse because
`double.nan.clamp(1, 45)` returns 45. `clamp` is reported when the returned
value is exactly 1.0 or 45.0 (a documented approximation — an exact inverse
of 1 or 45 is tagged `clamp`). `Wes2SetNCentre{rep, source}` is exposed via
`@visibleForTesting` and written to `Wes2HintTrace`.

Unchanged: candidate domain (`W0`, two steps down, two up only when previous
**entered** RIR > 2.5), ±5 rep window clamped 1–100, target/drop gating,
scoring, tie ladder, cap, extra-set RIR inheritance, bodyweight scoring in
absolute load with candidates in display-added units. No candidates → no
generated hint (existing `null` path, no fabrication). The bounded search is
**not** a global optimum (target 31 / 15 kg / RIR 2 example, PROBES.md).

Literal fixtures (independent arithmetic + bounded-search assertions): 40×10@2
→ 56.8 → S2 free 35×13@2; 20×20@0 → 41.3529 → 15×22@2; 40×7@2 with S2 weight
20 → 50.6286 → 21 reps @2; stale own rep hint 30 has no effect (the builder
removes it); inverse-clamped high target; negative-assisted and empty-candidate
cases produce no hint.

### 3.6 Set 1 post-processing (authorised, limited)

* Baseline fallback E1RM (`WES2_hint_service.dart:513-532`, reads the set's
  own hints) → **pure Set 1 context**: E1RM of `view(0, ∅)` from the same
  pass (memoised), or the stored pure Set 1 context in offline mode (§7).
* Anchoring (`:401-416`) reads `set.reps.hintValue` — with the builder that is
  a prescription only, so behaviour is stable; code unchanged.
* Late RIR solve, closest-E1RM weight, cue flags, BB3HintService, progression
  engine, formulas: unchanged.

### 3.7 RIR direction cue

`rirReferenceHint` (in-memory on `Wes2SetState`, not serialised) = RIR hint of
`view(i, E \ {weight, reps})` for the current predecessor. `Wes2SetRow`
colours against it instead of `baselineRirHint`. Not written to drafts or
Firestore.

### 3.8 Timed sets (D10)

Set 2+ timed: seconds = `prev.reps.actual ?? prev.reps.hint`; weighted timed
weight = `prev.weight.actual ?? prev.weight.hint`; no rep/RIR solving. Plan
reps × 5 conversion happens once per pass from the prescription/plan value
(never from a converted hint), so no repeated conversion.

### 3.9 Contract statements (tested)

Unchanged complete inputs/context ⇒ identical outputs regardless of repeated
passes, edit order, refresh or add-set passes. Earlier sets unchanged by later
edits. Actuals never become hints and hints never become actuals via Done,
save, refresh, recompute or completion (mutations are still created only from
entry/acceptance). Downstream values may legitimately change when accepting a
hint changes provenance (entered RIR authority) or precision (1.25 → 1.3);
there is no blanket "downstream never changes" rule.

### 3.10 Controller integration

`Wes2SessionController` gains `_hintContext` (service + generation) and
`_recompute(exerciseIds, fromSet)` that builds complete new rows and assigns
`_rows` once. Every mutator calls it **before** its single
`notifyListeners()`: `updateSetField` (from edited set), `removeSet` (from
removed index), `restoreSet/restoreExercise` (from restored index), `addSet`
(from new index), `replaceExercise`, `replaceWithTemplateRows`, `undo`,
`setRows`, `applyHintContext` (runner), `setPrescriptions`. `_onAddSet` no
longer calls `_loadAndApplyHints`.

### 3.11 BB3 day panel

`bb3_day_panel.dart:1096-1221` builds a temp row with Set 1 marked `bb3Hint`
and calls `computeRowHints`. `computeRowHints` keeps its signature and becomes
`resolveRow` over `Wes2HintInput` (generated Set 1 passed as the panel's
prescription for set 0, as today). Numeric changes come from the centre fix
only; a characterisation test records old vs new outputs for fixed fixtures
with the arithmetic reason, and a save test proves panel hints are never
written.

### 3.12 Consumed-versus-displayed agreement

`Wes2HintTrace` gains a test hook recording, per set, the predecessor values
the resolver consumed. Agreement is asserted at **three** levels (R9), in this
order, and a failure at any level fails the test:

1. **Numeric model equality:** the consumed weight/reps/RIR equal the previous
   final row's `actual ?? hint` **model doubles/ints exactly** (no tolerance,
   no rounding). This is what catches a mismatch smaller than display
   precision, which formatted text would hide.
2. **Provenance:** per field, whether the consumed value came from an actual or
   a hint equals the previous row's state, asserted separately from the number.
3. **Rendered text:** the previous row's displayed text, produced by the real
   widget formatters, equals the formatted consumed value.

Stored actuals are never rounded to display precision to make level 3 pass.
Editing behaviour is respected: while a field is focused, deliberately
unfinished text (`-`) and a valid trailing decimal (`22.`) stay in the
`TextField` while the model holds the last valid number, so raw text/caret and
model consumption are asserted **separately** during editing, and text is never
restored early to satisfy a display assertion.

## 4. Async hint orchestration (D9)

Extract `_loadAndApplyHints` into `Wes2HintLoadRunner`
(`lib/wes2_hint_load_runner.dart`) with injected `Wes2PlanService`,
defaults repository, types loader, history refresher and a
`Wes2HintGeneration` token `(loadEpoch, actingUid, date, blockId,
settingsGeneration, disposed)`; production control flow unchanged otherwise.

* `isCurrent()` checked **after every await** and **before** settings-cache
  write, `setExerciseSettings`, service registration and application.
* Settings refresh (settings sheet save) increments `settingsGeneration`
  **before** awaiting, so an older response can never replace newer
  settings/defaults/types.
* Final application is one synchronous controller call
  `applyHintContext(ctx)` that reads current rows/structure (edits made while
  loading included), recomputes all rows, assigns once, notifies once.
* Empty/no-block/disposed paths return before side effects; `dispose()`
  marks the runner disposed.
* Background history refresh completion re-enters the runner with a fresh
  token.

## 5. Text entry and parsing (D8)

`Wes2FieldParser.parse(fieldKey, text) → empty | valid(v) | invalid`:
weight/RIR/velocity `^-?(\d+\.?\d*|\.\d+)$`, reps `^\d+$`, finite only. RIR 0
valid. Existing numeric ranges otherwise unchanged (negative RIR remains
accepted as today — D-010). `1e3`/hex are now invalid (D-011).

Used by controller `updateSetField`, `Wes2SetRow` blur listeners, Done
barrier, exit coordinator, `_acceptHint` double-tap, `_onFieldUnfocused`,
mutation `fieldValueFrom` (rejects non-finite), pending overlay.

* While typing incomplete text: model keeps last valid actual (or none ⇒ hint
  shows); text and caret untouched.
* Blur / Done / exit with invalid text: controller restores text to the
  formatted last valid actual or empty, caret at end; no mutation; never zero;
  never auto-accepts a hint.
* Empty text is a clear (tombstone mutation), distinct from malformed.

## 6. Set structure

* Saved structure wins: `_mergeCompletedAndBb3Row` uses the completed row's
  count (already `max(stored setCount, stored sets length)`) when that row
  establishes structure (`setCount > 0` or non-empty `sets`); prescriptions
  beyond it are ignored. `_resolveEffectiveSetCount` no longer grows an
  existing row to `planCount`.
* Initial settings-based growth happens once, when a row is first created in
  a session without structural intent (plan-only BB3 row, `addExercise`,
  replace): the first hint pass for that row sets `max(setCount, planCount)`;
  if the row already exists in the workout document the count is persisted
  through the existing `setCount` mutation. Fresh plan-only reload (no saved
  row, no local structure intent) repeats plan defaults; established sessions
  never regain deleted planned sets.
* Local session-structure intent for rows without a saved row (e.g. BB3 row +
  added blank set) is kept in draft metadata (§7) and survives refresh and
  recovery.
* Prescriptions stay positional after deletion (matches reload). setIds,
  notes, done state and media stay attached to their sets.
* Untouched BB3-only rows never create execution documents.
* Hint passes never create or delete sets.

## 7. Offline hint context and prescriptions

Prescription authority: current server planned day → Firestore cache read
(`GetOptions(source: Source.cache)` after a failed/offline server read; also
`loadPlannedDay` stops bypassing its injected `_db`) → local stored
prescription metadata. Generated or schema-1 hints are display caches only.

Local draft payload `schemaVersion: 2` (Isar record JSON only; no Isar schema
change) adds `exerciseMeta[exerciseId]`:

```
structure:      { setCount, established }
prescriptions:  { source, blockId, dateKey, fetchedAtMs, exercisePlanNote,
                  sets: [ {weight, reps, rir, velocity, planNote} ] }
pureSet1:       { key: sha256(blockId|dateKey|exerciseSettings[exerciseId]|prescription0),
                  weight, reps, rir, e1rm }
```

Field JSON additionally carries `hintOrigin` (additive; schema-1 readers
default to `empty`, which never counts as a prescription). None of this is
written to Firestore execution values.

Modes:

1. **Settings + usable history:** normal; refresh `pureSet1`.
2. **Settings, history unavailable** (history store reports failed/absent
   hydration, not "no history"): Set 1 uses matching `pureSet1`, else the
   existing deterministic plan/default path; Set N follows current resolved
   predecessors.
3. **Settings unavailable:** no model results invented. Known display hints
   are kept only on the unchanged prefix; an entry/context change at set `k`
   clears derived hints for `k..end` (actuals and prescriptions kept). When
   authoritative inputs return, the runner recomputes everything.

First upgrade opened offline (no shadow yet): rows from the draft's actuals
(§9.8), prescriptions from Firestore cache or none, hints per mode 1–3.

---

## 8. Persistence protocol — concepts

| Concept | Definition |
|---|---|
| **Stream** | `installationId|actorUid`. `installationId` = UUID created once per outbox database; never reused. |
| **Stream era** | UUID in outbox `meta`, part of every checkpoint entry. Rotated when the client detects that its `nextSeq` is at or below the server's recorded applied seq for the same era — the signature of a restored/rolled-back outbox database (R3). Rotation is what stops new edits being mistaken for old applied ones. |
| **Mutation version** | immutable `(stream, era, seq)`; `seq` from a persistent monotonic counter in the outbox DB, never reset, never reassigned. The local primary key is `seq`. |
| **Attempt evidence** | `everAttempted`, set durably inside the claim transaction **before** the network call and never cleared. "Pending" alone never means "never sent" (R2). |
| **Bootstrap id** | UUID minted durably on an op with `frameEpoch == null` before its first attempt; the document epoch created by that op equals it, so a replay recognises its own creation (R3). |
| **Coalescing slot** | optional `slotKey` (e.g. field of a set) used only to *replace a pending, not-in-flight, last-in-scope* row's payload; replacement allocates a new `seq`. Slots are never receipts. |
| **Scope** | `(actorUid, athleteUid, dateKey)` = one workout document for one actor. Ordering unit. |
| **Target identity** | exercise: `exerciseId`. Set: `setId` when present; otherwise a **frame position** interpreted only through §9.3. Content is never identity. |
| **Frame** | what the athlete saw when authoring: confirmed shadow (rev, epoch) + all earlier own pending ops in scope. Recorded per op as `frameRev`, `frameEpoch`, `frameOps` (mids assumed applied), `preRowHash`. |
| **Replay evidence** | server checkpoint `wes2OpReceipts.applied[stream] = highest seq applied to this document`. Constant size per stream; survives pruning and content returning to an earlier state. |
| **Confirmed base** | local durable shadow = last authoritative document read or committed. |
| **Pending intent** | local ops not yet confirmed, in `seq` order. |
| **Conflict** | a op whose preconditions cannot be established safely. Kept, visible, blocks its scope until resolved. |
| **Media recovery record** | structural Undo record with held video ids (§12). |

## 9. Persistence protocol — behaviour

### 9.1 Operations (`Wes2Op` v2 payloads)

Every op payload: `v:2, stream, seq, kind, exerciseId, frameRev, frameEpoch,
frameOps[], preRowHash` plus kind-specific fields. Destructive ops carry the
**content they remove**.

| Kind | Target / fields | Apply semantics |
|---|---|---|
| `setField` | set target, `fieldKey`, `value` (finite or null = clear), `rowSeed` (create/promote only, actuals only) | patch one field |
| `setNote` | set target, `note?` | patch note |
| `exerciseNote` | exerciseId, `note?` | patch |
| `markDone` | exerciseId, `isDone`, `rowSeed` | patch flag only |
| `raiseSetCount` | exerciseId, `toCount`, `rowSeed` | `count = max(server, toCount)`; blank sets only (raise-only, as today) |
| `manualExercise` | row (no values) | add to `wesPlannedExercises` if absent |
| `setId` | set target, `setId` | additive; never overwrites an existing `id`/`setId` |
| `removeSet` | set target, `removed` = full set map (values, note, setId), `undoRecordId?` | validate removed content, remove, compact indices |
| `restoreSet` | exerciseId, `insertAt` (frame position), `snapshot`, `restoresSeq` | insert snapshot at resolved position |
| `deleteExercise` | exerciseId, `removedRow` (full row map incl. list membership, order, circuit, done, notes) | validate, remove |
| `restoreExercise` | `snapshot` row + membership | insert if absent; present ⇒ conflict |
| `replaceExercise`, `moveCircuit`, `deleteAllForDay`, `templateReplaceAll` | as v1 + `removed` content for the destructive ones | ordered + checkpointed; destructive ones validate removed content |

`rowSeed`/`snapshot` serialise actual values only (existing `_buildRowMap`
rule); hints/prescriptions never travel.

### 9.2 Two entry points over one shared target resolution (R7)

`lib/wes2_sync/wes2_doc_ops.dart` (no Firebase/Drift imports) exposes:

* `resolveTarget(doc, receipts, op)` — §9.3. Answers only "can this op's own
  target be identified safely in this document?".
* `resolveForCommit(doc, receipts, op, myStream)` → `applied(newDoc,
  newReceipts) | alreadyApplied(doc) | conflict(reason, doc)`. Full
  prerequisites; used by the Firestore transaction.
* `resolveForDisplay(base, op)` → `shown(newBase) | ambiguous(reason)`.
  Target resolution **and nothing else** — no checkpoint, no epoch, no
  dependency, no destructive precondition. Used by the render overlay so a
  blocked or conflicted earlier op never demotes a later, safely identified
  entry (§9.5a).

`resolveForCommit` steps:

1. Replay evidence: `applied[op.stream]` with **matching era** and
   `seq >= op.seq` ⇒ `alreadyApplied`. A different era is a different lineage
   and never counts as applied.
2. Era guard (R3): before the first write of a session to a document, if
   `applied[stream].era == myEra && applied[stream].seq >= meta.nextSeq`, the
   outbox database has been rolled back or restored. The client rotates its
   era (new UUID, `nextSeq` raised above the server value) and re-authors its
   queued ops under the new era **before** anything is written.
3. Epoch / bootstrap lifecycle (R3):
   * `op.frameEpoch != null`: `doc` missing, receipts missing, or
     `receipts.epoch != op.frameEpoch` ⇒ `conflict(documentReset)`.
   * `op.frameEpoch == null` and receipts present: if
     `receipts.epoch == op.bootstrapId` this is our own earlier creation
     (step 1 normally already returned `alreadyApplied`); otherwise another
     writer bootstrapped the document and normal resolution continues.
   * `op.frameEpoch == null` and **no receipts**: missing receipts are not
     proof that an earlier attempt never applied. If `op.everAttempted` and the
     op would **create** the document/row or is **destructive** ⇒
     `conflict(uncertainFirstWrite)` (visible recovery: "we could not confirm
     this first save and the day is now empty"). Otherwise (never attempted, or
     an idempotent-by-value op whose row still exists) it applies and
     bootstraps the epoch from `op.bootstrapId`.
4. Dependencies: `applied[stream].seq >= max(frameOps)` else
   `conflict(dependencyNotApplied)`. Necessary, not sufficient (a max
   checkpoint cannot prove every smaller seq applied); sufficiency comes from
   the local invariants in §9.4/§9.6 — FIFO per scope, and any op whose frame
   assumed a discarded or replaced op is re-authored, with references remapped,
   in the same local transaction.
5. Resolve the target (§9.3); unresolved ⇒ conflict.
6. Destructive validation: current content of what will be removed equals the
   op's `removed` content (all fields incl. note, setId, done, and for
   exercises order/circuit/membership/exercise note) ⇒ else
   `conflict(removedContentChanged)`.
7. Apply; update receipts including **break detection on every committing
   path** (§9.3, §10.2); return the new document.

The Firestore transaction runs `resolve` on the transactionally read document
and writes `newDoc` fields (`exercises`, `wesPlannedExercises`,
`wes2OpReceipts`, `userId`, `date`, `lastEditedAt`) with `merge: true`. The
outcome and the resulting document (read data with the written fields
substituted — exactly what was committed, `lastEditedAt` excepted) are
returned. The local overlay runs the same function against the shadow for
display. Equal functions on different bases can differ; the transaction
result is authoritative and replaces the shadow.

### 9.3 Set target resolution

**Order matters (R4): recorded history is consulted before any positional
shortcut, and whole-row equality never overrides it.**

```
1. setId present            -> index of set with readStableSetId == id, else conflict(targetMissing)
2. receipts == null         -> pre-bootstrap: no protocol history exists at all;
                               hash(serverRow) == op.preRowHash ? op.pos
                                                                : conflict(rowChangedUnidentifiable)
3. receipts present         -> history is authoritative:
     op.frameRev < floor                       -> conflict(historyUnavailable)
     breaks[ex] > op.frameRev                  -> conflict(historyBroken)
     rowHash[ex] != hash(serverRow)            -> conflict(unloggedWrite)
     row-replacing entry in window             -> conflict(rowReplaced)
     else                                      -> token rebase (below)
```

The old "equality first" branch is removed. In the reviewer's case — another
protocol client removes B and inserts a different id-less set that ends up
holding 60, so the row's content returns to its old shape and `preRowHash`
matches — step 3 rebases through the logged `removeSet`/`insertSet` pair, finds
the frame's token gone, and returns `conflict(targetRemoved)`. Equality is
therefore only an optimisation *inside* the rebase (a window with no structural
entries maps positions to themselves), never an authorisation. Step 2 exists
only where there is no history to consult at all; its residual limitation (an
unlogged A→B→A by an old build before the document is ever bootstrapped) is
stated in §16.

**Break detection on every committing path.** Before applying, each commit
snapshots the hash of **every** row (including the target row, and including
commits targeted by `setId`) and compares it with `receipts.rowHash`. Any
mismatch records `breaks[ex] = newRev` — stamped with the **new** revision, so
every op whose frame predates the foreign write is fenced while ops authored
afterwards are unaffected — and only then is `rowHash` refreshed. Without this,
an identified (`setId`) write would refresh `rowHash` and hide an earlier
unlogged structural change from a later id-less rebase. Rows that appear or
disappear with no log entry record a document-wide break.

Token rebase: start from anonymous tokens `T0..Tn-1` for the row at
`frameRev` (n from the first log entry's `countBefore`, or current count if no
structural entries). Replay logged structural effects in rev order
(`removeSet pos`, `restoreSet pos`, `raiseSetCount to`), labelling inserted
tokens by mid. Check final length == server row length, else conflict.
Frame list = tokens with only **own** entries of `seq < op.seq` applied (by
token identity). `target.pos` in frame list → token → index in server list;
token removed by a foreign entry ⇒ `conflict(targetRemoved)`. Field-only
entries do not move tokens. Row-replacing entries (`deleteExercise`,
`restoreExercise`, `replaceExercise`, `deleteAllForDay`,
`templateReplaceAll`) end the token history for that exercise: an id-less op
authored before one of them (by another stream) is a conflict.

Create/promote: a `setField` whose frame had no row for the exercise
(`preRowHash` = absent sentinel) creates the row from `rowSeed` only if the
exercise is still absent; if it now exists, normal resolution applies (id or
equality/log, else conflict).

**Limits on hashes (approved condition U-1, tightened by R4).** A hash is only
ever a *negative test*: "has this row changed since the frame / since the last
protocol commit?". It never locates a set, never matches a set by its content,
and never substitutes for `setId`. Resolution uses, in order: `setId`; logged
structural history; and — only where no history exists at all (step 2,
pre-bootstrap) — whole-row equality with the authoring frame, which authorises
**the frame's own position and nothing else**. A hash match never overrides
history and never triggers a search for a set whose content looks like the
target, so "a set whose old value was 60" is never an identity.

Two id-less sets in a row that is byte-identical to the authoring frame are
observationally identical: they carry no `setId`, no media (media requires a
`setId`), and the showcase reducers key them by position, so position *is*
their identity in that state. That is the only case where position is used
without identity or history.

**Missing or expired history falls back to a visible conflict** (approved
condition U-1): if the log does not cover `(frameRev, rev]`, or a
`breaks[ex]` marks a non-protocol write, or `rowHash[ex]` disagrees with the
current row, an id-less target is a conflict — never a best-effort guess.

For `restoreSet.insertAt`: same rebase for the insertion slot (the frame
neighbour tokens); if neither neighbour is resolvable ⇒ conflict.

### 9.4 Ordering and the engine

* Claim: for the signed-in `actorUid`, per scope, the **earliest** op by
  `seq` whose state is not `done`. If that head is `inFlight`, backed off,
  `blocked`, `malformed` or `conflict`, the whole scope waits; other scopes
  progress.
* Claim is a local transaction: `pending → inFlight`, `claimToken := uuid`,
  `everAttempted := true`, `bootstrapId` minted if absent, `rowVersion`
  checked; the claimed payload is copied inside that transaction and used for
  the remote attempt (edits during I/O cannot mutate it: in-flight rows are
  never coalesced). `everAttempted` is written **before** the network call and
  never cleared, so a later local decision can tell "never sent" from "sent,
  outcome unknown" (R2).
* Outcomes, each a single local transaction conditional on
  `(seq, claimToken, state == inFlight)`:
  * `applied` / `alreadyApplied` → write shadow (authoritative doc, rev,
    epoch, `commitCounter++`) **and** delete the op.
  * `conflict` → state `conflict`, `conflictJson` (reason + server data),
    write shadow from the returned doc.
  * transient → `pending` with backoff (scope stays blocked behind it).
  * permission/unauthenticated → `blocked`.
  * undecodable payload → `malformed` (raw JSON preserved).
* Startup: rows left `inFlight` by a dead process return to `pending` (their
  attempt may have committed; replay resolves to `alreadyApplied`).
* Post-confirmation side effects (qualifying day, set-video reconciliation)
  keep firing from the `confirmed` stream for `setField` weight/reps with a
  value, including `alreadyApplied` outcomes (both effects are idempotent).
* **Seq monotonicity per document** is an invariant the engine relies on for
  the checkpoint: any local action that inserts ops *ahead of* already-queued
  ops in a scope (legacy conversion §9.8, conflict replacement §9.6) must
  re-author those queued ops with new seqs after the inserted ones, in the
  same local transaction.
* Draining: after each outcome the loop claims the next head immediately;
  a submit during a pass sets `rerun` so the loop rescans before exiting. The
  30 s timer is only a fallback.
* Coalescing (R2, R6): a new `setField/setNote/exerciseNote/markDone` op
  replaces the slot's existing row **only if** that row is `pending`, is the
  last op in its scope, and has `everAttempted == false`. The replacement is
  authored **against the frame of the op it replaces** — `frameRev`,
  `frameEpoch`, `preRowHash`, `frameOps` and target are copied from the
  replaced op, never from the optimistic frame that contained it — so the
  replacement can never depend on a `seq` that coalescing just deleted. Delete
  and insert happen in one local transaction, which also remaps every
  reference to the replaced `seq` (other ops' `frameOps`, structural-undo
  `removalSeq`/`restoreSeq`). Otherwise a new row is appended. Nothing else is
  ever deleted or rewritten by enqueue (no supersession, no index rewriting).
  Without this, offline `50 → 55` produced a replacement carrying
  `frameOps: [1]` with no seq 1 left to satisfy it, and the server rejected it
  as `dependencyNotApplied` forever.

### 9.5 Shadow, loads and rendering

Shadow table keyed `(actorUid, athleteUid, dateKey)`: `exists`, `docJson`,
`rev`, `epoch`, `commitCounter`, `lastLoadGen`, `confirmedAtMs`.

* **Shadow writes are guarded in the repository layer, not the controller
  (R8).** Each load takes a monotonic `loadGen` for its scope at read start and
  records `commitCounter`. The check and the write are **one local
  transaction** that accepts the write only when all hold:
  `commitCounter` unchanged since the load started; `newRev >= shadow.rev`
  (protocol revisions are monotonic, so older server data is rejected outright);
  and, when `newRev == shadow.rev`, `loadGen > shadow.lastLoadGen`. Two reads
  that overlap with no confirmation between them therefore cannot leave the
  durable shadow stale: if L1 reads rev 4, L2 reads rev 5 and finishes first,
  L1's late response is rejected at the database, not merely ignored by the
  widget. Cached reads (`metadata.isFromCache`) never replace the shadow.
* Controller load epochs still discard stale loads.
* **Online render:** shadow (fresh) → parse rows → merge prescriptions → apply
  pending ops in `seq` order with **`resolveForDisplay`** (target resolution
  only); `shown` results become ordinary actuals; `ambiguous` ops are not
  applied (Not-saved marker + Needs attention) → unsaved recovery markers →
  hints.
* **Offline render:** same from the durable shadow.
* **No shadow and no network:** §9.8.

Pending intent is never replayed over the Isar draft.

### 9.5a What counts as an actual for the cascade (approved U-2)

| Value | Shown as | Drives hints |
|---|---|---|
| Confirmed server value | ordinary entry | yes |
| **Pending local entry, not yet synced (offline or in flight)** | ordinary entry | **yes, immediately** — the overlay applies it as an actual before any server round trip, and `_recompute` runs in the same synchronous mutation as today |
| Value restored from a recovery item onto a **safely identified** set | ordinary entry | **yes, immediately** on restore — it becomes an actual and an ordinary pending op at once; it never waits for server confirmation |
| Unresolved legacy/draft-only value (no safe target) | **separate** Not-saved recovery item (§13), never rendered as an ordinary entry | no |
| Entry whose upload is **paused** behind an earlier conflict, blocked or backed-off op, but whose own target is still safely identified | ordinary entry | **yes** — commit prerequisites never demote a displayable entry (R7) |
| Op whose **own** target is no longer safely identifiable (`ambiguous`) | Not-saved marker + recovery item | no, until resolved |

Only `resolveForDisplay` decides this table; `dependencyNotApplied`,
`documentReset`, checkpoint and destructive preconditions are commit-side
concerns. A positional target that genuinely became ambiguous *because* an
earlier op did not apply (for example an edit addressed relative to a removal
that never happened) is re-validated and moves visibly to recovery; an entry on
a surviving `setId` does not.

The rule this encodes: nothing is ever displayed as an ordinary entered value
while the cascade calculates from something else. Either a value is an actual
— displayed normally *and* driving hints — or it is an explicitly unresolved
recovery item, displayed separately and driving nothing. A pending sync state
never downgrades an entry: only loss of a safe target does, and that is
visible the moment it happens.

Consequence to state plainly: when an op flips from pending to `conflict`, the
value stops driving hints and moves to the sheet, and the hints for that set
and the sets after it are recomputed without it. That transition is visible
(marker + sheet), never silent.

### 9.6 Conflicts

Conflicts never silently drop intent, never retarget to another set, never
show as saved. Actions (sheet, §13): apply to a chosen current set, add as a
new set (field/note/restore), discard this change, discard pending changes for
this exercise. Each action is a local transaction that deletes or replaces the
conflicted op, **re-authors dependent later ops** in the scope (new frames and
new `seq`s after the replacement) and **remaps every reference** to the old
`seq` — other ops' `frameOps`, structural-undo `removalSeq`/`restoreSeq` — so
no dangling or falsely satisfied reference survives. An op whose target token
only existed through a discarded op becomes a conflict itself.

**Discarding an op with attempt evidence (R2).** "Discard" may not simply
delete a row whose `everAttempted` is true: the commit may already have landed.
Such a row is first allowed to reconcile (applied / alreadyApplied / conflict);
only then, if it did apply, is a compensating op enqueued (a field returns to
the confirmed value from its frame; a removal is followed by `restoreSet`).
The sheet wording for these items is "Undo this change" rather than "Discard",
because that is what it does. Retry/reload alone does not clear a precondition
conflict. Transient/blocked states keep the existing "tap to retry".

### 9.7 Retention and compatibility

* Server checkpoint entries are never pruned by count/age; one `{era, seq}`
  pair per stream per document. An era rotation adds at most one further entry
  per document for that installation (rotation happens only on a restored or
  rolled-back outbox database).
* Log (P-META): last 64 entries per document; `floor` advances; pruning only
  turns some id-less rebases into conflicts, never into replays.
* Local: ops deleted on confirmation; conflicts/malformed/unsaved kept until
  resolved; shadows for scopes without pending/unresolved items pruned beyond
  the 60 most recent days.
* Old app builds write workout docs with `merge: true` on
  `exercises/wesPlannedExercises/lastEditedAt` only (audited:
  `WES2_repository.dart`, `bb3_planned_exercise_service.dart:305`), so
  `wes2OpReceipts` survives them; their writes are detected as non-protocol
  (`rowHash` mismatch).
* `WorkoutSummaryScreen.dart:117-124` non-merge `set` matches docs by full ISO
  `date` query, which WES2 `yyyy-MM-dd` docs do not satisfy (to be
  re-verified with a rules/emulator-free unit check). `week_planner.dart:1134`
  deletes whole workout docs and account deletion removes them: handled as
  document reset (epoch).
* Function triggers on `users/{uid}/workouts/{id}` (`functions/coach/index.js:364`,
  `functions/showcase/firestore_store.js:323`) read `exercises`; the new map is
  ignored. `lastEditedAt` already changes on every write, so trigger frequency
  is unchanged. Verified by `npm run test:emulator` showcase specs.

### 9.8 v1 migration and legacy recovery

**Step 0 (before touching outbox code):** a generator test run against the
unmodified v1 outbox/engine writes real SQLite fixtures + companion JSON
(server doc, draft rows, intended final state) to
`test/fixtures/wes2_outbox_v1/`: reindexed field edits, multiple removals
incl. same-index collapse, removal index rewritten by a later lower removal,
coalescing moved to back, applied-but-unacknowledged ops, `localSeq`
collisions, notes/done/setCount/setId, blocked/backoff rows.

**Drift outbox schema 1 → 2** (`onUpgrade`): create new tables; keep
`wes2_mutations` rows untouched as legacy evidence; initialise `nextSeq =
max(seq)+1`, create `installationId`. No SQL rewriting of v1 rows.

**Legacy reconciliation** per legacy scope, online only, before any v2 op in
that scope is claimed (v2 ops authored meanwhile queue behind it):

1. Read the server document `D`.
2. Reconstruct legacy intent: undo v1 index rewriting by walking surviving
   removals in **descending seq**; for each removal at stored index `r`, rows
   with `seq < removal.seq` and index `≥ r` are incremented. Validated
   assumptions: v1 rewrote only rows with index `> r` (decrement) and deleted
   rows with index `== r`; coalescing kept the rewritten id but moved `seq` to
   the back, so a coalesced row's index refers to the post-removal layout,
   consistent with its new seq. Evidence of rows deleted by supersession is
   gone and **cannot** be reconstructed.
3. Simulate corrected intent over `D` with v1 repository semantics (count
   guard, idempotent fields) → `R*`.
4. **Authorise per operation from PRE-state evidence, never from the result
   (R5).** Walk the reconstructed sequence in order against the live document.
   An operation may be auto-converted only when, at its turn, either
   * its target set still carries the `setId` it was authored against, or
   * the whole exercise row equals that operation's reconstructed **pre-state**
     row (content equality *before* the operation is applied).

   The first operation that satisfies neither stops auto-conversion for that
   exercise; it and everything after it become **Needs attention** items
   listing server values, draft values and each legacy intent with its original
   position. Earlier operations that were authorised keep converting.

   This replaces the v6 rule "`R*` equals the draft ⇒ convert". That test can
   be satisfied by a write to the wrong set: with all sets id-less, original
   `[50,60,70]`, legacy intent B→80, draft `[50,80,70]`, and a server that
   removed B and inserted D=65 at the same position (`[50,65,70]`), applying
   the positional edit yields exactly `[50,80,70]` — matching the draft while
   overwriting D. Post-state agreement is therefore corroboration only and is
   never the authorisation. A count guard that now no-ops is likewise not
   evidence that a removal was acknowledged; that operation's outcome is
   **unknown** and it becomes a recovery item.

   Authorised conversions are written as v2 ops authored against `D` (frame =
   D) in one local transaction that also deletes those legacy rows and
   re-authors any v2 ops already queued in that scope after them (new seqs,
   frames = D + converted ops, references remapped per §9.6).
5. Draft-only actuals that `D` lacks and no pending/legacy intent covers
   become `Wes2UnsavedEntries` (always, not only at upgrade).

Offline first upgrade with no shadow: display the draft's execution values as
the base and mark legacy intent "awaiting server comparison"; do **not**
overlay legacy ops (the draft already reflects them). New v2 edits in this
state record `frameEpoch null, frameRev 0, preRowHash` of the draft row;
they queue behind the legacy scope and resolve normally (id or
whole-row-equality, else conflict). Original draft and legacy rows are kept
until every derived item is resolved; restart preserves them.

## 10. Schema changes

### 10.1 Local (client-only)

Outbox DB `goodlift_wes2_outbox.sqlite` schema 2:

| Table | Columns (key) |
|---|---|
| `wes2_meta` | `key` PK, `value` — `installationId`, `streamEra`, `nextSeq`, `sessionId` (new UUID each process start) |
| `wes2_ops` | `seq` PK, `stream`, `era`, `slotKey?`, `actorUid`, `athleteUid`, `dateKey`, `kind`, `exerciseId`, `payloadJson`, `state` (`pending/inFlight/blocked/malformed/conflict`), `claimToken?`, `rowVersion`, `everAttempted`, `bootstrapId?`, `attemptCount`, `nextAttemptAtMs`, `lastError?`, `conflictJson?`, `undoRecordId?`, `createdAtMs`, `updatedAtMs`; index `(actorUid, athleteUid, dateKey, seq)` |
| `wes2_shadows` | PK `(actorUid, athleteUid, dateKey)`, `exists`, `docJson`, `rev`, `epoch?`, `commitCounter`, `lastLoadGen`, `confirmedAtMs` |
| `wes2_unsaved_entries` | `id` PK, `actorUid`, `athleteUid`, `dateKey`, `exerciseId`, `position`, `setId?`, `sourceSignature`, `fieldKey`, `valueJson`, `origin` (`legacyDraft`/`legacyQueue`/`draftOnly`), `createdAtMs` |
| `wes2_mutations` | unchanged v1 table, now legacy evidence + `resolvedAtMs?` column |
| `wes2_structural_undo` | `id` PK, `actorUid`, `ownerUid`, `dateKey`, `exerciseId`, `kind` (`removeSet/deleteExercise`), `state` (`preparing/live/restoring/discarding`), `sessionId` (owning process session), `publishedAtMs?` (controller publication completed), `snapshotJson`, `videoRecordIdsJson`, `removalSeq?`, `restoreSeq?`, `createdAtMs`, `updatedAtMs` |

Set-video DB `goodlift_set_videos.sqlite` schema 2: new `set_video_holds`
(`recordId`, `undoRecordId`, `priorDeletedAtMs?`, `priorSuppressed`,
`createdAtMs`, PK `(recordId, undoRecordId)`). `finalizable()` adds
`NOT EXISTS hold`. Existing columns unchanged. Holds are inserted in the same
video-DB transaction as the soft delete and record the record's prior state,
so rollback and Undo restore exactly that state (a previously detached,
suppressed clip is not un-suppressed — D-014).

Isar: no schema change; draft payload `schemaVersion 2` (§7).

Downgrade (older build over schema 2) is not supported by Drift; Play
versionCode ordering prevents it in normal distribution. Stated as a
limitation.

### 10.2 Server: `users/{uid}/workouts/{yyyy-MM-dd}.wes2OpReceipts`

**Within the approved G1 scope (replay evidence):**

```
wes2OpReceipts: {
  v: 1,
  epoch: "<bootstrapId of the operation that created this map>",
  applied: { "<installationId>|<actorUid>": { era: "<uuid>", seq: <int> } }
}
```

`epoch` equals the creating operation's durable `bootstrapId`, so a replay of
that same operation recognises its own document lineage instead of treating a
recreated document as its own. `applied` is keyed by stream and carries the
stream **era**, so a restored outbox database cannot have its new operations
mistaken for old applied ones (§9.2 step 2).

**Additional metadata P-META — approved in principle (2026-09-16), same map,
subject to the three conditions below:**

```
  rev:     <int>                          // +1 per protocol commit
  rowHash: { "<exerciseId>": "<sha256>" } // row content after last protocol commit
  log:     [ { rev, stream, seq, ex, kind, pos?, countBefore?, to?, rowHashAfter } ]  // ≤ 64
  floor:   <int>                          // lowest rev whose successors are all in log
  breaks:  { "<exerciseId>": <rev> }      // latest rev at which a non-protocol write was detected
```

Conditions (all enforced in §9.3 and tested in §15):

1. P-META may only *permit* a concurrent edit when identity and recorded
   history establish compatibility. Missing, pruned or broken history ⇒
   visible conflict.
2. Hashes never substitute for set identity; they are negative tests only.
3. Pruning `log`/`floor` never touches `applied`, so durable replay protection
   is independent of log retention (`S-REPLAY-LOG-PRUNED`,
   `S-REPLAY-RETURN-TO-PRE`).

Why P-META: without it, an id-less target can only be applied when the whole
row still equals the authoring frame. Example: athlete (phone) and coach
(tablet, new build) both online; coach edits Set 1 note while athlete edits
Set 3 weight on an id-less row. Without P-META the athlete's edit becomes a
conflict every time; with it, the log shows a field-only foreign entry and the
edit applies to Set 3. Safety is identical either way.

Rules: `firestore.rules` has no field allowlist on workout documents
(athlete and allow-listed coach may write). No rules change planned. New
rules specs prove athlete/coach can write and read the map, others cannot.

Hash: SHA-256 (`crypto` already a dependency) of canonical JSON (sorted keys,
numbers normalised to shortest double text).

## 11. Why each rejected counterexample cannot occur

| Counterexample | Mechanism that prevents it |
|---|---|
| U5 `[50,60,70]` delete 60 ack'd, offline Undo, edit → `[50,80,80,70]` | render = shadow `[50,70]` + restore(seq s) + edit(seq s+1); never draft + pending. Server: restore then edit → `[50,80,70]`; lost ack ⇒ `applied ≥ s` ⇒ alreadyApplied |
| identical id-less sets collapsed by value dedupe | no value dedupe anywhere; positions via frame/log |
| offline delete B then C at same compacted index drops B | two immutable seqs, no supersession; sequential frames |
| backoff lets rebased edit overtake removal | scope head blocks all later ops |
| old in-flight ack deletes newer coalesced value | in-flight rows never coalesced; ack deletes by `(seq, claimToken)` |
| restore before video records restored ⇒ footage purged after crash | holds created before removal is durable; restore op enqueued before `undoDelete`; holds block finalisation until the record completes (§12) |
| global maintenance, not only snackbar | every finaliser path takes the structural/media lock and excludes held records |
| only-set / deleteExercise Undo | same record/op flow with `deleteExercise` + `restoreExercise` |
| receipts pruned by 30 days/100 entries ⇒ duplicate restore | checkpoint per stream is never pruned |
| count-only conflict checks | whole-row hash, destructive content validation, log tokens |
| removeSet by id, later field patches by old index | field ops carry setId when present, else frame + rebase |
| applying mutation to old shadow ≠ server result | shadow is replaced by the transaction's committed document |
| replaying reindexed v1 rows unchanged | legacy reconciliation reverses indexing, compares with draft, else Needs attention |
| shadow creation discards draft-only values | draft-only actuals become unsaved entries before any shadow-based render hides them |
| maintenance mistakes gap between writes for a crash | recovery runs only while holding the same lock a live structural op holds for its whole sequence |
| content is not identity (B→80 lands on C) | no content retargeting; old-build write ⇒ rowHash mismatch ⇒ id-less conflict; new-build write ⇒ log shows field-only ⇒ stays on position 1 (B) |
| missing content proves removal | removal known only from setId absence or a logged `removeSet` token |
| return-to-pre re-applies restore after foreign delete | `applied[stream] ≥ seq` ⇒ alreadyApplied, independent of content |
| per-device FIFO vs other device cycle | checkpoint is per stream on the server document, not per device queue |
| id-only signatures ignore execution changes | destructive ops validate full removed content incl. values/notes/done |
| preparing record stranded after same-process exception | recovery under the lock treats any `preparing/restoring` record not registered as active as orphaned, including this process |
| failed live-process operations | op sequence `try/finally` deregisters then triggers recovery |
| **R1** maintenance releases a hold while app-bar Undo is still offered | opportunity lifetime is durable (`sessionId`), separate from "currently executing"; a `live` record of the current session is preserved by recovery and discarded only on the listed lifecycle events or when its session is gone |
| **R1** exception after the durable transition, before the screen is updated | `publishedAtMs` is written only after controller publication; recovery republishes from durable state instead of leaving a changed database behind an unchanged screen, and holds/media association survive |
| **R2** pending-with-backoff treated as "never committed" | cancellation requires `everAttempted == false`, tested atomically against claiming; an attempted removal keeps its identity, reconciles, and Undo becomes a durable `restoreSet`/`restoreExercise` |
| **R3** lost first-write acknowledgement then a planner reset recreates the day | `frameEpoch == null` + `everAttempted` + creating/destructive + no receipts ⇒ `conflict(uncertainFirstWrite)`; missing receipts are never proof of non-application |
| **R3** restored outbox reuses stream id with a lower `nextSeq` | checkpoints carry the stream **era**; a rollback is detected at first contact and the era rotates before any write |
| **R4** identical row content bypasses known replacement history | history is consulted first; equality is only an optimisation inside the rebase and never an authorisation |
| **R4** identified write hides an earlier unlogged structural change | every committing path snapshots all rows before mutating and records `breaks[ex] = newRev` before refreshing `rowHash` |
| **R5** migration approves a write because the result matches the draft | auto-conversion needs pre-state identity/equality; post-state agreement is corroboration only; unknown outcomes become recovery items |
| **R6** coalesced revision depends on the `seq` coalescing deleted | the replacement is authored against the replaced op's frame, with references remapped in the same transaction |
| **R7** a blocked earlier upload removes a safely identified entry from the cascade | display uses `resolveForDisplay` (target only); commit prerequisites never demote a displayable entry |
| **R8** two overlapping loads leave the durable shadow stale | shadow writes are guarded by `rev` then `loadGen` with `commitCounter`, checked and written in one local transaction |

## 12. Structural Undo and media recovery

### 12.1 Lock

`Wes2StructuralMediaLock` — one process-wide non-reentrant async mutex
(`lib/wes2_sync/wes2_structural_media_lock.dart`). Taken by: WES2 remove set,
delete exercise, Undo, discard; `SetVideoService.runMaintenance` around
recovery + `finalizeExpiredDeletions`; `SetVideoCoordinator.finalizeDeletion`
around its finalise; startup/resume maintenance via `ProfileServices`. Methods
called while holding it are lock-free internal variants (no nesting ⇒ no
deadlock).

**Two different questions, two different mechanisms (R1).** The mutex and the
in-memory `activeRecordIds` set answer only *"is an operation executing right
now?"*. They say nothing about *"is an Undo opportunity still available?"*,
which outlives the operation and must survive ordinary maintenance. That
second question is answered durably by the record's `sessionId` (a UUID minted
in `wes2_meta` at each process start) plus the explicit lifecycle events in
§12.4. Holding the mutex never protects a completed operation's Undo lifetime;
the record's session ownership does.

### 12.2 Removal (set or exercise, incl. only set)

Under the lock:
1. Read candidate video ids for the removed set(s)/exercise (by setId / exerciseId).
2. Outbox tx: insert `wes2_structural_undo` `preparing` with snapshot + video ids + `sessionId`; register active.
3. Video tx: insert holds (with prior state) + `softDelete` for those ids.
4. Outbox tx: insert `removeSet`/`deleteExercise` op (+`undoRecordId`) and set record `live` with `removalSeq`.
5. Controller removes and recalculates; Undo entry `{recordId}` pushed; snackbar shown.
6. Outbox tx: set `publishedAtMs`.
`finally`: deregister from `activeRecordIds`; on exception (including one
between 4 and 6) run recovery immediately — the durable state is authoritative
and the screen is rebuilt from it (§12.5), never left showing a set the
database has already removed. The record stays `live` and keeps its holds, so
the Undo opportunity and the media association survive a failed publication.

### 12.3 Undo (snackbar or app bar)

Under the lock:
1. Outbox tx: the removal op may be **cancelled in place of a restore only
   when durable evidence proves it was never attempted** — `everAttempted ==
   false`, state `pending`, last in scope — and that test and the deletion
   happen in the same transaction that a claim would use, so no claim can
   interleave (R2). In every other case, including `pending` after a
   backoff (where a commit may have succeeded and only its response was lost),
   the removal keeps its identity and reconciles, and a durable
   `restoreSet`/`restoreExercise` op (frame = current) is enqueued after it.
   Record → `restoring`, `restoreSeq`.
2. Video tx: `undoDelete` exact held ids; delete holds for the record.
3. Outbox tx: delete record.
4. Controller inserts the snapshot into **current** rows (neighbour and other
   exercise edits kept), recalculates.

If the server later rejects the restore (`conflict`, e.g. the exercise was
deleted on another device) the restored set shows *Not saved*; choosing
**Discard change** re-soft-deletes its clips without a hold so ordinary
maintenance finalises them — footage is never left attached to a set that no
longer exists anywhere.

### 12.4 Discard (opportunity expired)

The **only** discard triggers are: date change, athlete change, screen
dispose, undo-stack eviction/overflow, an explicit user discard, and recovery
finding a `live` record whose `sessionId` is not the current session (an
opportunity left unused by a previous process). Record → `discarding`; holds
removed (restoring each record's prior `deletedAt`/`suppressed`); record
deleted. Soft-deleted rows are then finalised by ordinary maintenance.

Ordinary maintenance in the current session **never** discards a `live`
record: a completed removal whose snackbar has closed still offers app-bar
Undo, and its footage stays held. A successful reload does not discard either —
structural Undo restores into current state, so it stays valid while the
screen lives.

### 12.5 Recovery (under the lock, before destructive maintenance)

| Record state (not in `activeRecordIds`) | Action |
|---|---|
| `preparing` (any session) | roll back: for ids **with a hold row for this record**, restore `priorDeletedAtMs/priorSuppressed` and delete the hold; ids without a hold are untouched; delete record. The removal was never durable (op insert and `live` are one transaction) |
| `live`, `sessionId == current`, `publishedAtMs == null` | **republish from durable state**: rebuild the affected rows from shadow + pending ops, restore the Undo entry for this record, then set `publishedAtMs`. Holds untouched |
| `live`, `sessionId == current`, published | **leave alone** — the Undo opportunity is still offered; holds stay |
| `live`, `sessionId != current` | unused opportunity from a dead process ⇒ discard (§12.4) |
| `restoring` (any session) | finish steps 2–3 (the restore op is already durable); footage preserved until complete |
| `discarding` | finish |

Owner isolation: recovery acts on records whose `actorUid` is the signed-in
account; it only releases holds/undoes deletes, never purges another owner's
files. Tests verify file bytes, not just rows.

### 12.6 Undo stack

`_undoStack` entries become typed: `structural(recordId)` (durable, restores
into current state) or `snapshot(rows)` (existing G2 behaviour for add set /
replace / move / template / delete-all). `_pendingVideoUndoIds` is removed.

## 13. UI

* Status line (`_buildSyncStatusLine`) gains **Needs attention (n)** (conflict,
  malformed, unsaved, legacy ambiguity) → bottom sheet `Wes2RecoverySheet`.
* Row markers: set/exercise with an unresolved item shows a small
  **Not saved** chip; conflicted and unresolved values are never rendered as
  ordinary entries (§9.5a). The chip is the only place their numbers appear in
  the row; the sheet carries the values themselves.
* Restoring a recovery item onto a chosen, safely identified set makes it an
  ordinary entry immediately: the value appears as an actual, the cascade
  recomputes from that set forward in the same frame, and the durable op is
  queued in the same action. Nothing about it waits for the server.
* Sheet item (grouped by exercise):
  * Your change — e.g. "Set 2 weight → 80 kg (this device, 14:02)".
  * Saved now — current server values for that exercise.
  * Reason — plain language ("This set changed on another device").
  * Actions: **Apply to set…** (pick current set), **Add as new set**,
    **Discard change**, **Discard pending changes for this exercise**
    (confirm). Unsaved values: **Save** (validated op on chosen set) /
    **Discard**. Legacy ambiguity: per original position **Place at set…** /
    **Add as new set** / **Discard**. Malformed: details + **Discard**.
* After an action the sheet refreshes from shadow + revalidated pending ops.
* Undo snackbar unchanged in wording; app-bar Undo remains.

## 14. Files, dependencies, sequence

### 14.1 Files

| File | Change |
|---|---|
| `lib/WES2_models.dart` | `hintOrigin` in JSON; `rirReferenceHint`; `Wes2Prescriptions` |
| `lib/wes2_hint_input.dart` (new) | input builder |
| `lib/wes2_cascade_resolver.dart` (new) | pass loop, view memo, matching |
| `lib/WES2_hint_service.dart` | per-set API, centre, pure Set 1 fallback, timed Set N, no growth of established rows |
| `lib/wes2_setn_solver.dart` | `Wes2SetNCentre` helper only |
| `lib/WES2_controller.dart` | remove baseline machinery; `_recompute`; prescriptions; structural Undo entries; restore APIs; parser |
| `lib/wes2_field_parser.dart` (new) | parsing |
| `lib/wes2_hint_load_runner.dart` (new) | async runner |
| `lib/WES2_screen.dart` | runner wiring, load via shadow, structure merge, remove/delete/undo flows, recovery sheet entry, parsing |
| `lib/WES2_widgets/WES2_set_row.dart`, `WES2_exercise_card.dart` | blur restore, parser, RIR cue source, Not-saved chip |
| `lib/WES2_widgets/wes2_recovery_sheet.dart` (new) | sheet |
| `lib/WES2_plan_service.dart` | use `_db`; cache fallback |
| `lib/WES2_local_store.dart` | draft schema 2 metadata |
| `lib/WES2_repository.dart` | `applyOp` transaction returning outcome + doc; `saveSetId`/`savedPerformanceForSet` use `_db`; loadDay exposes `fromCache` + receipts |
| `lib/wes2_sync/wes2_mutation.dart` | v2 op constructors; finite values |
| `lib/wes2_sync/wes2_doc_ops.dart` (new) | pure resolver, hashing, receipts |
| `lib/wes2_sync/wes2_mutation_outbox.dart` (+ `.g.dart` via build_runner) | schema 2, tables, claim/ack/coalesce |
| `lib/wes2_sync/wes2_legacy_reconciler.dart` (new) | §9.8 |
| `lib/wes2_sync/wes2_pending_overlay.dart` | rewrite over resolver + shadow; draft fill → unsaved entries |
| `lib/wes2_sync/wes2_sync_engine.dart` | FIFO per scope, outcomes, draining |
| `lib/wes2_sync/wes2_sync_services.dart` | wiring, recovery at start |
| `lib/wes2_sync/wes2_structural_media_lock.dart`, `wes2_structural_undo.dart` (new) | §12 |
| `lib/wes2_video/set_video_store.dart` (+ `.g.dart`) | holds table, schema 2, `finalizable` |
| `lib/wes2_video/set_video_service.dart`, `set_video_coordinator.dart`, `set_video_pipeline.dart` | lock, recovery-before-finalise, locked variants |
| `lib/profile/profile_services.dart` | maintenance path via lock (no behaviour change otherwise) |
| `lib/bb3_day_panel.dart` | adapt to resolver input (no UI change) |
| `lib/bb3_hint_service.dart`, `lib/bb3_planned_exercise_service.dart`, `lib/periodization_model_utils.dart`, progression engine | **no change planned** |
| `functions/test-rules/wes2_receipts_rules.spec.js` (new) + `package.json` script list | rules specs |
| `test/wes2_screen_cascade_e2e_test.dart` (new) | real-screen/runner final verification (§15) |

### 14.2 Sequence

* **A0** Harness + reproductions through production paths: runner race (D9),
  timed widget (D10), screen-level edit/remove/undo; v1 fixture generator
  (Step 0 of §9.8). Commit fixtures before any outbox change. The isolated
  protocol prototype (`docs/wes2-cascade/prototype/`) is extended alongside
  B1–C1 as a cheap specification check; it is **never** counted as a
  production gate and never ships in `lib/` or `test/`.
* **A1** Parser + text entry (small, independent).
* **A2** Service per-set API + centre + Set 1 fallback + timed; unit fixtures.
* **A3** Resolver + view + builder; **I1/ambiguity exhaustive gate across all
  supported Set 1 progression models** — a violation is recorded as a concrete
  counterexample and resolved per §3.4 (never by weakening accepted-hint
  behaviour, narrowing the model set, or touching the formula).
* **A4** Controller recompute, prescriptions, structure rules, RIR cue,
  display-agreement widget test, BB3 panel characterisation.
* **A5** Runner extraction + offline hint modes + draft schema 2.
* **B1** `wes2_doc_ops` pure resolver + hashing + receipts (exhaustive unit
  tests incl. every §11 case at document level).
* **B2** Outbox schema 2 + migration + claim/ack/coalesce; engine FIFO.
* **B3** Repository `applyOp`, shadow, load/render pipeline, overlay rewrite.
* **B4** Legacy reconciler + unsaved entries against v1 fixtures.
* **B5** Conflict/recovery sheet + revalidation.
* **C1** Lock, holds, structural undo records, recovery, coordinator/maintenance.
* **C2** Screen flows for remove/delete/undo on top of B and C1.
* **D** Existing-test updates with written reasons, focused suites, analyze
  (compare with baseline), full `flutter test`, `npm run test:rules`,
  showcase emulator specs, integration + release (§17).

Handoff docs are updated at the end of each step.

## 15. Requirement → test mapping

All tests use production classes; stubs only at I/O seams (Firestore via
`FakeFirebaseFirestore`, Drift in-memory or on-disk temp files, file system
temp dirs, injected clocks/Completers/hooks). `R` = reproduces a current
failure before the fix; `P` = preservation.

**Final verification runs through the real screen.** `PROBES.md` evidence and
the controller-level suites below are necessary but not sufficient: the
release gate includes `test/wes2_screen_cascade_e2e_test.dart`, which pumps
the actual `Wes2Screen` with its real `Wes2HintLoadRunner`, repository, plan
service, outbox and widgets (only Firestore/Drift/file-system seams faked),
and asserts for every set that the values the resolver consumed equal the
**previous row's final displayed actual/hint combination** as rendered:

| Test | Requirement |
|---|---|
| E2E-CONSUME-DISPLAYED-{load, edit, clear, accept, addSet, removeSet, undo, reload, settingsRefresh} | after each real interaction, every set's consumed predecessor == previous row's displayed text per field, with actual/hint provenance matching |
| E2E-ORDER-INDEPENDENCE | the same interactions in different orders end on identical rendered rows |
| E2E-PENDING-DRIVES-HINTS | an entry made with the server unreachable drives hints immediately (§9.5a) |
| E2E-CONFLICT-LEAVES-CASCADE | an op turning into a conflict removes its value from the cascade and shows the marker in the same frame |
| E2E-RESTORE-DRIVES-HINTS | restoring a recovery item onto a chosen set makes it an actual and recomputes immediately, before any sync |
| E2E-BLOCKED-EARLIER-LATER-DRIVES (R7) | a conflict on one set/exercise, then valid entries elsewhere: through offline → reload → reconnect the safely identified entries stay visible and feed the cascade while syncing is paused; only genuinely ambiguous targets move to recovery |
| E2E-PREDECESSOR-NUMERIC-EQUALITY (R9) | consumed values equal the previous final row's model numbers exactly, provenance asserted separately, rendered text checked with the real formatters |
| E2E-EDITING-TEXT-VS-MODEL (R9) | `-` and `22.` remain in the focused field while the model supplies the last valid number; caret preserved; no premature restore; no rounding of stored actuals |

### Hints — `test/wes2_cascade_contract_test.dart` (controller + real service)
| Test | Requirement |
|---|---|
| H-MASK-S1-{HHH…AAA} (8) | all masks at Set 1, S2 observes (R for AHH/HAH-with-baseline-equal) |
| H-MASK-MID-{HHH…AAA} (8) | intermediate set, next set observes |
| H-ORDER-all-permutations | every entry order of each mask ends identical |
| H-OLD-BASELINE-EQUAL (R: P2) | actual equal to old baseline after predecessor edit is consumed |
| H-RIR-AUTHORITY-EQUAL (R: P3) | entered RIR 3 equal to hint keeps authority |
| H-SIBLING-{w,r,rir} | each edit changes relevant siblings and S+1 consumes them |
| H-CHAIN-LATER-ACTUALS | partial/complete later actuals preserved; earlier sets identical objects |
| H-CLEAR-ONE / H-CLEAR-ALL (R: P4) | clears return current-context hints |
| H-EDIT-REVERT / H-RETYPE-EQUAL | revert and equal retype give identical rows |
| H-REPEAT-PASSES (R: P5) | 10 passes, interleaved addSet, no drift |
| H-FRESH-CONTROLLER | same complete inputs on a fresh controller ⇒ identical |
| H-NO-HINT-TO-ACTUAL | Done/save/refresh/recompute never create actuals |
### `test/wes2_accepted_hint_view_test.dart`
| H-VIEW-40x10-{weightFirst,repsFirst} (R: R-HINT-5) | RIR stays 2, S3 35×13@2 |
| H-VIEW-ROUNDING-1.25 | accepts "1.3"; downstream consumes 1.3 |
| H-VIEW-FORMAT-BOUNDARY | 0.15/"0.1", 2.55/"2.5", 16.2505/"16.25" |
| H-VIEW-RIR-2.5-vs-3.0 / H-VIEW-HINTED-3.0 | cap permission only from entered RIR > 2.5 |
| H-VIEW-BB3-LOCKS | reps/weight/RIR lock acceptance keeps cues |
| H-VIEW-SIBLINGS-STABLE | accepting keeps remaining hints/cues |
| H-VIEW-I1-EXHAUSTIVE-{model} | I1 across all progression models × fixtures |
| H-VIEW-AMBIGUOUS-AGREE-{model} | every ambiguous state agrees on remaining hints/cues |
### `test/wes2_setn_centre_test.dart`
| H-CENTRE-LITERAL-{56.8,41.3529,50.6286} (R: R-HINT-1..3) | literal targets + bounded results |
| H-CENTRE-STALE-OWN-30 (R: R-HINT-4) | no effect |
| H-CENTRE-SOURCES | constraint/inverse/clamp/fallback tags; NaN/Inf/≤0 inputs |
| H-CENTRE-BOUNDED-LIMIT | target 31 example keeps bounded result |
| H-CENTRE-NO-CANDIDATES / NEG-ASSISTED | no fabricated hints; existing grid limitation characterised |
| H-CENTRE-BW | display-added candidates, absolute scoring |
### `test/wes2_set1_postprocess_test.dart`
| H-S1-PURE-FALLBACK | no-history late RIR solve uses pure Set 1 context, stable across passes |
| H-S1-RIR-CUE | `rirReferenceHint` from free-context view |
### `test/wes2_timed_cascade_test.dart`
| H-TIMED-{weighted,unweighted,bodyweight} (R: D10) | actual-or-hint seconds/weight propagate; no repeated ×5 |
### `test/wes2_field_entry_widget_test.dart` (real `Wes2SetRow` + controller)
| H-TEXT-RAPID 2→22→22.→22.5 | model 2,22,22,22.5; caret/text kept |
| H-TEXT-UNFINISHED "."/"-" (R: P8) | last valid kept; blur restores |
| H-TEXT-NONFINITE (R: R-PARSE) | NaN/Infinity/1e3/0x10 invalid |
| H-TEXT-ZERO-RIR | 0 valid, saved |
| H-TEXT-{blur,done,exit,doubletap} | same parser; no zero; no auto-accept |
| H-TEXT-NO-HINT-SAVED | outbox has only entered values |
### `test/wes2_display_agreement_test.dart`
| H-AGREE-CONSUMED-NUMERIC (R9) | consumed weight/reps/RIR == previous final row's `actual ?? hint` model values, exact equality, no tolerance |
| H-AGREE-PROVENANCE (R9) | actual-vs-hint provenance per field asserted separately from the number |
| H-AGREE-RENDERED-TEXT (R9) | rendered text matches via the real formatters, after the numeric assertions |
### `test/wes2_hint_structure_test.dart`
| H-STRUCT-REMOVE-RECALC (R: P6) / ADD / UNDO | immediate recalc == fresh pass |
| H-STRUCT-SAVED-COUNT-WINS / OLDER-SAVED | planned sets do not reappear |
| H-STRUCT-POSITIONAL-PRESCRIPTIONS | prescriptions stay positional |
| H-STRUCT-IDS-NOTES-MEDIA | attached after removal/restore |
| H-STRUCT-PLAN-ONLY-FRESH vs ESTABLISHED | growth once |
| H-STRUCT-NO-RESURRECTION | hint passes never add sets |
### `test/wes2_hint_load_runner_test.dart`
| H-RUN-OLD-AFTER-NEW | older completion ignored |
| H-RUN-SETTINGS-RACE | older settings never replace newer cache/defaults/types |
| H-RUN-CONTEXT-{date,athlete,block} | no registration/application |
| H-RUN-LATE-EDITS | edits during load included |
| H-RUN-DISPOSED / NO-BLOCK | no side effects |
| H-RUN-ONE-NOTIFY | exactly one notification per logical pass |
### `test/wes2_hint_offline_context_test.dart`
| H-OFF-MODE-{1,2,3} | §7 modes |
| H-OFF-PRESCRIPTION-ORIGIN | server→cache→local order; schema-1 hints never prescriptions (R: R-HINTORIGIN) |
| H-OFF-FIRST-UPGRADE | no shadow, offline |
| H-OFF-REFRESH-RECOVERY | recompute on return |
| H-JSON-ROUNDTRIP | hintOrigin, velocity, setId, notes |
| H-USER-DATA-PREDICATE | `workoutHasUserEnteredData` unchanged semantics |
### `test/bb3_day_panel_cascade_test.dart`
| H-BB3-CHARACTERISE | old vs new outputs + reason |
| H-BB3-NO-SAVE | panel hints never persisted |

### Persistence (real Drift outbox, engine, `FirestoreWes2Repository` on `FakeFirebaseFirestore`, real controller/load pipeline; selected real widgets)
| Test | Requirement |
|---|---|
| S-ORDER-C100-REMOVE-B (R: probe5) | `[50,100]` |
| S-ORDER-CONSECUTIVE-REMOVALS (R: P6a) | both reach server |
| S-ORDER-DEL-UNDO-ADD-DEL-UNDO | final state exact |
| S-ORDER-IDS-ACROSS-VISITS-RESTARTS (R: R-SEQ) | unique seqs, both kept |
| S-ORDER-COALESCE-BOUNDARIES | only last pending not-in-flight |
| S-COALESCE-FRAME-REBUILD (R6) | offline 50 → 55 → 60 on one field syncs to 60 with no recovery item; the replacement carries the original frame and no dependency on deleted seqs |
| S-COALESCE-AFTER-ATTEMPT (R6, R2) | after a transient error the next edit is appended, not merged; both reconcile |
| S-COALESCE-CLEAR-NOTE-DONE (R6) | clear, set-note and markDone coalescing follow the same frame rebuild |
| S-REF-REMAP (R6) | re-authoring remaps `frameOps` and structural-undo `removalSeq`/`restoreSeq`; no dangling or falsely satisfied reference |
| S-ORDER-BACKOFF-PREREQ (R: P6b) / BLOCKED / MALFORMED | scope waits; other days progress |
| S-ORDER-INFLIGHT-NEW-REVISION (R: P6c) | 55 survives ack and error |
| S-ORDER-SERVER55-INFLIGHT50 | ends 55, both acknowledged |
| S-ORDER-DRAIN-NO-TIMER | many ops drain in one trigger |
| S-U5 | `[50,80,70]` exactly once after reload/reconnect |
| S-REPLAY-CRASH-AFTER-COMMIT-{each kind} | alreadyApplied, shadow correct |
| S-REPLAY-RETURN-TO-PRE (v5 cex) | foreign delete not reversed |
| S-REPLAY-DOC-RESET | conflict, not replay |
| S-REPLAY-LOG-PRUNED | id-less ⇒ conflict, id ⇒ applies |
| S-BOOT-FIRST-WRITE-CLEAN (R3) | ordinary first creation on an absent document still works offline and online |
| S-BOOT-UNCERTAIN-AFTER-RESET (R3) | attempted create/promote + lost ack + document deleted ⇒ `uncertainFirstWrite` recovery, no recreation |
| S-BOOT-LEGACY-NO-RECEIPTS (R3) | legacy document without receipts bootstraps safely; idempotent value ops still apply |
| S-BOOT-RECREATED-BY-OTHER-DEVICE (R3) | different epoch ⇒ conflict, never silent reapply |
| S-BOOT-CHECKPOINT-LOST (R3) | checkpoint absent but document present: destructive ops conflict, value ops reapply idempotently |
| S-STREAM-ERA-ROLLBACK (R3) | a restored outbox database (same installation id, lower `nextSeq`) rotates its era at first contact; the new edit reaches the server instead of being absorbed as `alreadyApplied` |
| S-ID-UNIQUE-CONTENT (v5 cex) | never edits C |
| S-ID-SAME-COUNT-REMOTE-STRUCT | conflict or correct token |
| S-ID-REMOTE-VALUE-CHANGE-IDENTIFIED | applies to id |
| S-ID-IDENTICAL-IDLESS-SETS | no collapse |
| S-ID-FIELD-NOTE-SETID-AFTER-INSERT | correct target |
| S-ID-DELETE-EXERCISE-CHANGED (v5 cex) | conflict |
| S-ID-EXERCISE-LEVEL-FIELDS | order/circuit/done/note changes detected |
| S-ID-OLD-BUILD-WRITER | receipts preserved, rowHash break detected |
| S-ID-RETURN-TO-IDENTICAL-ROW (R4) | remove B + insert D holding the same number: the id-less edit conflicts although `preRowHash` matches; removal variant likewise |
| S-ID-BREAK-NOT-HIDDEN-BY-IDENTIFIED-WRITE (R4) | old-build change → new-build `setId` write → pending id-less op conflicts (`historyBroken`) rather than applying to changed content |
| S-ID-BREAK-ON-EVERY-PATH (R4) | every committing kind (field, note, done, setId, setCount, structural) records breaks before refreshing `rowHash` |
| S-SHADOW-NOOP-CONFLICT-AUTHORITATIVE | shadow = returned doc |
| S-SHADOW-STALE-LOAD-AFTER-CONFIRM | load discarded |
| S-SHADOW-OVERLAP-LOADS-CONFIRMS-EDITS | ordered, no overwrite |
| S-SHADOW-OUT-OF-ORDER-LOADS (R8) | L1 (older data) finishing after L2 with no confirmation between them is rejected in the repository; the newest shadow survives restart and offline recovery |
| S-DISPLAY-VS-COMMIT-SPLIT (R7) | `resolveForDisplay` ignores checkpoint/epoch/dependency; `resolveForCommit` enforces them |
| S-DISPLAY-AMBIGUOUS-AFTER-CONFLICT (R7) | a positional target that became ambiguous because an earlier op did not apply moves visibly to recovery |
| S-SHADOW-CACHE-READ | never replaces shadow |
| S-CONFLICT-{apply,addNew,discard,discardExercise} + reload/reconnect | dependents revalidated |
| S-CONFLICT-RETRY-NOT-RESOLUTION | stays conflict |
| S-MIG-V1-FIXTURE-{each} | real v1 SQLite fixtures |
| S-MIG-REPLACED-TARGET (R5) | the id-less remove-B-insert-D case whose result equals the draft: no auto-conversion, recovery item, D untouched |
| S-MIG-APPLIED-UNACKED (R5) | already-applied but unacknowledged edits and removals convert or recover without double application |
| S-MIG-SAME-COUNT-REPLACEMENT (R5) | same-count remote replacement never auto-converts |
| S-MIG-COUNT-GUARD-NOOP (R5) | a no-op count guard is treated as unknown outcome, not as acknowledgement |
| S-MIG-DAMAGED-EVIDENCE (R5) | superseded/collapsed v1 rows ⇒ all recoverable intent preserved and listed |
| S-MIG-SCHEMA-UPGRADE | on-disk v1 DB opened by v2 |
| S-MIG-NO-SHADOW-OFFLINE | draft base, no overlay replay |
| S-UNSAVED-{detect,save,discard,restart} (R: TEST 10 semantics change) | explicitly unsaved; never rendered as an ordinary entry; excluded from the cascade |
| S-UNSAVED-RESTORE-IMMEDIATE | restored onto a safely identified set ⇒ actual + pending op + hints recomputed, with no server round trip |
| S-RENDER-PENDING-DRIVES-HINTS | offline/in-flight entries are actuals for the cascade throughout their pending life |
| S-UNDO-ONLY-SET / DELETE-EXERCISE × {online,offline,restart} (R: R-UNDO) | durable |
| S-UNDO-AFTER-LOST-ACK (R2) | commit succeeds, response times out, Undo before acknowledgement ⇒ durable restore; server, shadow, UI and media agree; removeSet and deleteExercise |
| S-UNDO-AFTER-CRASH-COMMITTED (R2) | same with crash + restart between commit and acknowledgement |
| S-UNDO-CANCEL-ONLY-UNATTEMPTED (R2) | cancellation happens only with `everAttempted == false`, atomically against a concurrent claim |
| S-DISCARD-ATTEMPTED-COMPENSATES (R2) | discarding an attempted op reconciles first and enqueues a compensating op instead of deleting evidence |
| S-UNDO-PRESERVES-{entries,ids,notes,done,order,circuit,media} | exact |
| S-UNDO-LATER-EDITS-OTHER-ROWS | survive |
| S-DI-SETID (R: R-SETID) | uses injected instance |
| S-RULES (`functions/test-rules/wes2_receipts_rules.spec.js`) | athlete/coach write, stranger denied |

### Media (`test/wes2_structural_media_recovery_test.dart`)
| M-MAINT-EVERY-AWAIT | maintenance (incl. zero window) injected at each await of removal/undo/recovery waits or skips held |
| M-ZERO-WINDOW-OTHER-VIDEO (R: R-MEDIA) | held footage survives |
| M-CRASH-{preparing,held,live,restoring} | recovered state + file bytes |
| M-EXCEPTION-LIVE-PROCESS-{each step} | recovered in same process |
| M-APPBAR-UNDO-AFTER-SNACKBAR | footage restored |
| M-HOLD-RELEASE-{dateChange,dispose,overflow,restart} | released, then finalised |
| M-RESTORING-ACROSS-RESTART | completed |
| M-OWNER-ISOLATION | other owner's files untouched |
| M-LIVE-UNDO-SURVIVES-MAINTENANCE (R1) | remove set B with footage, complete the operation, close the snackbar, run ordinary maintenance **and** a zero-window deletion of another video; app-bar Undo restores B and the original file **bytes**; repeated with exceptions injected after each durable transition |
| M-PUBLISH-FAILURE-REPUBLISHES (R1) | an exception after the durable op/record transaction but before controller publication rebuilds the screen from durable state; the record stays `live`, holds and media association intact, Undo still works |
| M-EXPIRED-PREVIOUS-SESSION (R1) | a `live` record from a previous process is discarded on the next launch and only then finalised |

### Existing suites updated (reason recorded per test in the commit/PR)
* `wes2_rir_actual_cascade_cap_test` "TEST 3 — same-value suppression still
  applies" and "clearing … restores original baseline hints" → rewritten to
  the no-suppression contract (suppression is D1/D2).
* `wes2_setn_cascade_test` TEST 16/17/20/23 → fed through the builder; any
  numeric change explained by the centre rule.
* `wes2_durable_sync_test` TEST 16/17 and "replacing/clearing drops queued
  edits", "replayed removal carries the guard" → same server outcomes,
  different queue mechanics (no supersession; checkpoint instead of count
  guard).
* `wes2_sync_semantics_test` TEST 10 "draft-only value still shows" → unsaved
  entry semantics.
* `wes2_set_video_store_test` finalizable → plus holds.
Legitimate guards (cap, BB3 locks, account isolation, tombstones, Done-only)
keep their assertions.

## 16. Limitations and performance

* Formula discontinuity at t = 25 remains; very high reps can still appear.
* Bounded search is not a global optimum.
* Durable Undo covers deleted sets/exercises only; add set, replace, move
  circuit, template replacement and delete-all keep session-local snapshot
  Undo (lost on restart; not synced as an inverse). This is stated in the
  handoff.
* A conflict at the head of a day pauses syncing of later changes for that
  day (they stay durable and visible) until resolved.
* Concurrent edits from **old builds** on id-less sets of the same exercise
  produce Needs-attention conflicts.
* An entry whose target stops being safely identifiable (conflict) leaves the
  cascade at that moment; hints for that set and later sets are recomputed
  without it while the marker and sheet show it. This is the one case where a
  value the athlete typed stops driving hints, and it is always visible.
* Structural Undo for BB3 exercise deletion restores execution data durably;
  the planned-day re-sync remains the existing best-effort call.
* Negative-assisted grid limitation and display-E1RM basis discrepancy
  characterised, not changed.
* **Pre-bootstrap ABA (R4 residual).** Before a document has ever been written
  by this protocol there is no history to consult, so an id-less target is
  authorised by whole-row equality alone. An old build that changed the row and
  changed it back in that window is indistinguishable. Smallest correction if
  this is not acceptable: refuse id-less targets on documents without receipts
  and route them to recovery instead — safe, but it would make the first edit
  after upgrade on every legacy day a Needs-attention item, so the plan keeps
  equality here and states the limit.
* **Uncertain first write (R3).** When a create/promote attempt's response is
  lost and the document is then deleted, the athlete sees a recovery item
  rather than a silent recreation. Their values are preserved and re-savable in
  one tap; they are not written automatically.
* **Discarding an attempted change** performs a compensating write rather than
  a local deletion, so the sheet calls it "Undo this change".
* Era rotation (restored outbox database) re-authors queued ops with new seqs;
  their original authoring order is preserved, but their `seq` values change.
* Keystroke cost: one edit recomputes sets `k..n` with ≤ 8 raw calls per set
  (memoised; typical 1–3). Set 1 raw may run BB3HintService; worst case 8 Set 1
  raws per Set 1 edit. A benchmark test reports p50/p95 per edit for 5-set
  rows on the test runner and on the phone checklist; if p95 > 16 ms on the
  runner I add a per-pass cache keyed by complete inputs (already memo-safe).
* Sync: one transaction per op (as today), shadow JSON write per commit
  (single small document).

## 17. Integration and release checklist (after approval)

1. Keep this worktree; rebase onto current `origin/main`; rerun affected gates.
2. `flutter pub get`; `flutter analyze` (compare with a baseline captured on
   `origin/main` before changes); focused suites; full `flutter test`.
3. `functions`: `npm test`, `npm run test:rules` (client write contract
   changed), showcase emulator specs; Java 21.
4. Coordinate `C:\Projects\RE-test` ownership (its dirty `.docx`/lock file are
   not ours; preserve); integrate branch into `main` there without stash/reset
   of others' work; no force-push.
5. Read current `pubspec.yaml` and release history; choose the next patch
   version and a versionCode above the highest known (check Play if
   accessible, else mark pending). Resume an existing candidate if already
   bumped. `flutter pub get` after bump (no `--no-pub`).
6. Record prior AAB version/size/SHA-256/upload certificate before overwriting.
7. Commit + push to `main`; record SHA.
8. Deployment: expected **none** (no rules/functions change); confirm from the
   final diff.
9. `flutter build appbundle --release`; verify package, versionName/Code,
   `jarsigner -verify`, certificate vs prior AAB, size, SHA-256; versioned
   copy; release record in `build/release-verification/`.
10. Handoff with phone checklist: live hint editing (Set 1 and later, accept,
    clear, 40×10 style acceptance), set/exercise deletion + snackbar and
    app-bar Undo, offline edits + restart + reconnect, a forced conflict from a
    second device, video on a deleted set then Undo, first launch after
    upgrade with pending offline edits.

## 18. Decisions resolved on 2026-09-16

**U-1 — approved in principle.** `rev`, `rowHash`, bounded `log`/`floor` and
`breaks` may live in `wes2OpReceipts` and may permit a concurrent edit only
when identity and recorded history establish compatibility. Missing or expired
history falls back to a visible conflict; hashes never substitute for set
identity; pruning the log never weakens replay protection. Written into §9.3,
§10.2 and the §15 tests.

**U-2 — approved with the stated nuance.** Genuinely unresolved legacy values
are retained as separate *Not saved* recovery items that do not drive hints
and are never shown as ordinary entries. Ordinary entries — including offline
entries awaiting sync — drive hints immediately, and a recovery value restored
onto a safely identified set becomes an actual that drives hints immediately,
without waiting for server confirmation. Written into §9.5a, §13 and the §15
tests.

No open decisions remain. Implementation approval is still pending review of
this plan; the checkpoint in NEXT.md is preserved.

## 19. Review R1–R9 → sections and regressions (v6.1)

| Review point | Corrected in | Named regressions |
|---|---|---|
| R1 live Undo vs maintenance; post-commit publication failure | §12.1 (two mechanisms), §12.2 step 6, §12.4 (closed trigger list), §12.5 (state table), §10.1 (`sessionId`, `publishedAtMs`) | M-LIVE-UNDO-SURVIVES-MAINTENANCE, M-PUBLISH-FAILURE-REPUBLISHES, M-EXPIRED-PREVIOUS-SESSION |
| R2 pending ≠ never committed | §8 (attempt evidence), §9.4 (claim), §9.6 (discard), §12.3 (cancel rule) | S-UNDO-AFTER-LOST-ACK, S-UNDO-AFTER-CRASH-COMMITTED, S-UNDO-CANCEL-ONLY-UNATTEMPTED, S-DISCARD-ATTEMPTED-COMPENSATES, S-COALESCE-AFTER-ATTEMPT |
| R3 epoch bootstrap, reset recovery, stream identity reuse | §8 (era, bootstrap id), §9.2 steps 1–3, §9.7, §10.1, §10.2 | S-BOOT-FIRST-WRITE-CLEAN, S-BOOT-UNCERTAIN-AFTER-RESET, S-BOOT-LEGACY-NO-RECEIPTS, S-BOOT-RECREATED-BY-OTHER-DEVICE, S-BOOT-CHECKPOINT-LOST, S-STREAM-ERA-ROLLBACK |
| R4 hash must not override history; break detection everywhere | §9.3 (order + break detection) | S-ID-RETURN-TO-IDENTICAL-ROW, S-ID-BREAK-NOT-HIDDEN-BY-IDENTIFIED-WRITE, S-ID-BREAK-ON-EVERY-PATH, S-ID-UNIQUE-CONTENT, S-REPLAY-LOG-PRUNED |
| R5 migration cannot use the post-state as proof | §9.8 step 4 | S-MIG-REPLACED-TARGET, S-MIG-APPLIED-UNACKED, S-MIG-SAME-COUNT-REPLACEMENT, S-MIG-COUNT-GUARD-NOOP, S-MIG-DAMAGED-EVIDENCE, S-MIG-NO-SHADOW-OFFLINE |
| R6 coalescing frame rebuild and references | §9.4 (coalescing), §9.6 (remap) | S-COALESCE-FRAME-REBUILD, S-COALESCE-CLEAR-NOTE-DONE, S-REF-REMAP |
| R7 display eligibility ≠ commit prerequisites | §9.2 (two entry points), §9.5, §9.5a | E2E-BLOCKED-EARLIER-LATER-DRIVES, S-DISPLAY-VS-COMMIT-SPLIT, S-DISPLAY-AMBIGUOUS-AFTER-CONFLICT |
| R8 overlapping loads vs durable shadow | §9.5, §10.1 (`lastLoadGen`) | S-SHADOW-OUT-OF-ORDER-LOADS |
| R9 numeric predecessor equality + editing text | §3.12, §15 E2E block | H-AGREE-CONSUMED-NUMERIC, H-AGREE-PROVENANCE, H-AGREE-RENDERED-TEXT, E2E-PREDECESSOR-NUMERIC-EQUALITY, E2E-EDITING-TEXT-VS-MODEL |

Isolated prototype (`docs/wes2-cascade/prototype/protocol_prototype_test.dart`,
12 checks, all passing) demonstrates the corrected transitions for R1–R8 as a
specification model. It found one defect in the first draft of the R4
correction: a break stamped with the pre-increment revision failed to fence the
operation it was meant to fence, and the target row's own unlogged change was
compared after mutation. Both are fixed in §9.3. The prototype is not a
production gate and proves nothing about `lib/`.
