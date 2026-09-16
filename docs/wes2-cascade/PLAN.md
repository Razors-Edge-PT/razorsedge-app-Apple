# WES2 hint cascade — Stage 1 (implemented) and Stage 2 (scoped)

Branch `fix/wes2-live-hint-cascade`, based on `origin/main` `abdaa477`.
Companions: `PROBES.md` (reproduced failures), `DECISIONS.md` (decision log),
`NEXT.md` (resume point), `ARCHIVE_v6.1_protocol.md` (earlier persistence
protocol — background only, **not approved for implementation**).

---

## Stage 1 — hint cascade. IMPLEMENTED, full suite green.

`flutter test`: **2195 passing, 0 failing.** `flutter analyze lib/`: 1017
issues on both `origin/main` and this branch — **no new issues**; the only
differences are line numbers of pre-existing style infos.

### S1-1 What changed, and why

| Change | File(s) | The defect it removes |
|---|---|---|
| **One input builder.** Calculation input is rebuilt from actuals + positional BB3 prescriptions only. | `wes2_hint_input.dart` | A row's own generated hints were input to their own regeneration (Set 3 walked 15×14 → 12.5×19 → 10×22 across passes), and a recovered draft hint was indistinguishable from a BB3 lock. |
| **Forward resolver with the accepted-hint view.** Set 1 resolves, each later set consumes the previous set's final `actual ?? hint` mixture; typing a value the set already shows reuses that set's hints instead of re-solving it. | `wes2_cascade_resolver.dart` | Accepting a hinted 10 reps at 40 kg moved RIR 2 → 1.5 and shifted every later set. |
| **Matching uses the row's own formatters** (`Wes2HintFormat`, shared with the widget). | `wes2_cascade_resolver.dart`, `WES2_set_row.dart` | A ±0.05 tolerance disagrees with the display: `0.15` renders "0.1", `2.55` renders "2.5". |
| **Set N rep centre = the inverse at the anchor weight**, with validated inputs and reported provenance (`constraint`/`inverse`/`clamp`/`fallback`). | `wes2_setn_solver.dart`, `WES2_hint_service.dart` | The centre was the set's own stale rep hint, then the plan target: after Set 1 of 20×20@0 (target 41.35) the window could only reach 20×15 = 36.0. `NaN.clamp(1,45)` returns 45, so an invalid input looked like a 45-rep centre. |
| **Set 1 late-RIR fallback uses this day's pure Set 1 context** (the same Set 1 with no entries), computed once per pass. | `WES2_hint_service.dart` | The fallback read the set's own hints, i.e. the previous pass's output, so it drifted and could be contaminated by the athlete's earlier entries. |
| **Timed sets propagate the previous set's resolved seconds/added load**; plan→seconds conversion happens once from the prescription. | `WES2_hint_service.dart` | A plank actually held for 60 s still suggested the planned 45 s for every later set. |
| **Prescriptions are a separate positional store**, captured from the planned day. | `WES2_models.dart`, `WES2_controller.dart`, `WES2_screen.dart` | Prescription authority was read back out of row hints. |
| **Single recompute path in the controller**, forward-only from the edited set; baseline snapshot machinery deleted. | `WES2_controller.dart` | Same-value entries were suppressed (the screen showed 32.5 while the next set consumed 30), an entered RIR equal to its hint lost actual-only authority, and clearing restored load-time hints instead of current-context ones. |
| **Structural operations re-cascade immediately** and mark session structure established. | `WES2_controller.dart`, `WES2_hint_service.dart` | `removeSet` left the survivor on the removed set's hints; a later pass grew the row back to the planned count, resurrecting a deleted set. |
| **One parser for every entry point**, decimal-only and finite. | `wes2_field_parser.dart`, controller, row widget, screen | `NaN`, `Infinity`, `1e3` and `0x10` were accepted as entries; a half-typed `-` left the field showing `-` while the model held 25. |
| **Invalid text is restored on blur**, never saved, never turned into 0 or into an accepted hint. | `WES2_set_row.dart` | Same. |
| **RIR direction cue reads a live per-pass reference** (`rirReferenceHint`) instead of a load-time baseline. | `WES2_models.dart`, `WES2_set_row.dart`, `WES2_exercise_card.dart` | The baseline went stale and could carry the athlete's own earlier entries. |
| **Hint pass extracted into `Wes2HintLoadRunner`** with one identity token checked after every await and before every cache write, service registration and application. | `wes2_hint_load_runner.dart`, `WES2_screen.dart` | An older pass could install its settings, register its service and apply its hints over the day then on screen; a settings save could be overwritten by a response already in flight. |
| **`hintOrigin` is serialised** in draft JSON. | `WES2_models.dart` | A reloaded draft lost BB3 provenance, so a generated number could act as a lock. |

