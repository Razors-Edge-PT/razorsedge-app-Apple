# WES2 hint-cascade repair — reproduction record

All runs on **2026-09-16**, worktree `C:\Projects\RE-wes2-cascade`, branch
`fix/wes2-live-hint-cascade`, HEAD `abdaa477` (= `origin/main` at fetch time),
production code **unmodified**. Raw outputs were captured to the session
scratchpad; the relevant lines are transcribed here.

These are **disposable reproductions of current defects**, not implementation
gates. None of them proves the redesigned code works. They call production
classes directly; where a screen method would normally drive a call, the probe
mirrors that exact code path and says so (so they are *production-class* runs,
not full screen-orchestration runs — the implementation plan adds those).

Synthetic fixtures are **not** screenshot evidence. Screenshot numbers are in
PLAN.md §2 and were never re-derived here.

## Baseline

`flutter test` on 14 existing suites (hint service, Set N solver/cascade, RIR
cap, done/focus race, top-sets round trip, set identity, timed cell, durable
sync, sync semantics, settings increments, set-video store/service/pipeline):
**308 passed, 0 failed.**

## Recovered probes (lost session 848fba5c, re-run today)

Copied verbatim to `recovered-probes/`. Fixture: `Seated Shoulder Dumbbell
Press`, Linear Classic, 2.5 kg grid, history 35×8@2, group C.

| Probe | Defect | Observed today |
|---|---|---|
| P1 | D3 centre | S1 actual 20×20@0 → S2 hint **20×15@2 (E1RM 36.0)** vs target 41.35 |
| P2 | D1 suppression | S1 weight 30 → S2 hint 30×13. Typing S2 weight **32.5** (= OLD baseline) → recalc input S2 weight actual **null**; screen shows 32.5×13 while S3 consumed 30×13 |
| P3 | D2 RIR authority | S1 entered RIR **3** (= hint): recalc input RIR actual **null**; S2 reps 3 → S2 weight 35, S3 30×7. Entered **3.5**: retained, S2 37.5×3 |
| P4 | D4 recapture | after S1 25×15 + addSet + screen pass, clearing **all** S1 entries leaves S2 32.5×15 (E1RM 58.5) / S3 27.5×18 — not the load-time 32.5×10 |
| P5 | D5 drift | fixed S1 15×30@0: S3 **15×14 → 12.5×19 → 10×22** across passes, then stable |
| P5 tail | screenshot shape (synthetic) | then S4 actual 40×7@0.5 → S5 hint **35×17@0.5, E1RM 64.6** (cf. triceps screenshot 36×25@0.5, 66.6) |
| P6 | D6 removeSet | after removing S2, survivor keeps 20×15; a recompute gives 20×20 |
| P7 | D7 undo | baseline present after deleteExercise+undo: **false** |
| P8 | D8 text | text `-` / `.` after 25 → model weight actual stays **25.0** |

Queue probes (real Drift outbox + `Wes2SyncEngine` + `FirestoreWes2Repository`
on `FakeFirebaseFirestore`):

| Probe | Scenario | Server result | Intent |
|---|---|---|---|
| probe5 | [50,60,70]: C→100 then remove B | `[50, 70]` (100 lost). Queue `1:field@1, 2:removeSet@1` — field index rewritten, seq not | `[50, 100]` |
| P6a | offline remove B, then C (same compacted index) | queue `1:removeSet@1` only; server **unchanged** `[10,20,30]` | `[10]` |
| P6b | removal backs off; later edit to new set 1 | after pass 2 `[99,20,30]` (edit overtook); final `[20,30]` | `[99,30]` |
| P6c | 50 in flight, athlete types 55 (same slot) | server `[50,…]`, queue **empty** — 55 deleted by old ack | 55 |

Exhaustive acceptance probe `probe4` (old centre, ±0.05 RIR tolerance
matching, 11 fixtures incl. two Set 1 fixtures, Linear Classic only):
**1,063 states, 590 acceptance steps, 187 ambiguous states, 0 ambiguous
disagreements, 0 I1 violations, 0 view breaks; 41 breaks without the view
rule.** Identical to the lost session's report. It does not cover the new
centre, formatted-string matching, other progression models, or production
controller wiring.

