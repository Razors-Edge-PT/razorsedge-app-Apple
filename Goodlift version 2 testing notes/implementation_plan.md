# REClaude Implementation Plan
*Last updated: 2026-03-28 (Q1–Q5 resolved)*

This document is the canonical reference for all planned changes, organised by tier. Each item includes the desired behaviour, affected files (where known), and open questions.

---

## Tier 1 — Bug Fixes (Active Regressions)

### 1.1 Workout Session Rehydration Bug
**Problem:** When a user edits a workout session (removes/adds exercises, edits sets) and leaves the app, reopening that date's workout reloads from the schedule, discarding all edits.

**Desired behaviour:**
- The workout entry screen for a given date must persist its own state independently of the schedule.
- The schedule is the **initial seed only** — once any user edit is made (add, remove, reorder exercise; add, remove, edit set), the session state is the source of truth.
- This must hold across app restarts until the workout is explicitly cleared.
- There is no "Finish Workout" button; auto-save on every change is required.

**Scope of edits that must be preserved:**
- Exercise removed from session
- Exercise added to session (including exercises not in the schedule)
- Set added beyond planned count
- Set removed
- Set values (weight, reps, RIR) entered or edited
- Circuit structure changes (add/remove circuit)

**Suggested implementation:**
- Introduce a `WorkoutSessionCache` layer that persists a per-date session snapshot to local storage (JSON, keyed by `{uid}_{date}`).
- On open: check for existing session cache → use it if present; otherwise seed from schedule.
- On any edit: write cache immediately.
- Cache is cleared only when the user explicitly resets/clears the session (future feature).

**Affected files:** `workout_session_screen.dart`, `weekly_schedule_service.dart`, new `workout_session_cache.dart`

---

### 1.2 Set Completion Dynamic State
**Desired behaviour:**
- A set becomes "complete" when all required fields (weight, reps, RIR) are populated.
- Deleting a value from any field marks the set (and by extension the exercise) as incomplete.
- Pressing "Complete" on an exercise promotes all hint text values to plain text values and marks complete.
- Un-completing works at set level (clear a field) and exercise level (tap checkmark again).

**Affected files:** `circuit_card.dart`, `workout_session_screen.dart`

---

### 1.4 Set Cascade Bug — Reps-Only Edit Does Not Propagate Downstream

**Status:** Partially resolved. Weight edits on any set correctly propagate downstream (confirmed working). RIR edits correctly update gating (confirmed working). **Reps-only edits (no logged weight) are the confirmed remaining gap.**

**Root cause (identified via RE-Test-Main comparison, 2026-03-28):**
The re-anchor condition in `circuit_card.dart → _buildSetHints()` (line 539) is:
```dart
if (index == 0 || log.weight != null)
```
This only updates `set1E1rm` when a logged weight exists on the set. When a user changes reps on Set N without logging a weight, `log.weight == null` → the condition fails → `set1E1rm` is not updated → downstream sets continue to use the pre-edit E1RM anchor → their weight hints do not change.

**RE-Test-Main reference:** In `workout_entry_screen.dart`, `_actualE1RMForSet(exIdx, setIdx)` reads `_typedOrHintWeightAbs()` (returns the hint weight if no typed value) combined with the user-typed reps, producing a new E1RM regardless of whether weight was typed. This always re-anchors on any value change.

**Required fix — single-line change in `circuit_card.dart`:**
```dart
// BEFORE (line ~539):
if (index == 0 || log.weight != null) {
  final liveE1rm = calculateE1rmSafe(
    weight: log.weight,
    reps: log.reps ?? targetReps,
    rir: log.rir ?? targetRir,
  );

// AFTER:
if (index == 0 || log.weight != null || log.reps != null) {
  final anchorWeight = log.weight ?? result.effectiveWeightKg;
  final liveE1rm = calculateE1rmSafe(
    weight: anchorWeight,
    reps: log.reps ?? targetReps,
    rir: log.rir ?? targetRir,
  );
```

**Behaviour change:**
- If user types reps on Set N (no weight logged): `anchorWeight` = the current effective hint weight for that set; `set1E1rm` = E1RM(hint_weight, new_reps, rir); downstream sets re-anchor from this value.
- If user types weight on Set N: unchanged from current behaviour.
- If neither: condition still fails, `set1E1rm` unchanged (correct).

**Desired behaviour (full spec):**
- Any set edit (weight, reps, or RIR) must propagate downstream to all following sets (set n+1 … last).
- Cascade must **never** propagate upstream — editing set 3 must not change sets 1 or 2.
- Weight edit triggers: already working.
- Reps edit triggers: blocked by this bug.
- RIR edit triggers: already working (via `previousSetRirs`).