Unchanged on purpose: the E1RM formulas and their inverses, the progression
engine and models, `PeriodizationModelUtils`, BB3HintService, the candidate
domain / ±5 window / tie ladder / weight cap, extra-set RIR inheritance,
bodyweight display-vs-absolute handling, and the whole persistence layer.

### S1-2 Which acceptance criteria Stage 1 satisfies

| Criterion | Status | Evidence |
|---|---|---|
| Each subsequent set consumes the preceding set's final actual/hint mixture | **met** | `wes2_display_agreement_test` (numeric, provenance, rendered text), `wes2_cascade_contract_test` H-MASK (8 combinations × Set 1 and an intermediate set) |
| Any weight/reps/RIR edit or clear updates sibling hints first, then propagates | **met** | H-SIBLING, H-CLEAR |
| Later entries, zero RIR and entries identical to hints are preserved | **met** | H-MASK, "RIR 0 is a real entry", "an entry equal to the hint is still consumed", updated `wes2_rir_actual_cascade_cap_test` TEST 3 |
| Stale hints cannot feed their own recalculation; no drift | **met** | H-STABILITY (10 further passes; repeated recalculation), `wes2_setn_centre_test` stale-own-hint case |
| Prescriptions, timed and bodyweight behaviour, existing progression behaviour preserved | **met** | `wes2_timed_cascade_test`, `wes2_setn_cascade_test` (incl. BB3 locks, bodyweight, models), `wes2_hint_service_test` |
| Limited Set 1 post-processing only | **met** | pure Set 1 fallback; late RIR solve, cue flags and the engine untouched |
| E1RM formulas and inverses unchanged | **met** | no edit to `periodization_model_utils.dart`; literal targets re-derived by hand in `wes2_setn_centre_test` |
| All eight actual/hint combinations, acceptance, clearing, repeated recalculation, unfinished/rapid typing, structural changes | **met** | the five new suites listed in NEXT.md |
| Existing reload/offline paths still work | **met** | `wes2_durable_sync_test`, `wes2_sync_semantics_test`, `wes2_set_video_*`, full suite green |
| Production screen/controller/runner exercised | **partly met** | real controller + real hint service + real `Wes2SetRow` + real `Wes2HintLoadRunner`. The `Wes2Screen` widget itself is not pumped: it constructs its repository, local store and sync services internally and needs Firebase, Isar and Drift. Adding those seams is deferred to Stage 2, where the persistence work touches the same wiring. |
| All-model accepted-hint gate | **met, no counterexample** | `wes2_accepted_hint_view_test`: 4 progression models × history present/absent × 3 sets — acceptance stability and I1 both hold |

### S1-3 Still dependent on Stage 2

* Durable Undo for deleted sets/exercises (`R-UNDO`).
* The queue/ordering failures (`probe5`, `P6a`, `P6b`, `P6c`, `R-SEQ`).
* Footage purged while Undo is still offered (`R-MEDIA`).
* `saveSetId` dependency injection (`R-SETID`).
* Offline hint context beyond what exists today: prescriptions still come from
  the planned-day load, so an offline day with no cached plan shows model hints
  only. Stage 1 keeps that behaviour rather than adding a local prescription
  store, which belongs with the Stage 2 persistence work.

### S1-4 Known limitations (unchanged by Stage 1)

* The E1RM formula discontinuity at `t = 25` still produces very high rep
  suggestions in places; replacing the formula is a separate task.
* The bounded search is not a global optimum (target 31 / 15 kg / RIR 2:
  centre 18 gives 31.76, while 30 reps would give 30.98, outside the window).
* Set 1 keeps its planned rep target where the progression model owns that
  decision; a Set 1 weight entry is reflected in the cascade rather than in its
  own rep hint.
* Negative-assisted grid limits and the display-E1RM basis are characterised,
  not changed.

