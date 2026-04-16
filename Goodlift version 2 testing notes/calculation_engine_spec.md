# Calculation Engine & Hint Text Specification
## REClaude — RE-Test-Main Reference Implementation

**Audience**: Two simultaneous audiences — wiki-level prose for documentation readers, and precise pseudocode for engineers reimplementing the engine from scratch.

**Scope**: Everything that produces "reasonable exercise values" in the workout UI: E1RM formulas, periodization models, progression logic, fatigue cascade, and the full hint-text pipeline.

**Source files analysed**:
- `periodization_model_utils.dart` (PMU) — 3,978 lines — core calculation engine
- `progression_engine.dart` (PE) — 968 lines — callback-driven engine wrapper
- `workout_entry_screen.dart` (WES) — 18,063 lines — hint text display and set entry UI
- `week_planner.dart` (WP) — 2,570 lines — week planning grid and Firestore structure

---

> **Architectural note — Exercise Library as Source of Truth**
>
> RE-Test-Main was built around block-driven workouts, and the upper tiers of the hint cascade
> (Sections 7–8) assume a pre-generated schedule exists. The rebuild targets a broader contract:
>
> **The exercise library defaults are the source of truth for hint generation in any workout.**
> Block planning *inherits* these defaults and may override them per cycle; those overrides are
> local to the cycle and do not change the library defaults. An ad-hoc (unplanned) workout
> receives the same hint quality as a block workout — the engine computes `calculatedWeight`,
> `calculatedReps`, and `calculatedRir` on the fly from exercise library defaults + history
> rather than reading pre-embedded schedule values.
>
> Concretely:
> - `users/{uid}/exerciseDefaults/{exerciseName}` — library defaults (increment, sets, rep range,
>   periodization/RIR/progression models). Source of truth for all workouts.
> - `users/{uid}/blocks/{blockId}.plannedExerciseDetails` — per-cycle overrides. Seeded from
>   library defaults; may diverge for a specific block without affecting library defaults.
> - Hint tier resolution in any session (see Section 7):
>   1. User-typed value
>   2. Pre-computed schedule value (block workouts only, when schedule exists)
>   3. On-the-fly computed value from library defaults + E1RM history (all workouts)
>   4. Raw history fallback (all workouts)
>
> Sections 7 and 8 describe RE-Test-Main's schedule-driven implementation. Where the rebuild
> deviates to implement on-the-fly computation for ad-hoc workouts, this is the intended
> behaviour, not a simplification.

---

## Table of Contents