**Affected files:** `lib/screens/workout_session/widgets/circuit_card.dart` (single condition change, ~line 539)

**Test cases:** See `app_review.md §5.6`, IDs PC-01 through PC-11. Specifically PC-03 covers the gap scenario.

---

### 1.3 Calendar Auto-Refresh After Logging
**Desired behaviour:**
- After any workout session edit (not just explicit save), the calendar on the home screen must reflect changes immediately without requiring a pull-to-refresh or navigation.
- Planned days and logged days must both update in real time.

**Suggested implementation:**
- Replace polling/snapshot approach with Firestore stream listeners in `TrainingDayService`.
- Or: emit an event/notifier from the session cache when a change is made, and have the calendar subscribe.

**Affected files:** `training_calendar.dart`, `home_screen.dart`, `training_day_service.dart`

---

*Note: §1.3 and §1.4 numbering updated — original §1.3 remains Calendar Auto-Refresh; §1.4 is the cascade bug added from Q2 resolution.*

---

## Tier 2 — Behaviour Corrections

### 2.1 Partial Schedule Regeneration
**Desired behaviour:**
- When a block is edited (exercises, training days, models, rep targets), regeneration applies **only from today (or the first unlogged date) forward**.
- Logged workouts are immutable — they are never overwritten by a schedule regeneration.
- This applies to: adding exercises, removing exercises, changing training days, updating periodization models, changing rep/RIR targets.

**Implementation note:**
- `generateWorkoutMapFromBlock()` needs a `regenerateFrom` date parameter.
- Before writing new schedule entries, query Firestore for logged entries in the block date range and exclude those dates.

**Affected files:** `workout_map.dart`, `block_planning_service.dart`, `planning_pipeline_service.dart`

---

### 2.5 Dynamic Reps Ranges and Rep-Anchored Weight Hints for Sets 2+

**Status:** Not implemented. Confirmed gap via RE-Test-Main comparison (2026-03-28).

**Problem:** The current hint system for Sets 2+ uses `plannedReps` from the schedule as a fixed input. This means:
- Reps hints never reflect what is actually achievable at the previous set's weight
- Neither weight nor reps are shown as ranges
- When a user changes reps on Set 1 (e.g. 3 → 8), Sets 2+ reps hints remain static rather than dynamically adjusting to reflect how many reps are achievable at the same weight with fatigue

**Desired behaviour (from RE-Test-Main `_synthesizeHintsForSet`):**
For every Set N (N ≥ 2) where the user has not typed values:
1. Anchor weight = previous set's effective weight (logged or hinted)
2. Compute `repsNeeded = reverseCalculateReps(targetE1RM_N, anchorWeight, rir)` — how many reps at the previous weight hit this set's fatigue-adjusted target
3. Build `repsRange = {repsNeeded−1, repsNeeded, repsNeeded+1}` (clamped 1–45)
4. Build `weightRange` = valid increment options within ±7.5% of `reverseCalculateWeight(targetE1RM_N, repsNeeded, rir)`, capped at previous set's weight
5. Cross-filter: keep only (reps, weight) pairs where `|E1RM(weight, reps, rir) − targetE1RM_N| ≤ tolKg`
   - `tolKg` = 0.3 for Group D (isolation), 0.7 for all other groups
6. Display: reps as "6–8" (or "6" if collapsed), weight as "90–92.5 kg" (or single value)

**Real example:**
Set 1: 105 kg × 8 reps
- Set 2: `repsNeeded = reverseCalculateReps(targetE1RM_2, 105, rir)` → ~7; shown as **"6–8 reps"**, weight range near 100 kg
- Set 3: `repsNeeded = reverseCalculateReps(targetE1RM_3, Set2_hintWeight, rir)` → ~6; shown as **"6 reps"**, lower weight

**Implementation plan:**

**Step 1 — `SetRangeSynthesiser` service** (`lib/services/set_range_synthesiser.dart`):
```dart
class SetRangeSynthesiser {
  static ({List<int> repsRange, List<double> weightRangeKg}) synthesise({
    required double targetE1rm,
    required double prevSetWeightKg,
    required double rir,
    required List<double> incrementOptions,
    required ExerciseGroup exerciseGroup,
    required bool isBodyweight,
  });
}
```

**Step 2 — Extend `SetHintResult`** (`set_hint_resolver.dart`):
- Add `repsRangeMin`, `repsRangeMax` (int?)
- Add `weightRangeMinKg`, `weightRangeMaxKg` (double?)
- Keep existing `repsHintValue` / `weightHintKg` as single-value fallbacks