### S1-5 Acceptance coverage map

Requirement → test name → complete or deferred. Test names are the `test(...)`
descriptions in the named file.

**All eight actual/hint combinations, acceptance and clearing — COMPLETE**

| Requirement | Test |
|---|---|
| Eight combinations at Set 1, next set observes | `wes2_cascade_contract_test` → `H-MASK` group, `set 1 HHH` … `set 1 AAA` (8) |
| Eight combinations at an intermediate set | same group, `set 2 HHH` … `set 2 AAA` (8) |
| Accepting a displayed hint leaves the rest of that set alone | `wes2_accepted_hint_view_test` → `H-VIEW-40x10` group (free / weight-first / reps-first / Set 3 follow-on) |
| Acceptance across every progression model, history present and absent | same file → `H-VIEW-GATE`, `<model> (history: true|false) — accepting any displayed hint leaves the rest of that set unchanged` (8 tests) |
| Acceptance matches what was displayed, not a tolerance | same file → `H-VIEW-FORMAT` group (3) |
| An accepted RIR keeps entered-RIR authority | same file → `entered RIR 3.0 permits a heavier next set; a hinted 3.0 does not`; `wes2_display_agreement_test` → `H-AGREE-PROVENANCE` |
| Clearing one field / all fields returns current-context hints | `wes2_cascade_contract_test` → `clearing one field restores the current-context hint`, `clearing every field returns the whole row to its free state` |
| Clearing is distinct from invalid text | `wes2_field_entry_widget_test` → `H-TEXT-CLEAR an emptied field is a clear, not invalid text` |
| An entry equal to its hint is preserved and consumed | `wes2_cascade_contract_test` → `an entry equal to the hint is still consumed by the next set`; `wes2_rir_actual_cascade_cap_test` → `TEST 3 — entries equal to their hints are preserved, not suppressed` |

**Saved structure and positional BB3 prescriptions — COMPLETE**

| Requirement | Test |
|---|---|
| A saved row keeps its own set count across a reload (through `FirestoreWes2Repository.loadDay`) | `wes2_hint_structure_and_provenance_test` → `a two-set saved row is not grown back to the planned four` |
| A plan-only row still takes the planned count | same file → `a plan-only row still takes the planned count` |
| A hint pass never resurrects a removed set in-session | `wes2_cascade_contract_test` → `a hint pass never resurrects a removed set` |
| Each set shows its own prescription, as a BB3 lock | `wes2_hint_structure_and_provenance_test` → `each set shows its own prescription, as a BB3 lock` |
| Prescriptions stay positional after a removal | same file → `after removing set 2, position 2 keeps prescription 2` |
| BB3 locks stay authoritative through the cascade | `wes2_setn_cascade_test` → `TESTS 24-25` (pre-existing, still green) |

**Hint provenance and entries surviving a draft reload — COMPLETE at the draft
payload level**

| Requirement | Test |
|---|---|
| Entries (including an entered 0), notes and setId round trip | `wes2_hint_structure_and_provenance_test` → `actual values, notes, setId and hint provenance round trip` |
| A BB3 prescription stays a prescription; a generated hint stays a display value | same test, plus `a generated hint is never promoted to a prescription` |
| An old schema-1 draft yields no prescriptions, but its entries still recover | same file → `a schema-1 draft (no hintOrigin) yields no prescriptions` |
| Stored `setId` survives the Firestore shape | `wes2_set_identity_test` (pre-existing) |

Scope note: these exercise `Wes2ExerciseRow.toJson/fromJson`, which is exactly
what `IsarWes2LocalStore` writes and reads. The Isar store itself is not
driven in a test (it needs the native database); that is unchanged from before
this work.

**Missing settings / history and offline hint behaviour — PARTLY COMPLETE**