## New reproductions (`repro/repro_current_main_test.dart`)

Settings: Linear Classic, `10 x 3`, RIR plan 2, 2.5 kg grid, no history.

| ID | Observed on current code |
|---|---|
| R-HINT-1 | S1 40×10@2 → S2 **35×13@2** (57.2727), S3 32.5×14@2 |
| R-HINT-2 | S1 20×20@0 (42.3529; target 41.3529) → S2 **20×15@2 = 36.0** (centre = plan reps 10 ⇒ window 5–15) |
| R-HINT-3 | S1 40×7@2 (51.4286; target 50.6286), S2 weight 20 → reps **15** (36.0) |
| R-HINT-4 | same as R-HINT-2 but S2 carries stale own rep hint 30 → S2 **20×30@2** (41.312): own output captures the search |
| R-HINT-5 | free S2 35×13@2. Enter w=40 → reps 10; accept 10 → **RIR 2.0→1.5**, S3 **32.5×14 → 40×9**. Reps-first order: identical 1.5 / 40×9 |
| R-PARSE | `NaN`, `Infinity`, `-Infinity` become weight actuals; `.`/`-` keep 25.0 |
| R-HINTORIGIN | draft JSON round trip: `bb3Hint` → **`empty`** (lock lost) |
| R-UNDO | removeSet queued+applied, `controller.undo()`: local `[50,60,70]`, queue 0 rows, server reload **`[50,70]`** — Undo is not durable |
| R-SEQ | two removals with `localSeq` 1 (new screen visit) → **1** queued row; first removal deleted |
| R-SETID | `saveSetId` on injected FakeFirebaseFirestore throws `[core/no-app]` (uses `FirebaseFirestore.instance`) |
| R-MEDIA | structural soft delete B + direct delete C; `finalizeExpiredDeletions(undoWindow: zero)` (what `finalizeDeletion(C)` runs) → finalised **2**, B's file **deleted**, row purged |

## Language facts verified with `dart run`

| Expression | Result | Consequence |
|---|---|---|
| `1.25.toStringAsFixed(1)` | `1.3` | displayed-hint acceptance rounds |
| `0.15.toStringAsFixed(1)` / `2.55…` | `0.1` / `2.5` | a symmetric ±0.05 tolerance disagrees with the widget ⇒ match on formatted text |
| `16.2505.toStringAsFixed(3)` | `16.250` | same for weight |
| `double.nan.clamp(1.0, 45.0)` | `45.0` | inverse inputs must be validated **before** `reverseCalculateReps` |
| `double.tryParse('NaN')` / `'1e3'` | `NaN` / `1000.0` | finite + decimal-syntax parser needed |
| `int.tryParse('0x10')` | `16` | reps parser must be decimal-only |

## Hand arithmetic (model demonstration, not a test run)

Unchanged formulas (`t = reps + RIR`; `t ≤ 25` Brzycki `w·36/(37−t)`, else
`w·(1+0.0333t)`; inverse picks the branch and clamps reps to 1–45).

* 40×10@2 → 57.6; group C drop 1.0 gated ×0.8 (prev RIR 2) → **56.8**.
* 20×20@0 → 42.3529; drop 1.0 → **41.3529**. Inverse at W0=20, RIR 2 →
  17.59 → centre 18; window 13–23; weights {20,17.5,15}: best **15×22@2 =
  41.538** (|err| 0.185).
* 40×7@2 → 51.4286 → **50.6286**. At weight 20, RIR 2: inverse 20.78 →
  centre 21; best **20×21@2 = 51.43**.
* Target 31, 15 kg, RIR 2: inverse centre 18 → 31.7647; rep 30 (t=32, Epley)
  → 30.984 lies outside the ±5 window. Limitation illustration only.
* Accepted 40×10 at S2 with target 56.8: naive late RIR solve 1.5 (56.47);
  view rule reuses view({reps:10}) whose weight hint is 40 and RIR hint 2 ⇒
  RIR stays 2; S3 then sees predecessor 40×10@2 ⇒ same target 56.8 ⇒ free
  S3 = S2's free result **35×13@2**.