**Step 3 — Wire into `_buildSetHints()`** (`circuit_card.dart`):
- For cascade sets (`isCascadeSet == true`), call `SetRangeSynthesiser.synthesise()` using `previous.effectiveWeightKg` as anchor weight
- Populate range fields in `SetHintResult`

**Step 4 — Update `_SetRow` hint display** (`circuit_card.dart`):
- When `repsRangeMin != repsRangeMax`, show "6–8" in the reps hint label
- When `weightRangeMinKg != weightRangeMaxKg`, show "90–92.5" in the weight hint label

**Note on re-anchor fix (§1.4):** The re-anchor fix to `_buildSetHints()` (line 539) handles propagation when the user has already *logged* a value. This feature (§2.5) is the complementary piece — it governs what hints are shown to the user *before* they type anything on downstream sets.

**Affected files:**
- New: `lib/services/set_range_synthesiser.dart`
- Modified: `lib/screens/workout_session/widgets/set_hint_resolver.dart` (extend `SetHintResult`)
- Modified: `lib/screens/workout_session/widgets/circuit_card.dart` (`_buildSetHints`, `_SetRow` hint display)

**Test cases:** `app_review.md §5.6` IDs PC-03, PC-12, PC-13.

---

### 2.2 Block Activation — Explicit
**Desired behaviour:**
- Saving a block from the planner does **not** auto-activate it.
- Activation is a deliberate user action.
- The block planner screen should include an activation toggle or menu item (in addition to the existing control on the blocks list page).

**Affected files:** `block_planner.dart`, `planned_blocks.dart`, `block_planning_service.dart`

---

### 2.3 Block End Popup
**Desired behaviour:**
- When the app is opened and the active block's end date has passed, display a congratulation modal.
- Modal contents:
  - Congratulation message for completing the block.
  - Up to 2 existing blocks listed by nearest start date, each showing:
    - Block name (tappable link → navigates to block planner for review)
    - "Activate" button
  - "Create New Block" option → launches full block planner flow.
- **Confirmed (Q4):** The popup reappears on every app open until the user acts on it. A "Do not show again" checkbox is available for the user to suppress it if desired.

**Affected files:** `home_screen.dart`, new `block_completion_modal.dart`, `block_planning_service.dart`

---

### 2.4 Workout Outside Block Annotation
**Desired behaviour:**
- In the schedule/calendar view, workouts outside the active block's exact date range are annotated:
  - Falls within a block's planned weeks but outside block end date: *"Outside of block"*
  - Is an ad-hoc workout with no block: *"Outside of block"* (or *"Ad-hoc"*)
  - Is part of a different named block: show that block's name as a label
- This annotation appears on the day card / schedule entry, not as a blocking UI.

**Affected files:** `training_calendar.dart`, `week_schedule_tab.dart`, `training_day_service.dart`

---

## Tier 3 — Calculation & Defaults Engine

This tier ports the calculation system documented in `RE-Test-Main_Functional_Design.md` and `RE-Test-Main_Calculation_Scenarios.md` into the main codebase. Some pieces already exist (`hint_resolver.dart`, `exercise_default_settings.dart`, `block_exercise_defaults_repository.dart`); the gaps and wiring are described below.

---

### 3.1 E1RM Calculation (Brzycki / Epley)
**Status:** Partially implemented in `models/utils/e1rm_helpers.dart`. Verify the Brzycki ≤ 25 / Epley > 25 switch matches the spec.

**Spec (from RE-Test-Main_Functional_Design.md §1.1–1.3):**
- `calculateE1RM(weight, reps, rir)` — totalReps = reps + rir
- `reverseCalculateWeight(targetE1RM, reps, rir)`
- `reverseCalculateReps(targetE1RM, weight, baseWeight, rir, minReps)` — with minReps guard

---

### 3.2 History-Based E1RM Priority System
**Status:** Not yet in main branch. Lives in RE-Test-Main.

**Spec (from RE-Test-Main_Functional_Design.md §2.1):**
`computeBaseE1RMFromHistory()` uses a 6-level priority:
| Priority | Source | Condition |
|---|---|---|
| A | `recent_match` | Within 28 days, effectiveReps within ±0.5 of target |
| B | `two_week_avg` | Average of all entries within 14 days |
| C | `last4_avg` | Average of last 4 entries if ≥4 exist |
| D | `recent_any_avg` | Average of 1-3 recent entries |
| E | `maxWeightByReps` | Fallback to max weight by reps record |
| F | `no_history` | Returns null |

