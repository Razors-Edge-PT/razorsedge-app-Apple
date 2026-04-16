# Calculation Engine — Test Cases

## Test Setup

**Account state:** Fresh account, no workout history.

**Onboarding best effort entries:**

| Exercise | Weight | Reps | RIR assumed |
|---|---|---|---|
| Bench Press, Barbell | 120 kg | 1 | 0 |
| Back Squat, Barbell | 130 kg | 1 | 0 |
| Chin-Up | 125 kg | 2 | 0 |
| Deadlift, Conventional | 140 kg | 1 | 0 |

---

## Reference Calculations

### E1RM from onboarding entries

Formula: `E1RM = weight × 36 / (37 − (reps + RIR))`

| Exercise | Calc | Expected E1RM |
|---|---|---|
| Bench Press, Barbell | 120 × 36/36 | **120.0 kg** |
| Back Squat, Barbell | 130 × 36/36 | **130.0 kg** |
| Deadlift, Conventional | 140 × 36/36 | **140.0 kg** |
| Chin-Up | 125 × 36/35 | **128.6 kg** |

### Ad-hoc session parameters (first session, DUE model)

- `weekIndex = 0`, `exposureIndex = 0`, `frequencyPerWeek = 3`
- **Rep target: 12**, **RIR: 2.0** ← DUE pattern[0] for freq=3
- `effectiveReps = 12 + 2.0 = 14`

### Base weight formula

`base = E1RM × (37 − 14) / 36 = E1RM × 23/36 = E1RM × 0.6389`

| Exercise | Base weight | Snap to 2.5 | + 5 increments (smart) | Expected hint |
|---|---|---|---|---|
| Bench Press, Barbell | 76.7 kg | 77.5 kg | +12.5 → 89.2 | **~90.0 kg** |
| Back Squat, Barbell | 83.1 kg | 82.5 kg | +12.5 → 95.6 | **~95.0 kg** |
| Deadlift, Conventional | 89.4 kg | 90.0 kg | +12.5 → 101.9 | **~102.5 kg** |
| Chin-Up | 82.1 kg | 82.5 kg | +12.5 → 94.6 | **~95.0 kg** |

> **Note on smart progression with no history:** When there is no prior session data, the scoring algorithm biases toward +5 increments above base. Expected hints sit between base weight and base + 5 × 2.5 kg. Any value in that range is a pass.

### Cascade sets — RIR gate

At RIR 2.0 the cascade gate returns **0 drop** (gate activates at RIR < 1.8). All three sets show identical weight/reps for a fresh account. Sets 2 and 3 become non-identical only after sessions with RIR < 1.8 are recorded.

---

## TC-01 — Exercise Detail Screen: Keystone Best Set Display

**How to test:** Open each exercise detail screen for the exercises below.

**Pass criteria:** Best Set field is visible and shows a value. E1RM matches reference above.

| # | Exercise | Expected best set display | Expected E1RM | Actual  | Pass |
|---|---|---|---|---------|---|
| 01a | Bench Press, Barbell | 120 × 1 | 120.0 kg | 120 × 1 | |
| 01b | Back Squat, Barbell | 130 × 1 | 130.0 kg | 130 × 1 | |
| 01c | Deadlift, Conventional | 140 × 1 | 140.0 kg | 140 × 1 | |
| 01d | Chin-Up | 125 × 2 | 128.6 kg | 125 × 2 | |

---

## TC-02 — Exercise List: Keystone Best Set Line

**How to test:** Open the exercise list and locate each exercise below.

**Pass criteria:** A best set line is visible in the tile subtitle (no calculator icon — these are recorded values, not calculated).

| # | Exercise | Expected subtitle line | Actual  | Pass |
|---|---|---|---------|---|
| 02a | Bench Press, Barbell | 120 × 1 | 120 × 1 | |
| 02b | Back Squat, Barbell | 130 × 1 | 130 × 1 | |
| 02c | Deadlift, Conventional | 140 × 1 | 140 × 1 | |
| 02d | Chin-Up | 125 × 2 | 125 × 2 | |

---

## TC-03 — Exercise List: Related Exercise Calculated Values

These exercises inherit onboarding seeds via the `_keystoneLiftKey` mapping.

**Pass criteria:** A best set line is visible with a **calculator icon** (calculated label). Value should be plausible relative to the keystone E1RM.

| # | Exercise | Seed source | Expected E1RM range | Actual | Pass |
|---|---|---|---|------|---|
| 03a | Incline Bench Press, Barbell | bench_barbell (120) | ~120 kg | null | |

> **Known gap:** Non-mapped exercises (e.g. Close Grip Bench, Romanian Deadlift, Dumbbell exercises) have no onboarding seed and no history → no calculated value shown. This is expected for now.

---

## TC-04 — Ad-Hoc Workout: Keystone Exercises

**How to test:** Create a new ad-hoc workout. Add each exercise below. Observe the per-set hints (weight / reps / RIR).

**Pass criteria:**
1. Weight hint is **not 20 kg** — confirms onboarding seed reached the engine.
2. Weight is within the expected range for that exercise (base weight to base + 12.5 kg).
3. Reps = 12, RIR = 2.0 for all sets.
4. All three sets show identical hints (RIR gate at 2.0 → zero cascade drop).