1. [E1RM — Estimated One-Rep Max](#1-e1rm)
2. [ExerciseGroup Classification](#2-exercisegroup-classification)
3. [RIR Models](#3-rir-models)
4. [Periodization Models](#4-periodization-models)
5. [Progression Engine](#5-progression-engine)
6. [Fatigue / Cascade Sets (Backoff Sets)](#6-fatigue--cascade-sets)
7. [Hint Text Pipeline](#7-hint-text-pipeline)
8. [Schedule Generation Integration](#8-schedule-generation-integration)
9. [Recommendations for Clean Rebuild](#9-recommendations-for-clean-rebuild)

---

## 1. E1RM

### 1.1 Purpose

The E1RM (Estimated One-Rep Max) is the single currency of the entire engine. Every weight suggestion starts from a historical E1RM, and every hint weight is derived by inverting the formula.

### 1.2 Forward Calculation — `calculateE1RM`

**Formula selection rule**: Brzycki for effective reps ≤ 25; Epley for effective reps > 25.

**Effective reps** = reps + RIR (both non-null, non-negative; function returns 0 on bad input).

The threshold comparison is done on a value rounded to 4 decimal places to avoid float-edge false branches:

```
function calculateE1RM(weight, reps, rir):
    if weight == null or weight <= 0: return 0
    if reps == null or reps <= 0:    return 0
    r = reps  (coerce to double)
    rValue = rir ?? 0.0
    w = weight

    effectiveReps = round(r + rValue, decimals=4)

    if effectiveReps <= 25.0:
        return w * (36 / (37 - effectiveReps))    // Brzycki
    else:
        return w * (1 + 0.0333 * effectiveReps)   // Epley
```

**Boundary behaviour**: At exactly 25 effective reps both formulas give identical results (≈ 2.38×weight). The 4-decimal rounding prevents 24.99999 floating-point artifacts from accidentally crossing the branch.

### 1.3 Reverse Calculations

#### 1.3.1 `reverseCalculateWeight`

Given a target E1RM and a rep+RIR target, solve for the weight that would hit that E1RM.

```
function reverseCalculateWeight(targetE1RM, reps, rir):
    if targetE1RM <= 0: return 0
    totalReps = reps + (rir ?? 0)
    totalReps = round(totalReps, decimals=4)

    if totalReps <= 25:
        return targetE1RM * ((37 - totalReps) / 36)    // inverse Brzycki
    else:
        return targetE1RM / (1 + 0.0333 * totalReps)   // inverse Epley
```

#### 1.3.2 `reverseCalculateReps`

Given a target E1RM and a known weight, solve for the rep count.

```
function reverseCalculateReps(targetE1RM, weight, rir, minReps=null):
    if targetE1RM <= 0 or weight <= 0: return null

    rirVal = rir ?? 0.0

    // Try Brzycki branch first (valid when answer <= 25)
    // Brzycki: e1rm = w * 36 / (37 - totalReps)
    //   => totalReps = 37 - 36*w/e1rm
    brzyckiEffective = 37 - (36 * weight / targetE1RM)
    brzyckiReps = brzyckiEffective - rirVal

    if brzyckiEffective <= 25 and brzyckiReps >= 1:
        result = brzyckiReps
    else:
        // Epley: e1rm = w * (1 + 0.0333 * totalReps)
        //   => totalReps = (e1rm/w - 1) / 0.0333
        epleyEffective = (targetE1RM / weight - 1) / 0.0333
        result = epleyEffective - rirVal

    result = clamp(result, 1.0, 45.0)

    // Bodyweight guard: if this is a BW exercise and minReps is provided
    if minReps != null and result < minReps:
        result = minReps.toDouble()

    return result
```

### 1.4 Base E1RM from History — `computeBaseE1RMFromHistory`

This function selects the historical E1RM to use as the progression anchor. It implements a 5-tier priority cascade, falling back to weaker evidence as better evidence is unavailable.

**Inputs**:
- `exerciseId` — Firestore exercise document ID
- `repTarget` — intended rep count for Set 1
- `rir` — intended RIR for Set 1
- `currentDateYmd` — today as `"YYYY-MM-DD"` string
- `workoutHistory` — list of past workout docs

**Tier priority** (highest to lowest):

```
Tier 1 — Recent rep-match (within ~14 days):
    Find the most recent workout entry where:
        abs(entry.reps - repTarget) <= 1
        entry.date within last 14 days
    Use calculateE1RM(entry.weight, entry.reps, entry.rir)

Tier 2 — 2-week rolling average (same rep range):
    All entries within 14 days matching rep range ±1
    baseE1RM = mean of their E1RMs

Tier 3 — Last-4 average (same rep range, any date):
    Last 4 entries matching rep range ±1
    baseE1RM = mean of their E1RMs

Tier 4 — Global average (any rep count):
    All history entries
    baseE1RM = mean of all E1RMs

Tier 5 — maxWeightByReps fallback:
    exercisePreviousTopSetReps[exerciseId][repTarget]
    If found: baseE1RM = calculateE1RM(topSetWeight, repTarget, 0)
    This is populated from WeekPlanner's loadTopSetsFromWorkouts.

If all tiers fail: return null (caller falls back to default weight table)
```

---

## 2. ExerciseGroup Classification

### 2.1 Purpose

ExerciseGroup determines how much E1RM drops between consecutive sets in the same circuit (the fatigue cascade). There are four groups: A, B, C, D.

### 2.2 Classification Priority

```
function _resolveGroupForExercise(exerciseId, exerciseName):
    // Priority 1: explicit name override table (case-insensitive)
    if exerciseName in _groupNameOverrides:
        return _groupNameOverrides[exerciseName]

    // Priority 2: category from Firestore exercise doc
    category = fetchExerciseCategory(exerciseId)  // e.g. "Legs", "Core"
    if category in _groupCategoryMap:
        return _groupCategoryMap[category]

    // Default
    return ExerciseGroup.B
```

### 2.3 Group Membership

#### Group A — Largest compound movements (highest fatigue)
Name overrides (partial list):
- Squat (Barbell), Back Squat, Front Squat
- Deadlift, Romanian Deadlift, Sumo Deadlift
- Bench Press (Barbell), Incline Bench Press (Barbell)
- Overhead Press (Barbell)
- Barbell Row, Pendlay Row

Categories that map to A: `Legs (Barbell)`, `Chest (Barbell)`, `Back (Barbell)`, `Shoulders (Barbell)`

#### Group B — Secondary compound and machine movements
Name overrides:
- Leg Press, Hack Squat, Bulgarian Split Squat
- Dumbbell Bench Press, Cable Fly, Lat Pulldown
- Seated Row (Cable), Face Pull
- Most dumbbell compounds

Categories: `Chest (Dumbbell/Cable)`, `Back (Cable/Machine)`, `Legs (Machine/Dumbbell)`

#### Group C — Single-joint isolation movements
Name overrides:
- Bicep Curl (Barbell/Dumbbell/Cable)
- Tricep Pushdown, Overhead Tricep Extension
- Lateral Raise (Dumbbell/Cable)
- Leg Extension, Leg Curl

Categories: `Arms`, `Shoulders (Isolation)`, `Legs (Isolation)`

#### Group D — Minimal fatigue (core, carries, accessories)
Name overrides:
- Plank, Dead Bug, Ab Wheel
- Farmer's Walk, Suitcase Carry
- Face Pull (if not already B), Rear Delt Fly

Categories: `Core`, `Carries`

### 2.4 E1RM Drop Constants per Group (per-set drop in kg·E1RM units)

```
_rawDropFor(group, setIndex):
    // setIndex = 0-based position AFTER set 1 (i.e., the drop INTO this set)
    drops = {
        A: [7.0, 10.5, 13.5, 16.0, 18.0, 19.5, 20.5],   // sets 2..8
        B: [5.0,  8.0, 10.5, 12.5, 14.0, 15.0, 15.5],
        C: [3.5,  5.5,  7.5,  9.0, 10.0, 10.5, 10.5],
        D: [2.0,  3.5,  5.0,  6.5,  7.5,  8.0,  8.0],
    }
    return drops[group][min(setIndex-1, 6)]   // setIndex 1..7 → array index 0..6
```

Note: these are *cumulative* drops from Set 1's E1RM, not incremental between adjacent sets.

---

## 3. RIR Models

### 3.1 RIR Plan Storage Format

RIR targets are stored in the block planner under `plannedExerciseDetails`:

```
plannedExerciseDetails[exerciseId]['rirPlan'] = {
    'week_0': {                    // week_0 = applies to all weeks (catch-all)
        'session_0': {             // session_0 = first session of exercise
            'set_0': { 'rir': 2.0 },   // set_0 = Set 1
            'set_1': { 'rir': 2.0 },   // set_1 = Set 2
            ...
        },
        'session_1': { ... },
    },
    'week_1': { ... },             // week-specific override
}
```

Week keys: `'week_0'` through `'week_N'`. Week 0 is the universal fallback.
Session keys: `'session_0'` through `'session_N'` — ordered by day of week.
Set keys: `'set_0'` through `'set_7'`.

### 3.2 `getRirFromPlanOrInput` — Full Resolution Chain

```
function getRirFromPlanOrInput(exerciseId, setIndex, weekIndex, sessionIndex,
                                resolvedBB2Values, plannedExerciseDetails):
    // Step 1: BB2 override (block planner explicit value)
    bb2 = resolvedBB2Values[exerciseId]
    if bb2 != null and bb2['rir'] != null:
        return bb2['rir'].toDouble()

    // Step 2: rirPlan lookup
    plan = plannedExerciseDetails[exerciseId]?['rirPlan']
    if plan != null:
        // Try exact week first, fall back to week_0
        weekKey = 'week_$weekIndex'
        sessKey = 'session_$sessionIndex'
        setKey  = 'set_$setIndex'

        weekData = plan[weekKey] ?? plan['week_0']
        if weekData != null:
            sessData = weekData[sessKey] ?? weekData['session_0']
            if sessData != null:
                setData = sessData[setKey]
                if setData?['rir'] != null:
                    return setData['rir'].toDouble()

    // Step 3: model-based default
    return getSet1RirByModel(exerciseId, weekIndex, periodizationModel)
```

### 3.3 `getSet1RirByModel` and `getSet1RirForExercise`

`getSet1RirByModel` reads from `modelSpecificRepTargets` (stored in `plannedExerciseDetails`) or falls back to hardcoded model defaults:

```
Model defaults for RIR (Set 1, various weeks):
    linearClassic:           week 1-3: 3.0, week 4-6: 2.0, week 7+: 1.0
    linearExposure:          same pattern as linearClassic
    dailyUndulatingWeek:     3.0 (uniform; rep variation provides intensity change)
    dailyUndulatingExposure: per-session, from rirPlan or default 2.0
    dupSignature:            2.0 (overridden per-week in rirPlan)
```

`getSet1RirForExercise` is the same but adds a session-rotation offset: when an exercise appears multiple times per week, alternate RIR values to create within-week variation.

---

## 4. Periodization Models

### 4.1 Overview

Five models are supported. The model is stored per exercise in `plannedExerciseDetails[exerciseId]['periodizationModel']`.

| Model Enum | Display Name |
|---|---|
| `dailyUndulatingExposure` | DUP by Exposure |
| `dailyUndulatingWeek` | DUP by Week |
| `linearClassic` | Linear Classic |
| `linearExposure` | Linear by Exposure |
| `dupSignature` | RE Signature (DUP Signature) |

### 4.2 DUP by Exposure (`dailyUndulatingExposure`)

Each *exposure* (session) within a week has a different rep target. The target is looked up by exposure index (0-based order of the exercise sessions in the week).

```
getSuggestedRepTargetByModel(exerciseId, weekIndex, exposureIndex, model):
    // model = dailyUndulatingExposure
    repOptions = plannedExerciseDetails[exerciseId]['dupExposureReps']
                 ?? getDefaultDupExposureReps(frequencyPerWeek)
    return repOptions[exposureIndex % repOptions.length]
```

Default DUP exposure rep patterns by frequency:
- 1×/week: [8]
- 2×/week: [12, 6]
- 3×/week: [12, 8, 5]
- 4×/week: [15, 10, 8, 5]
- 5×/week: [15, 12, 10, 8, 5]

### 4.3 DUP by Week (`dailyUndulatingWeek`)

Rep target changes each *week* (not each session). All sessions in a given week use the same rep target.

```
// week_reps = plannedExerciseDetails[exerciseId]['weeklyReps'] (list)
// Falls back to cycling default pattern
repTarget = weeklyReps[weekIndex % weeklyReps.length]
```

Default weekly cycling pattern: [12, 10, 8, 6, 12, 10, 8, 6, ...]

### 4.4 Linear Classic (`linearClassic`)

Reps decrease by a fixed amount each mesocycle phase, weight increases to compensate.

```
Phase map (0-indexed week → rep target):
    weeks 0-3:  repTarget = baseReps           (e.g. 12)
    weeks 4-7:  repTarget = baseReps - 2       (e.g. 10)
    weeks 8-11: repTarget = baseReps - 4       (e.g. 8)
    weeks 12+:  repTarget = baseReps - 6       (e.g. 6, minimum 3)
```

`baseReps` is stored in `plannedExerciseDetails[exerciseId]['defaultReps']`, defaulting to 12.

### 4.5 Linear by Exposure (`linearExposure`)

Same rep ladder as Linear Classic, but tracks *exposures* rather than calendar weeks. An exposure is one completed session of the exercise.

```
exposureCount = count of completed sessions for exerciseId
phase = exposureCount // sessionsPerPhase   // integer division
repTarget = baseReps - (phase * 2)
repTarget = max(repTarget, 3)
```

`sessionsPerPhase` defaults to 4.

### 4.6 RE Signature (`dupSignature`)

The most complex model. Generates a cycle-based undulating rep sequence that avoids recently-used rep ranges and maximises variety across the training block.

#### 4.6.1 `getDupSignatureRepTarget`

Entry point for scheduled rep targets (used in WeekPlanner display):

```
function getDupSignatureRepTarget(exerciseId, weekIndex, dayIndex, rirPlan):
    // Look up pre-computed rep sequence stored in block planner
    sequence = plannedExerciseDetails[exerciseId]['repSequence']
    if sequence == null:
        sequence = REsignatureRepTargets(exerciseId, weekCount, frequencyPerWeek)
    sessionIndex = weekIndex * frequencyPerWeek + dayIndex
    return sequence[sessionIndex % sequence.length]
```

#### 4.6.2 `REsignatureRepTargets` — Cycle-Based Undulating Sequence

Generates a sequence of rep targets that:
1. Covers the full rep range spectrum (e.g. 4-20 reps)
2. Avoids using the same rep group twice in a short window
3. Maximises distance from recently-used rep groups

```
REP_GROUPS = [
    [4,5],    // group 0: very heavy
    [6,7],    // group 1: heavy
    [8,9],    // group 2: moderate-heavy
    [10,11],  // group 3: moderate
    [12,13],  // group 4: moderate-light
    [14,16],  // group 5: light
    [17,20],  // group 6: very light
]

function REsignatureRepTargets(totalSessions, recentHistory=null):
    sequence = []
    recentGroups = []  // sliding window of last N group indices
    windowSize = min(3, REP_GROUPS.length - 1)

    for i in 0..totalSessions:
        availableGroups = REP_GROUPS indices NOT in recentGroups

        // If history exists, further filter to avoid groups used in last 2 workouts
        if recentHistory != null:
            recentlyUsedGroups = groups matching last 2 workout rep values
            availableGroups = availableGroups - recentlyUsedGroups

        // If all groups are excluded, reset and use farthest from most recent
        if availableGroups is empty:
            recentGroups.clear()
            availableGroups = all groups

        // Pick the group farthest (in group-index distance) from the most recently used
        lastGroup = recentGroups.last ?? 3  // default to moderate
        chosen = availableGroups.maxBy(g => abs(g - lastGroup))

        // Pick a specific rep value from within the chosen group
        // Alternate between min and max of the group range on successive visits
        repValue = chosen_group[visitCount[chosen] % chosen_group.length]

        sequence.add(repValue)
        recentGroups.add(chosen)
        if recentGroups.length > windowSize: recentGroups.removeFirst()

    return sequence
```

#### 4.6.3 `REsignatureRepsByExercise`

Same algorithm, but seeded with actual exercise history so the first few sessions of a new block continue naturally from where training left off:

```
function REsignatureRepsByExercise(exerciseId, totalSessions):
    lastNReps = fetchLastNRepValues(exerciseId, n=3)  // from workout history
    return REsignatureRepTargets(totalSessions, recentHistory=lastNReps)
```

#### 4.6.4 `getDupSignatureRepRange`

Parses a human-readable range string (e.g. `"6–12 reps"`) from the block planner UI into `(min, max)` integers. Used when the planner stores a range instead of a single value:

```
function getDupSignatureRepRange(instance1String):
    // Matches patterns: "6-12", "6–12", "6 to 12", "6–12 reps"
    match = regex.match(r'(\d+)[–\-to ]+(\d+)')
    if match: return (int(match[1]), int(match[2]))
    // Single number: "8 reps"
    single = regex.match(r'(\d+)')
    if single: return (int(single[1]), int(single[1]))
    return (8, 12)  // fallback
```

---

## 5. Progression Engine

### 5.1 Architecture

The progression engine is split across two layers:

- **`PeriodizationModelUtils`** (PMU) — pure calculation functions, no state.
- **`ProgressionEngine`** — a wrapper class that holds callbacks and a cache, providing a stable interface to WES.

### 5.2 `ProgressionEngineInputs`

The inputs struct passed to the engine contains:

```dart
class ProgressionEngineInputs {
    String uid;
    String blockId;
    String exerciseId;
    String exerciseName;
    int weekIndex;
    int sessionIndex;  // which session of this exercise in the week (0-based)
    int setIndex;      // 0-based set position
    String periodizationModel;
    String progressionModel;
    double? repTarget;
    double? rir;

    // Callbacks:
    Function getWorkoutHistory;           // exerciseId → List<WorkoutEntry>
    Function getPlannedExerciseDetails;   // exerciseId → Map<String, dynamic>
    Function getResolvedBB2Values;        // exerciseId → {weight, reps, rir, addedWeight}?
    Function getSeedHints;                // key → {s1_weight, s1_reps, ...}?
    Function getCachedProgressedValues;   // cacheKey → result?
    Function setCachedProgressedValues;   // cacheKey, result → void
    Function getExerciseGroup;            // exerciseId → ExerciseGroup
    Function getBodyweightKg;             // uid, dateYmd → double?
    Function getIncrementMap;             // exerciseId → {primary, secondary}
}
```

### 5.3 `engineProgressedValues` — Main Entry Point

```
function engineProgressedValues(inputs):
    cacheKey = buildCacheKey(inputs)

    // Layer 1: in-memory cache
    cached = inputs.getCachedProgressedValues(cacheKey)
    if cached != null: return cached

    // Layer 2: seed hints (pre-computed from schedule, fast first paint)
    seedKey = '${inputs.exerciseId}|${inputs.circuitIndex}'
    seed = inputs.getSeedHints(seedKey)
    if seed != null:
        result = extractFromSeed(seed, inputs.setIndex)
        inputs.setCachedProgressedValues(cacheKey, result)
        return result

    // Layer 3: guard — return placeholder if metadata not ready
    details = inputs.getPlannedExerciseDetails(inputs.exerciseId)
    if details == null or metadataNotReady:
        return {weight: 20.0, reps: 10.0, rir: 17.9}  // sentinel for "loading"

    // Step 1: Determine rep target
    repTarget = determineRepTarget(inputs, details)

    // Step 2: Get RIR
    rir = getRirFromPlanOrInput(inputs.exerciseId, inputs.setIndex,
                                inputs.weekIndex, inputs.sessionIndex,
                                inputs.getResolvedBB2Values(), details)

    // Step 3: Apply BB2 rep/RIR overrides
    bb2 = inputs.getResolvedBB2Values()(inputs.exerciseId)
    if bb2?['reps'] != null: repTarget = bb2['reps'].toDouble()
    if bb2?['rir']  != null: rir = bb2['rir'].toDouble()

    // Step 4: Calculate weight by progression model
    rawWeight = getWeightByProgressionModel(
        exerciseId:   inputs.exerciseId,
        repTarget:    repTarget,
        rir:          rir,
        weekIndex:    inputs.weekIndex,
        sessionIndex: inputs.sessionIndex,
        model:        inputs.progressionModel,
        history:      inputs.getWorkoutHistory(inputs.exerciseId),
        details:      details,
    )

    // Step 5: Snap to valid increment grid
    group = inputs.getExerciseGroup(inputs.exerciseId)
    isBW = isBodyweightExercise(inputs.exerciseId)
    if isBW:
        bw = inputs.getBodyweightKg(inputs.uid, todayYmd)
        addedWeight = rawWeight - (bw ?? 0)
        snappedAdded = roundToNearestValidIncrement(addedWeight, inputs.exerciseId)
        snappedWeight = snappedAdded + (bw ?? 0)
    else:
        snappedWeight = roundToNearestValidIncrement(rawWeight, inputs.exerciseId)

    // Step 6: Apply BB2 weight override
    if bb2?['weight'] != null:
        // If BB2 also changed reps/RIR: use 24-iteration bisection to find
        // a weight that preserves baseline E1RM at the new rep/RIR target
        if bb2RepsOrRirChanged:
            baseE1RM = calculateE1RM(snappedWeight, originalRepTarget, originalRir)
            snappedWeight = bisectWeight(baseE1RM, bb2Reps, bb2Rir, 24)
        // If only weight changed: find reps at the new weight that match
        // original E1RM (brute-force reps 1-30)
        else:
            snappedWeight = bb2['weight'].toDouble()
            repTarget = findRepsForE1RM(baseE1RM, snappedWeight, rir)

    result = {weight: snappedWeight, reps: repTarget, rir: rir}
    inputs.setCachedProgressedValues(cacheKey, result)
    return result
```

### 5.4 `getWeightByProgressionModel` — Model Router

```
function getWeightByProgressionModel(exerciseId, repTarget, rir, weekIndex,
                                      sessionIndex, model, history, details):
    baseE1RM = computeBaseE1RMFromHistory(exerciseId, repTarget, rir, today, history)

    switch model:
        case 'none':
            // No progression — return weight from base E1RM directly
            return reverseCalculateWeight(baseE1RM, repTarget, rir)

        case 'linearWeightIncrease':
            return getProgressedWeight(exerciseId, repTarget, rir, weekIndex,
                                        sessionIndex, baseE1RM, details)

        case 'smartProgression':
            return smartProgressionModel(exerciseId, repTarget, rir, weekIndex,
                                          sessionIndex, baseE1RM, history, details)

        case 'addRepsProgressionModel':
            return addRepsProgressionModel(exerciseId, repTarget, rir, weekIndex,
                                            sessionIndex, baseE1RM, history, details)

    // Post-snap is applied by caller (engineProgressedValues), not here
```

### 5.5 `getProgressedWeight` — Linear Weight Increase

Increases weight by a fixed increment each session or week.

```
function getProgressedWeight(exerciseId, repTarget, rir, weekIndex,
                               sessionIndex, baseE1RM, details):
    weeklyIncrement = details['weeklyWeightIncrement'] ?? defaultIncrement(exerciseId)
    // weeklyIncrement is in kg E1RM equivalent

    // Convert base E1RM to a target for this week
    progressedE1RM = baseE1RM + (weekIndex * weeklyIncrement)

    return reverseCalculateWeight(progressedE1RM, repTarget, rir)
```

Default increments by exercise group:
- Group A: 2.5 kg/week
- Group B: 2.0 kg/week
- Group C: 1.0 kg/week
- Group D: 0.5 kg/week

### 5.6 `smartProgressionModel` — Trial-Based Scoring

Generates candidate weight options and scores them against historical performance data.

```
function smartProgressionModel(exerciseId, repTarget, rir, weekIndex,
                                 sessionIndex, baseE1RM, history, details):
    // Generate candidate weights: base ± N increments
    incrementMap = getIncrementMap(exerciseId)
    candidates = generateCandidates(baseE1RM, repTarget, rir, incrementMap,
                                     range=±5_increments)

    bestScore = -Infinity
    bestWeight = reverseCalculateWeight(baseE1RM, repTarget, rir)

    for candidate in candidates:
        score = scoreCandidate(candidate, exerciseId, repTarget, rir,
                                weekIndex, history, details)
        if score > bestScore:
            bestScore = score
            bestWeight = candidate

    return bestWeight

function scoreCandidate(weight, exerciseId, repTarget, rir,
                          weekIndex, history, details):
    e1rm = calculateE1RM(weight, repTarget, rir)
    score = 0

    // Factor 1: Is this a new E1RM PR? (+large bonus)
    historicalMax = max E1RM in history
    if e1rm > historicalMax * 1.005:   // 0.5% tolerance
        score += 100

    // Factor 2: RIR compliance (penalise if previous sets show high residual fatigue)
    recentRir = average RIR of last 3 sessions
    rirDelta = rir - recentRir
    score += rirDelta * 10   // reward sets that match expected freshness

    // Factor 3: Rep range match (penalise large deviations from plan)
    score -= abs(repTarget - plannedReps) * 5

    // Factor 4: Increment efficiency (prefer larger increments if history supports)
    score += (weight - baseWeight) / primaryIncrement * 2

    return score
```

### 5.7 `addRepsProgressionModel`

Instead of increasing weight, adds reps until a rep ceiling is reached, then jumps weight.

```
function addRepsProgressionModel(exerciseId, repTarget, rir, weekIndex,
                                   sessionIndex, baseE1RM, history, details):
    repCeiling = details['repCeiling'] ?? (repTarget + 3)
    baseWeight = reverseCalculateWeight(baseE1RM, repTarget, rir)
    increment  = details['weightIncrement'] ?? primaryIncrement(exerciseId)

    // Check most recent session
    lastSession = history.mostRecent(exerciseId)
    if lastSession == null: return baseWeight

    lastReps = lastSession.reps

    if lastReps >= repCeiling:
        // Rep ceiling reached → increase weight, reset to base reps
        return lastSession.weight + increment
    else:
        // Stay at same weight, reps will naturally progress
        return lastSession.weight
```

### 5.8 Increment Grid — `roundToNearestValidIncrement`

All suggested weights must land on a valid increment. The valid grid is the union of all multiples of both primary and secondary increments, expanded from 0 to a practical maximum.

```
function roundToNearestValidIncrement(weight, exerciseId):
    incMap = getIncrementMap(exerciseId)
    primary   = incMap['primary']   ?? 2.5
    secondary = incMap['secondary'] ?? 1.25

    grid = expandIncrementOptions(primary, secondary, maxWeight=500)
    // grid = sorted set of {0, secondary, primary, primary+secondary, 2*primary, ...}

    nearest = grid.minBy(g => abs(g - weight))
    return nearest

function expandIncrementOptions(primary, secondary, maxWeight):
    grid = SortedSet()
    p = 0.0
    while p <= maxWeight:
        grid.add(p)
        s = p + secondary
        if s <= maxWeight: grid.add(s)
        p += primary
    return grid
```

`incMapFromRaw` parses raw increment specifications which may be stored as strings like `"2.5"`, `"2.5/1.25"`, or maps like `{primary: 2.5, secondary: 1.25}`.

---

## 6. Fatigue / Cascade Sets

### 6.1 Overview

Set 2 and beyond are "backoff" sets derived from Set 1's E1RM via a fatigue cascade. The cascade applies a cumulative E1RM drop to each subsequent set, gated by the actual/typed RIR of the preceding set.

### 6.2 `_rawDropFor`

Returns the *cumulative* E1RM drop from Set 1 into the given set:

```
_rawDropFor(group, setIndex):
    // setIndex is 1-based (setIndex=1 means Set 2, the first backoff set)
    drops = {
        A: [7.0, 10.5, 13.5, 16.0, 18.0, 19.5, 20.5],
        B: [5.0,  8.0, 10.5, 12.5, 14.0, 15.0, 15.5],
        C: [3.5,  5.5,  7.5,  9.0, 10.0, 10.5, 10.5],
        D: [2.0,  3.5,  5.0,  6.5,  7.5,  8.0,  8.0],
    }
    idx = clamp(setIndex - 1, 0, 6)
    return drops[group][idx]
```

### 6.3 `_gatedDrop` — RIR-Gated Attenuation

The cascade drop is modulated by the RIR of the previous set. If the previous set was performed with a high RIR (low exertion), the drop is reduced (or eliminated); if RIR was low, the full drop applies.

```
_gatedDrop(group, setIndex, prevSetRir):
    raw = _rawDropFor(group, setIndex)

    if prevSetRir == null:
        return raw  // no gating data, apply full drop

    if prevSetRir > 2.0:
        return 0.0  // previous set was easy enough — no cumulative fatigue applied

    if prevSetRir >= 1.8:
        // Partial drop: linearly interpolate between 0 and raw over [1.8, 2.0]
        frac = (2.0 - prevSetRir) / (2.0 - 1.8)   // 0.0 at RIR=2.0, 1.0 at RIR=1.8
        return raw * frac

    // prevSetRir < 1.8: full drop
    return raw
```

### 6.4 `_targetE1RMForSet` — Recursive Cascade Chain

The target E1RM for any set is computed recursively from Set 1:

```
_targetE1RMForSet(setIndex, exerciseId, circuitIndex):
    // Memoised per (setIndex, exerciseId, circuitIndex)
    if setIndex == 0:
        return set1E1RM  // from _getProgressedValues or typed weight

    prevE1RM = _targetE1RMForSet(setIndex - 1, exerciseId, circuitIndex)
    prevRir  = _typedOrHintRIR(setIndex - 1, exerciseId, circuitIndex)
    group    = _resolveGroupForExercise(exerciseId)

    drop = _gatedDrop(group, setIndex, prevRir)
    return prevE1RM - drop
```

**Important**: The drop is cumulative from Set 1. `_targetE1RMForSet(2)` subtracts the drop for setIndex=2 from `_targetE1RMForSet(1)`, which itself already subtracted the drop for setIndex=1 from Set 1's E1RM. The arrays in `_rawDropFor` are *cumulative from Set 1*, so the incremental drop between adjacent sets is:

```
incrementalDrop(set N) = _rawDropFor(group, N) - _rawDropFor(group, N-1)
```

### 6.5 Helper Functions: `_typedOrHint*`

These functions return the "effective" value of a set field — either what the user actually typed, or the current hint value if nothing typed yet. They are used in the cascade to propagate realistic values through the chain.

```
_typedOrHintWeightAbs(setIndex, exerciseId, circuitIndex):
    if controller[setIndex].text is non-empty number:
        w = parseDouble(controller[setIndex].text)
        if isBW(exerciseId): return w + bwKg  // typed = added weight for BW
        return w
    return _synthesizeHintsForSet(setIndex, exerciseId, circuitIndex).midWeight

_typedOrHintReps(setIndex, exerciseId, circuitIndex):
    if repsController[setIndex].text is non-empty number:
        return parseDouble(repsController[setIndex].text)
    return hintReps[setIndex]   // from seed or _getProgressedValues

_typedOrHintRIR(setIndex, exerciseId, circuitIndex):
    if rirController[setIndex].text is non-empty number:
        return parseDouble(rirController[setIndex].text)
    return hintRir[setIndex]    // from getRirFromPlanOrInput
```

### 6.6 `_actualE1RMForSet`

`_actualE1RMForSet` computes the E1RM from what was *actually performed* (typed weight × typed reps × typed RIR), used to anchor the cascade when a user has partially filled in a set:

```
_actualE1RMForSet(setIndex, exerciseId, circuitIndex):
    w    = _typedOrHintWeightAbs(setIndex, exerciseId, circuitIndex)
    r    = _typedOrHintReps(setIndex, exerciseId, circuitIndex)
    rir  = _typedOrHintRIR(setIndex, exerciseId, circuitIndex)
    return calculateE1RM(w, r, rir)
```

---

## 7. Hint Text Pipeline

### 7.1 Overview

The hint text pipeline produces the placeholder text that appears in weight and rep input fields. It operates in a strict 4-tier priority order and has separate paths for Set 1 and Sets 2+.

### 7.2 Four-Tier Priority (Highest to Lowest)

```
Priority 1: Claude_bullet snapshot override
    — Full UI state snapshot saved on last visit (within 2 hours)
    — Restores typed values AND hint overrides
    — If user typed a value last time: restore to typed controller, no hint shown
    — If hint was shown: restore the same hint value as override

Priority 2: Seed hints (_seedHintsByKey)
    — Pre-computed from schedule JSON, available at first paint
    — Keyed by '${exerciseId}|${circuitIndex}'
    — Contains s1_weight, s1_reps, s1_weight_added, s1_rir, s2_rir..s8_rir

Priority 3: BB2 overrides (_resolvedBB2Values)
    — Values written by the block planner (manual overrides for weight/reps/RIR)
    — Keyed by exerciseId → {weight, reps, rir, addedWeight}

Priority 4: Live calculation
    — engineProgressedValues (Set 1) or fatigue cascade (Sets 2+)
    — Computes in background, updates UI when ready
```

### 7.3 Set 1 Fast Path — `set1SuggestedWeight` and `set1SuggestedReps`

```
function set1SuggestedWeight(exerciseId, circuitIndex):
    // P1: Claude_bullet override
    override = _claudeBulletWeightHintOverrides[makeKey(exerciseId, circuitIndex, set=0)]
    if override != null: return override

    // P2: Seed hints
    seedKey = '${exerciseId}|${circuitIndex}'
    seed = _seedHintsByKey[seedKey]
    if seed != null:
        if isBW(exerciseId): return seed['s1_weight_added']
        return seed['s1_weight']

    // P3: BB2 override
    bb2 = _resolvedBB2Values[exerciseId]
    if bb2?['weight'] != null:
        if isBW(exerciseId): return bb2['addedWeight']
        return bb2['weight']

    // P4: Live calculation
    result = await _getProgressedValues(exerciseId, circuitIndex, setIndex=0)
    if isBW(exerciseId): return result.weight - bwKg
    return result.weight

function set1SuggestedReps(exerciseId, circuitIndex):
    // P1: Claude_bullet override (reps)
    override = _claudeBulletRepsHintOverrides[makeKey(exerciseId, circuitIndex, set=0)]
    if override != null: return override

    // P2: Seed hints
    seed = _seedHintsByKey['${exerciseId}|${circuitIndex}']
    if seed != null: return seed['s1_reps']

    // P3: BB2 override
    bb2 = _resolvedBB2Values[exerciseId]
    if bb2?['reps'] != null: return bb2['reps']

    // P4: Live calculation
    result = await _getProgressedValues(exerciseId, circuitIndex, setIndex=0)
    return result.reps
```

### 7.4 Set 2+ — `suggestedWeightForSet` and `_synthesizeHintsForSet`

```
function suggestedWeightForSet(exerciseId, circuitIndex, setIndex):
    if setIndex == 0: return set1SuggestedWeight(exerciseId, circuitIndex)

    // P1: Claude_bullet override
    override = _claudeBulletWeightHintOverrides[makeKey(exerciseId, circuitIndex, setIndex)]
    if override != null: return override

    // P2-4: Cascade synthesis
    synthesis = _synthesizeHintsForSet(exerciseId, circuitIndex, setIndex)
    if synthesis.singleWeight != null: return synthesis.singleWeight
    return synthesis.midWeight

function _synthesizeHintsForSet(exerciseId, circuitIndex, setIndex):
    // Compute target E1RM for this set via cascade
    targetE1RM = _targetE1RMForSet(setIndex, exerciseId, circuitIndex)

    // Get rep target and RIR for this set
    repTarget = suggestedRepsForSet(exerciseId, circuitIndex, setIndex)
    rir = getRirFromPlanOrInput(exerciseId, setIndex, ...)

    // Compute centre weight from target E1RM
    centreWeight = reverseCalculateWeight(targetE1RM, repTarget, rir)
    centreWeight = roundToNearestValidIncrement(centreWeight, exerciseId)

    // Build ±7.5% band around centre
    lowWeight  = roundToNearestValidIncrement(centreWeight * 0.925, exerciseId)
    highWeight = roundToNearestValidIncrement(centreWeight * 1.075, exerciseId)

    // Cap: backoff set weight must not exceed previous set's weight
    prevWeight = _typedOrHintWeightAbs(setIndex - 1, exerciseId, circuitIndex)
    if centreWeight > prevWeight: centreWeight = prevWeight
    if highWeight   > prevWeight: highWeight   = prevWeight

    // BW conversion: convert absolute weights to added weights for display
    if isBW(exerciseId):
        bw = bwKg
        centreAdded = centreWeight - bw
        lowAdded    = lowWeight - bw
        highAdded   = highWeight - bw
        if centreAdded <= 0 and lowAdded <= 0:
            // Bodyweight only, no added weight displayed
            return SynthResult(singleWeight: 0, displayText: 'BW')
        // Clamp negatives to 0
        lowAdded  = max(0.0, lowAdded)
        highAdded = max(0.0, highAdded)
        centreAdded = max(0.0, centreAdded)

    if lowWeight == highWeight:
        return SynthResult(singleWeight: centreWeight, midWeight: centreWeight)
    return SynthResult(lowWeight: lowWeight, midWeight: centreWeight,
                       highWeight: highWeight)
```

### 7.5 `_weightHintText` — Async Hint String for Weight Field

```
function _weightHintText(exerciseId, circuitIndex, setIndex):
    // P1: Claude_bullet override already loaded into controller — no hint needed
    if claudeBulletOverride exists: return ''

    weightTyped = weightController[setIndex].text is non-empty
    repsTyped   = repsController[setIndex].text is non-empty

    if weightTyped and repsTyped:
        return ''   // both typed: no hint needed

    if repsTyped and not weightTyped:
        // Reps are known → collapse to single weight
        typedReps = parseDouble(repsController[setIndex].text)
        rir = getRirFromPlanOrInput(...)
        targetE1RM = _targetE1RMForSet(setIndex, exerciseId, circuitIndex)
        weight = reverseCalculateWeight(targetE1RM, typedReps, rir)
        weight = roundToNearestValidIncrement(weight, exerciseId)
        if isBW: weight = weight - bwKg  // show added weight
        return formatWeight(weight)

    if weightTyped and not repsTyped:
        return ''   // weight already chosen, no weight hint to show

    // Neither typed: show range
    synthesis = await _synthesizeHintsForSet(exerciseId, circuitIndex, setIndex)
    if synthesis.singleWeight != null:
        return formatWeight(synthesis.singleWeight)
    return '${formatWeight(synthesis.lowWeight)} – ${formatWeight(synthesis.highWeight)}'
```

### 7.6 `_repsHintText` — Symmetric Logic for Reps Field

```
function _repsHintText(exerciseId, circuitIndex, setIndex):
    weightTyped = weightController[setIndex].text is non-empty
    repsTyped   = repsController[setIndex].text is non-empty

    if repsTyped and weightTyped: return ''

    if weightTyped and not repsTyped:
        // Weight is known → collapse to single rep count
        typedWeight = parseDouble(weightController[setIndex].text)
        if isBW: typedWeight = typedWeight + bwKg  // convert added → absolute
        rir = getRirFromPlanOrInput(...)
        targetE1RM = _targetE1RMForSet(setIndex, exerciseId, circuitIndex)
        reps = reverseCalculateReps(targetE1RM, typedWeight, rir)
        return reps.round().toString()

    if repsTyped and not weightTyped:
        return ''

    // Neither typed: show planned rep target
    repTarget = suggestedRepsForSet(exerciseId, circuitIndex, setIndex)
    return repTarget.round().toString()
```

### 7.7 `formatWeight` — Display Formatter

```
function formatWeight(weight):
    if weight == weight.truncate():
        return weight.toInt().toString()          // 100 → "100"
    remainder = weight - weight.truncate()
    if abs(remainder - 0.5) < 0.01:
        return weight.toStringAsFixed(1)           // 100.5 → "100.5"
    return weight.toStringAsFixed(2)               // 100.25 → "100.25"
```

### 7.8 `suggestedRepsForSet` — Unified Reps Across Sets

```
function suggestedRepsForSet(exerciseId, circuitIndex, setIndex):
    if setIndex == 0:
        return set1SuggestedReps(exerciseId, circuitIndex)

    // For sets 2+, derive reps from target E1RM and suggested weight
    targetE1RM = _targetE1RMForSet(setIndex, exerciseId, circuitIndex)
    weight = suggestedWeightForSet(exerciseId, circuitIndex, setIndex)
    rir = getRirFromPlanOrInput(exerciseId, setIndex, ...)
    if isBW: weight = weight + bwKg   // absolute weight for E1RM math

    reps = reverseCalculateReps(targetE1RM, weight, rir)
    return max(1.0, reps.round().toDouble())
```

### 7.9 Claude_bullet Snapshot Save/Restore

#### Save (`Claude_bulletSaveFullDayUiSnapshot`)

Called on navigation away from the workout screen. Iterates all visible sets and saves each field:

```
for each exercise in visible exercises:
    for each set in exercise.sets:
        for each field in [weight, reps, rir]:
            origin = 'typed' if controller.text non-empty
                     else if hintOverride exists: 'hint'
                     else: 'empty'
            snapshot[exerciseId][circuitIndex][setIndex][field] = {
                value: controller.text or hintValue,
                origin: origin,
                timestamp: now,
            }

save snapshot to Isar:
    WESInitSnapshot {
        uid: uid,
        blockId: blockId,
        dateYmd: todayYmd,
        snapshotJson: jsonEncode(snapshot),
        savedAt: now,
    }
```

#### Restore (`Claude_bulletTryRestoreFullDayUiSnapshot`)

Called on screen init, before the normal hint calculation:

```
stored = Isar.query WESInitSnapshot where uid=uid, blockId=blockId, dateYmd=today
if stored == null: return false

age = now - stored.savedAt
if age > Duration(hours: 2): return false

snapshot = jsonDecode(stored.snapshotJson)

for each exerciseId in snapshot:
    for each (circuitIndex, setIndex, field) in snapshot[exerciseId]:
        entry = snapshot[exerciseId][circuitIndex][setIndex][field]
        if entry.origin == 'typed':
            setController(exerciseId, circuitIndex, setIndex, field, entry.value)
        else if entry.origin == 'hint':
            setHintOverride(exerciseId, circuitIndex, setIndex, field, entry.value)

return true  // restore succeeded
```

---

## 8. Schedule Generation Integration

### 8.1 WESInitSnapshot and `_seedHintsByKey`

The first-paint hints are pre-computed during schedule generation and stored in the schedule JSON alongside the workout structure. When WES opens, it reads `_seedHintsByKey` from the snapshot before any async calculation completes.

#### Seed hint map structure

```
_seedHintsByKey: Map<String, Map<String, dynamic>> = {
    '${exerciseId}|${circuitIndex}': {
        's1_weight':       double,   // Set 1 absolute weight (kg)
        's1_weight_added': double,   // Set 1 added weight for BW exercises
        's1_reps':         double,   // Set 1 rep target
        's1_rir':          double,   // Set 1 RIR target
        's2_rir':          double,   // Set 2 RIR (from rirPlan)
        's3_rir':          double,
        ...
        's8_rir':          double,   // up to Set 8
    },
}
```

Note: Seed hints only pre-compute Set 1 weight/reps and all-set RIR. Sets 2+ weight/reps are computed live from the cascade.

### 8.2 `computePlanInputsHash` — Cache Invalidation Signature

This hash is stored alongside the seed hints. If the plan changes, the hash changes and the cached hints are invalidated.

```
function computePlanInputsHash(uid, blockId, weekIndex, plannedExerciseDetails,
                                blockStart, blockEnd, exerciseIds):
    components = [
        uid,
        blockId,
        weekIndex.toString(),
        blockStart.toIso8601String(),
        blockEnd.toIso8601String(),
    ]
    for exerciseId in sorted(exerciseIds):
        details = plannedExerciseDetails[exerciseId]
        components.add(exerciseId)
        components.add(details['periodizationModel'] ?? '')
        components.add(details['progressionModel'] ?? '')
        components.add(jsonEncode(details['rirPlan'] ?? {}))
        components.add(jsonEncode(details['dupExposureReps'] ?? []))
        components.add((details['defaultReps'] ?? '').toString())
        components.add((details['weeklyWeightIncrement'] ?? '').toString())

    joined = components.join('|')
    return sha1(utf8.encode(joined)).toString()
```

### 8.3 `WesHintInputsPayload` — Extended Hash Including BW and Workout Dates

`WesHintInputsPayload` extends the plan hash with runtime data that affects hint computation but is not in the plan:

```
class WesHintInputsPayload:
    planHash: String          // from computePlanInputsHash
    bodyweightKg: double?     // user's current BW (affects BW exercise hints)
    workoutDates: List<String>  // YMD strings of scheduled workouts in this week

    hash():
        return sha1(utf8.encode([
            planHash,
            bodyweightKg?.toString() ?? '',
            workoutDates.sorted().join(','),
        ].join('|'))).toString()
```

If the WESInitSnapshot's stored `hintsInputsHash` differs from the freshly computed hash, the stored seed hints are discarded and recomputed.

### 8.4 `WESInitSnapshot` — Isar-Backed Local Cache

```
@Collection
class WESInitSnapshot:
    id: int (auto)
    uid: String
    blockId: String
    dateYmd: String            // "YYYY-MM-DD" — one snapshot per workout day
    hintsJson: String          // jsonEncode(_seedHintsByKey)
    hintsInputsHash: String    // WesHintInputsPayload.hash() at time of computation
    hintsReady: bool           // false while computing, true when seeds are available
    snapshotJson: String?      // Claude_bullet full UI state (separate from seed hints)
    savedAt: DateTime
```

Query pattern:
```
Isar.where('WESInitSnapshot')
    .filter(uid == uid AND blockId == blockId AND dateYmd == dateYmd)
    .findFirst()
```

### 8.5 Schedule-to-WES Data Flow

```
1. ScheduleParser generates workout schedule for the block
2. For each workout day:
   a. Compute WesHintInputsPayload.hash()
   b. Check existing WESInitSnapshot — if hash matches and hintsReady=true: skip
   c. For each exercise in day:
      - Run engineProgressedValues(setIndex=0) → {weight, reps, rir}
      - Run getRirFromPlanOrInput for sets 2-8
      - Build seed hint entry
   d. Write WESInitSnapshot with hintsJson + hintsInputsHash + hintsReady=true
3. WES opens → reads WESInitSnapshot → populates _seedHintsByKey
4. WES renders immediately with seed hints (P2 priority)
5. Background: run full engineProgressedValues for cache warming (P4)
6. If user modifies a field: P1 (Claude_bullet) overrides take effect on next open
```

---

## 9. Recommendations for Clean Rebuild

### 9.1 File and Class Structure

The RE-Test-Main implementation grew organically into a large `periodization_model_utils.dart` (3,978 lines) and a massive `workout_entry_screen.dart` (18,063 lines). A clean rebuild should split these into focused units:

```
lib/
  engine/
    e1rm.dart                     // calculateE1RM, reverseCalculate*
    exercise_group.dart            // ExerciseGroup enum + _resolveGroupForExercise
    increment_grid.dart            // roundToNearestValidIncrement, expandIncrementOptions
    base_e1rm_resolver.dart        // computeBaseE1RMFromHistory (5-tier)
    rir_resolver.dart              // getRirFromPlanOrInput + getSet1RirByModel
    periodization/
      dup_exposure.dart
      dup_week.dart
      linear_classic.dart
      linear_exposure.dart
      re_signature.dart            // REsignatureRepTargets, getDupSignatureRepRange
    progression/
      linear_weight.dart           // getProgressedWeight
      smart_progression.dart       // smartProgressionModel
      add_reps.dart                // addRepsProgressionModel
    fatigue_cascade.dart           // _rawDropFor, _gatedDrop, _targetE1RMForSet
    progression_engine.dart        // engineProgressedValues (thin orchestrator)
  hints/
    hint_synthesiser.dart          // _synthesizeHintsForSet
    hint_text_provider.dart        // _weightHintText, _repsHintText
    seed_hint_builder.dart         // builds _seedHintsByKey for schedule
    snapshot_manager.dart          // Claude_bullet save/restore
  cache/
    wes_init_snapshot.dart         // Isar model + query helpers
    plan_inputs_hash.dart          // computePlanInputsHash, WesHintInputsPayload
```

### 9.2 Simplifications

1. **Separate E1RM math from UI state**. The cascade chain (`_targetE1RMForSet`) currently reaches into UI controllers (`_typedOrHintWeightAbs`). Refactor so the cascade takes explicit `(weight, reps, rir)` inputs and returns an E1RM; the UI layer bridges controller values to those inputs.

2. **Typed vs hint state as first-class concept**. Instead of checking `controller.text.isNotEmpty` everywhere, use a discriminated union:
   ```dart
   sealed class FieldValue {
     const factory FieldValue.typed(double v) = TypedValue;
     const factory FieldValue.hinted(double v) = HintedValue;
     const factory FieldValue.empty() = EmptyValue;
   }
   ```

3. **Memoisation at the correct boundary**. WES uses a flat `_synthHintCache` map that must be manually invalidated. Use a reactive computation framework (e.g. `riverpod`) so cache entries auto-invalidate when their inputs change.

4. **Bodyweight abstraction**. BW conversion (absolute ↔ added) appears in 7+ separate functions. Extract a `BwWeightDomain` helper with `toAbsolute(added)` / `toAdded(absolute)` / `isBodyweight(id)` that all other functions call.

5. **Collapse `exerciseSettings` into `plannedExerciseDetails`**. Already done in the reference implementation (legacy docs have both), but a clean rebuild should have a single source of truth from day one.

6. **Remove the 17.9 RIR sentinel**. The placeholder `{weight:20, reps:10, rir:17.9}` returned when metadata is not ready is a leaky abstraction. Replace with `null` / `Optional` and handle the loading state explicitly in the UI.

7. **Plan signature coverage**. The current `computePlanInputsHash` does not include the template assignment structure. In a clean rebuild, include template content (exercise list + order per day) in the hash so hint caches invalidate when templates change.

8. **Test surface**. All of Section 1-6 (E1RM through cascade) is pure mathematics with no UI dependencies and should have 100% unit test coverage. The key invariants to test:
   - `calculateE1RM(reverseCalculateWeight(e, r, rir), r, rir) ≈ e` for all (e, r, rir)
   - `reverseCalculateReps` agrees with `calculateE1RM` to within ±0.5 reps
   - `_targetE1RMForSet(N) < _targetE1RMForSet(N-1)` for all N > 0
   - `roundToNearestValidIncrement` always returns a value in the expanded grid
   - `REsignatureRepTargets` never uses the same rep group twice within a window of `windowSize`

### 9.3 Known Edge Cases to Preserve

- **BW exercises with negative added weight**: When `bwKg > suggestedAbsoluteWeight`, `addedWeight` goes negative. The hint system clamps this to 0 and shows "BW" for the weight field; do not show a negative number.
- **RIR > 2.0 gating**: A high-RIR set completely suppresses the cascade drop for the next set. This is intentional — if Set 1 was very easy, Set 2 should match Set 1's weight.
- **Brzycki/Epley crossover at exactly 25 effective reps**: Both formulas yield the same result. The 4-decimal rounding prevents float drift from causing inconsistent branch selection.
- **Missing history for new exercises**: All 5 tiers of `computeBaseE1RMFromHistory` may return null. The caller must fall back to a weight-by-category default table, not crash.
- **Legacy `exerciseSettings` field**: Old Firestore documents may have a separate `exerciseSettings` map alongside `plannedExerciseDetails`. On read, merge `exerciseSettings` into `plannedExerciseDetails` and re-write in the canonical format.
- **ID-keyed vs name-keyed `exerciseDetails`**: Legacy block documents may have `exerciseDetails` keyed by Firestore document ID rather than exercise display name. `resolveExerciseIds()` on `BlockPlannerState` handles this migration.

---

### 9.4 Exercise Library as Source of Truth — Rebuild Contract

This is a deliberate departure from RE-Test-Main's architecture and must be respected throughout the rebuild.

**Principle**: The exercise library (`users/{uid}/exerciseDefaults/{exerciseName}`) is the single source of truth for how the engine behaves for any exercise in any workout context. Block planning is additive — it inherits library defaults and may override them per cycle; those overrides are stored in `plannedExerciseDetails` and are local to the cycle.

**Consequences for hint generation:**

For a *block workout* where a schedule has been generated:
- Hints flow from pre-computed `calculatedWeight/Reps/Rir` embedded in the schedule (Section 8).
- Those values were computed using either the block override (if set) or the library defaults.

For a *block workout* where no schedule has been generated (e.g. first run before generation):
- Hints are computed on the fly from the block's `plannedExerciseDetails` + E1RM history.

For an *ad-hoc workout* (no block):
- Hints are computed on the fly from `exerciseDefaults` library settings + E1RM history.
- The engine uses the same computation path as block generation; there is no reduction in hint quality.

**Default set count:**

The library default `numSets` applies to both ad-hoc and block workouts. When a user starts an ad-hoc workout for Bench Press, Barbell, the session should initialise with the library default number of sets (e.g. 3), not a fixed application constant.

**Settings precedence chain** (highest → lowest):

```
User in-session edit
  ↓ Block cycle override (plannedExerciseDetails — cycle-specific)
  ↓ Exercise library default (exerciseDefaults — user's personal standard)
  ↓ App hardcoded default (ExerciseDefaultSettings — category/name fallback)
```

Block planning reads at tier 3 when seeding, and stores any user adjustments at tier 2. The library default (tier 3) is only modified by the user explicitly from the Exercise Library page — not as a side-effect of block planning.

---

*Specification derived from RE-Test-Main branch source analysis. Covers periodization_model_utils.dart (3,978 lines), progression_engine.dart (968 lines), workout_entry_screen.dart (18,063 lines), and week_planner.dart (2,570 lines).*