**Input:** exercise name, repTarget, plannedRIR, topSetHistory, maxWeightByReps, now
**Output:** `{ baseE1RM, baseSource, nUsed, usedSamples }`

**Requires:** A queryable history source — see §3.6 (Global PR/Bests Store).

---

### 3.3 Default Weight by Equipment Type
**Status:** Partially in `ExerciseDefaultSettings` but equipment-type logic incomplete.

**Spec (from RE-Test-Main_Functional_Design.md §3.1–3.2):**
- `_getExerciseTypeForName(name)` — primary lookup from `exerciseTypeById` map, fallback to name-contains 'barbell'
- `_defaultWeightForExercise(name)`:
  - Barbell Overhead Press / contains 'overhead press' → 10 kg
  - Other Barbell → 20 kg
  - Everything else → 5 kg

**Needs extension to cover:** Dumbbell, Cable, Machine, Bodyweight (see §3.5).
**Recommended approach:** Add Tier 2.5 to `ExerciseDefaultSettings` — after named, before category — for equipment type.

| Equipment | Default Weight |
|---|---|
| Barbell OHP | 10 kg |
| Barbell (other) | 20 kg |
| Dumbbell | 10 kg |
| Cable | 10 kg |
| Machine | 30 kg |
| Bodyweight | 0 kg (added weight) |
| Other | 5 kg |

---

### 3.4 Set Cascade Hints (Following Sets)
**Status:** Not yet in main branch (exists in RE-Test-Main `workout_entry_screen.dart`).

**Spec (from RE-Test-Main_Functional_Design.md §7):**
- Exercises grouped A/B/C/D by name and category.
- E1RM drops per set index, gated by previous set's RIR:
  - RIR > 2.0 → 0% drop
  - RIR 1.8–2.0 → 80% of base drop
  - RIR < 1.8 → 100% of base drop
- Drop table (base E1RM kg per set 2+):

```
Group       | Set 2 | Set 3 | Set 4+
A (heavy)   | 5.5   | 5.5   | 5.5
B (overhead)| 1.5   | 4.3   | 1.5
C (compound)| 1.0   | 1.0   | 1.0
D (isolation)| 0.3  | 0.3   | 0.3
```

- Weight hint: ±7.5% window around mid weight
- Reps hint: repsMid ± 1

**Confirmed (Q2):** Cascade is real-time (on every keystroke). Propagates downstream from the edited set only — never upstream. Triggers on weight change, rep change, and RIR change. Reference: RE-Test-Main §7 for full implementation.

**Affected files:** New `set_cascade_service.dart`, `circuit_card.dart`, `workout_session_screen.dart`

---

### 3.5 Bodyweight Exercise Handling
**Status:** `toAbsoluteWeight()` / `toDisplayAddedWeight()` referenced in RE-Test-Main; unclear if in main branch.

**Spec:**
- `isBodyweightExercise(id, name)` — lookup by ID or lowercased name
- Display weight = added weight (e.g., +10kg vest)
- Absolute weight = bodyweight + added weight
- Uses historical bodyweight data keyed by date

**Requires:** A bodyweight history query function (already exists in `WeightScreen`/`weight_controller.dart`?)

---

### 3.6 Global PR / Bests Store
**Status:** Not built. Currently PRs and history exist only within block/workout context.

**Desired structure:**
- `users/{uid}/bests/{exerciseId}` — top set records per exercise
- Fields: `maxE1rm`, `maxWeightAtReps` (map of reps→weight), `topSetHistory` (list of recent top sets), `lastUpdated`
- Updated whenever a workout is logged (via `WorkoutLogService`)
- Read by `computeBaseE1RMFromHistory()` for hint generation

**This is a prerequisite for §3.2.**

**Confirmed (Q1):** `topSetHistory` fed to `computeBaseE1RMFromHistory()` is read from `bests/{exerciseId}`, not scanned from `workouts/`. Other fallback tiers in the priority chain remain as currently built.

---

### 3.7 Weight Increment Rounding
**Status:** `roundToIncrement()` exists in `weight_hint_helper.dart`. Verify it matches the RE-Test-Main spec (primary + secondary increments, valid options set).

**Spec:** Primary + secondary increment options; find nearest in generated options set.

---

## Tier 4 — New Features

### 4.1 Ad-Hoc Workout Support
**Desired behaviour:**
- Any empty calendar day (tapped) or "Start Workout" hero card opens the workout entry screen for that date.
- No block/schedule association required.
- Hint values are driven by the full defaults hierarchy: named exercise → equipment type → category → historical.
- The session state cache (§1.1) applies equally to ad-hoc sessions.
- Ad-hoc workouts are stored in `users/{uid}/workouts/{timestamp}` with no `blockId`.