| # | Exercise | Expected weight range | Exp. reps | Exp. RIR | Set 1 actual | Set 2 actual | Set 3 actual | Pass |
|---|---|---|---|---|-------------|------|------|---|
| 04a | Bench Press, Barbell | 77.5 – 90.0 kg | 12 | 2 | 88.75 x 12 x 2 ✓ | retest | retest | |
| 04b | Back Squat, Barbell | 82.5 – 95.0 kg | 12 | 2 | 20 ✗ → fixed (liftKey 'squat'→'back_squat') | retest | retest | |
| 04c | Deadlift, Conventional | 90.0 – 102.5 kg | 12 | 2 | 102.5 x 12 x 2 ✓ | retest | retest | |
| 04d | Chin-Up | 82.5 – 95.0 kg | 12 | 2 | 95 x 12 x 2 ✓ | retest | retest | |
| 04e | Incline Bench Press, Barbell | 77.5 – 90.0 kg | 12 | 2 | 20 ✗ → retest | retest | retest | |

---

## TC-05 — Ad-Hoc Workout: Non-Keystone Exercises (Known Gap)

**How to test:** Add exercises not in TC-04 — e.g. Romanian Deadlift, Dumbbell Bench Press, Cable Row.

**Expected behavior:** Falls back to **20 kg × 12 @ RIR 2** because no history and no onboarding seed mapping exists for these exercises.

| # | Exercise | Expected weight | Actual weight | Note |
|---|---|---|----|---|
| 05a | Romanian Deadlift | 20 kg (fallback) | 20 | Known gap |
| 05b | Dumbbell Bench Press | 20 kg (fallback) | 20 | Known gap |
| 05c | Lat Pull Down, Supinated | 20 kg (fallback) | 20 | Known gap |
| 05d | _(add others)_ | 20 kg (fallback) | 20 | |

---

## TC-06 — Block Planner: Exercise Details Best Set

**How to test:** Open block planner → select a block → tap an exercise to view its details card.

**Pass criteria:** Best weight × reps field is populated for keystone exercises.

| # | Exercise | Expected best set | Actual | Pass |
|---|---|---|------|---|
| 06a | Bench Press, Barbell | 120 × 1 | null | |
| 06b | Back Squat, Barbell | 130 × 1 | null | |
| 06c | Deadlift, Conventional | 140 × 1 | null | |
| 06d | Chin-Up | 125 × 2 | null | |
| 06e | Non-keystone exercise | blank | null | |

---

## TC-07 — Block Schedule: Set Hints

**How to test:** Open the schedule / week view for a block. Tap a scheduled workout for a keystone exercise.

**Pass criteria:**
1. Rep and RIR values shown match the scheduled plan (periodization-correct, not overridden by engine).
2. Weight hint is shown and is **not blank / not 20 kg** for keystone exercises.
3. Non-keystone exercises may show 20 kg until workout history exists (known gap).

| # | Exercise | Expected reps (from plan) | Expected RIR (from plan) | Expected weight (non-20) | Actual reps | Actual RIR | Actual weight | Pass |
|---|---|---|---|---|------|------|------|---|
| 07a | Bench Press, Barbell | per block plan | per block plan | 77.5 – 90.0 kg | null | null | null | |
| 07b | Back Squat, Barbell | per block plan | per block plan | 82.5 – 95.0 kg | null | null | null | |
| 07c | Deadlift, Conventional | per block plan | per block plan | 90.0 – 102.5 kg | null | null | null | |
| 07d | Chin-Up | per block plan | per block plan | 82.5 – 95.0 kg | null | null | null | |
| 07e | Non-keystone exercise | per block plan | per block plan | ~20 kg (fallback) | null | null | null | |

---

## TC-08 — Post-Session Progression (Follow-up Test)

**Purpose:** Verify that after logging a session, the next hint improves.

**How to test:** Log one full session for Bench Press (e.g. 3 sets × 90 kg × 12 @ RIR 2). Then create a new ad-hoc session and add Bench Press.

**Pass criteria:**
1. New hint weight ≥ previous session weight (smart progression detects logged data).
2. The 20 kg fallback does not reappear.

| Field | Previous session | New hint | Pass |
|---|---|---|---|
| Weight | 90 kg | ≥ 90 kg | |
| Reps | 12 | 12 | |
| RIR | 2.0 | 2.0 | |

---

## TC-09 — Cascade Drop After Hard Session (Follow-up)

**Purpose:** Verify cascade sets drop when RIR < 1.8 is logged.

**How to test:** Log a hard set for Bench Press (e.g. 100 kg × 8 @ RIR 1.0). Then add Bench to a new ad-hoc session.

**Pass criteria:** Set 2 weight < Set 1 weight (cascade drop active below RIR 1.8).

| Set | Expected weight | Actual | Pass |
|---|---|---|---|
| Set 1 | engine-derived | | |
| Set 2 | Set 1 − ~7 kg E1RM equivalent | | |
| Set 3 | Set 1 − ~10.5 kg E1RM equivalent | | |

---

## Known Gaps (Not Failures)

| Gap | Affected tests | Status |
|---|---|---|
| Non-keystone exercises always fall back to 20 kg for fresh accounts | TC-05, TC-07e | Expected — no scaling from keystone to related exercises yet |
| Chin-Up weight display may show added weight or total body weight — verify display format | TC-04d | UX verification needed |
| Block schedule weight hints require the engine to load async — brief delay before hints appear | TC-07 | Expected — partial metadata hints show during load |