| Requirement | Status |
|---|---|
| No hint service (settings unavailable): entries still recorded, nothing invented | **complete** — `wes2_hint_structure_and_provenance_test` → `with no hint service the entry is still recorded and nothing is invented` |
| Settings present, no history: plan path still produces hints and the cascade runs | **complete** — same file → `with settings but no history the plan still produces hints`; and every `H-VIEW-GATE` case runs twice, once with `history: false` |
| A superseded settings response cannot overwrite newer settings | **complete** — `wes2_hint_load_runner_test` → `H-RUN-SETTINGS-RACE` |
| Existing offline rendering (draft + pending intent) still behaves | **complete, pre-existing coverage** — `wes2_sync_semantics_test` → `TEST 10` / `TEST 11` groups |
| Prescriptions available offline | **deferred to Stage 2.** They are still read from the planned-day load, so an offline day with no cached plan shows model hints only. A local prescription store belongs with the Stage 2 persistence work; no new test claims otherwise. |
| Offline hint *modes* (keep-known-prefix, clear-affected-downstream) | **deferred to Stage 2.** Stage 1 keeps today's behaviour: with no service registered the existing hints stay on screen and no new ones are computed. |

**Hints are never persisted as actuals — COMPLETE**

| Requirement | Test |
|---|---|
| Recalculation never creates an actual | `wes2_cascade_contract_test` → `recalculation never turns a hint into an actual` |
| Only entered fields are saved from the row widget | `wes2_field_entry_widget_test` → `H-TEXT-NO-HINT-SAVED only entered fields are ever saved` |
| A row carrying only hints serialises no execution values | `wes2_hint_structure_and_provenance_test` → `hints are never written into the entry fields` (asserts `buildRowMapForTest` emits no weight/reps/rir) |
| Done, save and refresh never materialise a hint | `wes2_sync_semantics_test` → `TEST 2 / 14 / 30` group (pre-existing) |
| `workoutHasUserEnteredData` still ignores hint-only rows | `wes2_cascade_contract_test` → same test as row 1 |

**Production screen integration — DEFERRED, release blocker (see Release).**

### S1-6 Existing tests updated, with reasons

* `wes2_rir_actual_cascade_cap_test` — harness moved to `applyHintContext`;
  "TEST 3 — same-value suppression still applies" **rewritten** to
  "entries equal to their hints are preserved": the old assertion encoded the
  defect (the cascade calculating from a value the athlete had not entered).
  Every cap/boundary assertion in that file is unchanged and still passes.
* `wes2_setn_cascade_test` — harness moved to `applyHintContext`; the
  reference model's rep centre now comes from `Wes2SetNSolver.centre` instead
  of the set's own baseline hint (TEST 16) and the plan target (TEST 18), and
  the brute force applies the documented tie ladder, which the new centre makes
  reachable (32.5×9, 35×7 and 37.5×5 all hit 45.0 exactly). The assertions
  themselves — minimum error, cap respected, candidate legality — are unchanged.

---

## Stage 2 — durable Undo and the reproduced saving failures. NOT STARTED.

Scope is exactly the eight reproduced failures listed in `NEXT.md`, each with
a named regression, using the smallest repair consistent with the agreed
guarantees. `ARCHIVE_v6.1_protocol.md` is background only: stream eras,
document epochs, durable shadows, structural logs and legacy reconciliation
are **not** deliverables unless a specific reproduced failure needs them.

Where a minimal repair is not yet worked out, the failing scenario and the
proposed smallest fix are recorded for review rather than implemented.

---

## Release

### RELEASE BLOCKER — real `Wes2Screen` integration test

Not shippable without it. It may land with Stage 2, whose persistence work
touches the same wiring (the screen builds its repository, local store and
sync services internally, which is why it cannot be pumped today), but it is a
gate on the release, not on Stage 2's review.

It must drive the **actual** `Wes2Screen` — not the controller standing in for
it — and prove, after each interaction:

* **numerical predecessor equality** — the values the cascade consumed equal
  the previous row's final `actual ?? hint` model numbers exactly, no
  tolerance, nothing rounded;
* **provenance** — per field, actual versus hint, asserted separately from the
  number, so an accepted value is still an entry;
* **displayed behaviour** — the rendered text through the real formatters.

Across: editing, clearing, accepting a displayed hint, structural changes
(add set, remove set, delete exercise, undo) and a reload of the day.

Until it exists, `wes2_display_agreement_test` covers the same three levels one
layer down (real controller, real hint service, real `Wes2SetRow`), and that
distinction is stated rather than glossed.

### Then

After Stage 2 review, this blocker and the remaining integration gates,
`/goodlift-release` performs the already-authorised version bump, integration
checks and verified signed AAB. `main` and the release version stay unchanged
during review. The custom E1RM formula remains a separate future task.