**Requires:** §3.2 and §3.6 for history-based hints.

---

### 4.2 Template Versioning
**Desired behaviour:**
- When a template is edited, the current version is archived before the edit is saved.
- Archive location: `users/{uid}/templates/{templateId}/versions/{versionNumber}`
- Each version stores: full snapshot of exercises/sets, `editedAt` timestamp, `version` number.
- A "Version History" screen accessible from the template detail shows all versions in reverse chronological order (full snapshot per version, no diff required initially).
- Existing schedule/workout entries that reference a template record the template version at time of generation.

**Confirmed (Q3):** Version history screen is only shown once the template has been edited at least once. A new version is only created if the template has previously been used in a block or workout — if the template is unused/draft, edits overwrite in place with no version created.

**Affected files:** `template_library.dart`, new `template_version_service.dart`, new `template_history_screen.dart`

---

### 4.3 Template Orphan Handling
**Desired behaviour:**
- When a block is deleted, its associated templates are **not** deleted.
- Their `blockId` field is set to `null` and an `unassigned: true` flag is added.
- The Templates screen shows an "Unassigned Templates" section for these.

**Affected files:** `block_planning_service.dart`, `template_library.dart`, `templates_screen.dart`

---

### 4.4 Block Planner "Group by Templates"
**Desired behaviour:**
- Add "Templates" as an option in the block planner group-by selector.
- When selected, exercises are grouped under their assigned template name.
- Exercises not assigned to any template appear under an "Unassigned" header.

**Affected files:** `block_planner.dart`, `week_schedule_tab.dart`

---

### 4.5 Flexible Block Count
**Desired behaviour:**
- Remove all hardcoded assumptions of exactly 3 blocks from onboarding, bootstrap, and schedule logic.
- Template bootstrap should trigger once per block as it is created, not require a count of 3.
- A user may have 0, 1, 2, or many blocks.

**Affected files:** `template_bootstrapper.dart`, `home_screen.dart`, `create_new_account_screen.dart`

---

### 4.6 Bidirectional Cache / Firestore Sync
**Desired behaviour:**
- On load, compare `updatedAt` timestamp of local cache vs. Firestore document.
- If Firestore is newer → update local cache.
- If local cache is newer → push local to Firestore (user may have been offline and made changes locally).
- If equal → use local (no round trip needed).

**Confirmed (Q5):** Most recent `updatedAt` wins at document level. **Exception:** Coach-driven changes take priority over user changes in conflict scenarios. Implementation must track `lastEditedBy` (user vs coach) on schedule/block documents. If Firestore has a coach-authored change, it wins regardless of local timestamp.

**Affected files:** `schedule_parser.dart`, `weekly_schedule_service.dart`, `workout_session_cache.dart` (new)

---

## Dependencies & Build Order

```
3.6 (Global Bests Store)
  └→ 3.2 (History E1RM)
       └→ 3.3 (Equipment Defaults) ─┐
       └→ 3.4 (Set Cascade)         ├→ 4.1 (Ad-Hoc Workouts)
       └→ 3.5 (Bodyweight)  ────────┘
  └→ 1.1 (Session Cache)
       └→ 1.3 (Calendar Refresh)
       └→ 4.6 (Bidirectional Sync)

2.1 (Partial Regeneration) ─→ 2.2 (Block Activation) ─→ 2.3 (Block End Popup)

4.2 (Template Versioning) ─→ 4.3 (Orphan Handling) ─→ 4.4 (Group by Templates)
```

---

## Open Questions

All Q1–Q5 resolved. No remaining open questions as of 2026-03-28.

---

## Build Order (updated)

```
3.6 (Global Bests Store)
  └→ 3.2 (History E1RM — reads bests collection)
       └→ 3.3 (Equipment Defaults)  ─┐
       └→ 1.4 / 3.4 (Set Cascade)   ├→ 4.1 (Ad-Hoc Workouts)
       └→ 3.5 (Bodyweight)   ────────┘

1.1 (Session Cache)
  └→ 1.3 (Calendar Refresh)
  └→ 4.6 (Bidirectional Sync — add lastEditedBy / coach priority)

2.1 (Partial Regeneration)
  └→ 2.2 (Block Activation control in planner)
  └→ 2.3 (Block End Popup)

4.2 (Template Versioning — used/unused gate)
  └→ 4.3 (Orphan Handling)
  └→ 4.4 (Group by Templates in planner)

4.5 (Flexible Block Count) — independent
```

---

*End of plan.*
