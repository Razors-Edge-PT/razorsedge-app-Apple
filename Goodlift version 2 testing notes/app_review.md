# REClaude App — Full Review & Test Plan

*Generated: 2026-03-28*

---

## Table of Contents

1. [Screen Inventory](#1-screen-inventory)
2. [Navigation Map](#2-navigation-map)
3. [Progression & Calculation Reference](#3-progression--calculation-reference)
4. [Test Cases](#4-test-cases)
   - 4.1 Authentication
   - 4.2 Account Creation
   - 4.3 Block Planning
   - 4.4 Schedule Screen (Week Schedule Tab)
   - 4.5 Workout Session Screen
   - 4.6 Set Progression — Expected Values
   - 4.7 E1RM Calculations — Expected Values
   - 4.8 Best Set Resolver — Tier Cascade
   - 4.9 Calendar & Auto-Refresh
   - 4.10 Templates
   - 4.11 Personal Records (Bests)
   - 4.12 Exercise History & Analytics
   - 4.13 Weight Tracking
   - 4.14 Social Features
   - 4.15 Coach Dashboard

---

## 1. Screen Inventory

### 1.1 Authentication & Onboarding

#### LoginScreen (`lib/onboarding_and_profile/login_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Email field | TextField | Accepts email address |
| Password field | TextField (obscured) | Accepts password; eye icon toggles visibility |
| Sign In | ElevatedButton | Calls Firebase email/password auth → navigates to HomeScreen on success |
| Sign in with Google | Button | Calls `_googleSignIn()` → Firebase Google auth → HomeScreen |
| Sign Up | TextButton | Navigates to CreateNewAccountScreen |
| Forgot Password? | TextButton | Navigates to ForgotPasswordScreen |

#### CreateNewAccountScreen (`lib/onboarding_and_profile/create_new_account_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Email field | TextField | Email input (may be pre-filled from args) |
| Password field | TextField (obscured) | Password entry; eye toggle |
| Confirm Password field | TextField (obscured) | Must match password |
| Username field | TextField | Debounced availability check via `_isUsernameAvailable()` |
| First Name field | TextField | Required |
| Last Name field | TextField | Required |
| DOB — Day/Month/Year | TextFields with `DobDashFormatter` | Date of birth entry |
| Gender | DropdownButton | Options: M / F / N |
| Create Account | ElevatedButton | Validates all fields; creates Firebase user; writes user doc to `users/{uid}`; bootstraps 3 default blocks + templates; navigates to HomeScreen |
| Terms of Service link | GestureDetector | Launches ToS URL |

#### ForgotPasswordScreen (`lib/onboarding_and_profile/forgot_password_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Email field | TextField | Email to receive reset link |
| Send Reset Link | ElevatedButton | Calls `FirebaseAuth.sendPasswordResetEmail()` |
| Back to Sign In | TextButton | Navigator.pop() |

---

### 1.2 Home Screen (`lib/home_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Bottom nav — Calendar tab | NavigationBarItem | Shows TrainingCalendar + day log summary |
| Bottom nav — Blocks tab | NavigationBarItem | Shows PlannedBlocksPage |
| Bottom nav — Templates tab | NavigationBarItem | Shows TemplatesScreen |
| Bottom nav — More tab | NavigationBarItem | Shows profile / social / coach links |
| Training calendar — day cell | GestureDetector | Taps load WorkoutSessionScreen for that date |
| Training calendar — empty day "Start Workout" | FilledButton.icon | Opens WorkoutSessionScreen for the selected date |
| Calendar day with logs | GestureDetector | Navigates to WorkoutLogDetailScreen |
| Block-end popup — Select Next Block | Modal button | Lets user pick which block becomes active after the current one ends |
| `_calendarRefreshToken` increment | Internal (onLogsSaved callback) | Forces TrainingCalendar to re-fetch data after a log is saved |

---

### 1.3 Block Planning

#### PlannedBlocksPage (`lib/block_planning/planned_blocks.dart`)

| Element | Type | Action |
|---------|------|--------|
| Block card | InkWell | Navigates to BlockPlannerScreen in edit mode with the block's data |
| Delete block | IconButton (trash) | Confirmation dialog → deletes block from Firestore |
| Add Block | FloatingActionButton | Navigates to BlockPlannerScreen in new-block mode |

#### BlockPlannerScreen (`lib/block_planning/block_planner.dart`)

| Element | Type | Action |
|---------|------|--------|
| Block name | TextField | Editable; updates `BlockPlannerState.blockName` |
| Start date | TextButton / DatePicker | Picks block start date |
| End date | TextButton / DatePicker | Picks block end date |
| Days of week (Mon–Sun) | Checkbox × 7 | Toggles which weekdays are training days |
| Add Exercise | TextButton / IconButton | Opens ExercisePicker dialog or ExerciseListScreen |
| Exercise row — drag handle | Draggable | Reorders exercises within the list |
| Exercise row — delete | IconButton | Removes exercise from block |
| Per-exercise — Weekly frequency | Slider | Sets how many days/week exercise appears (1–7) |
| Per-exercise — Best weight | TextField | Manual 1RM seed weight (kg); feeds Tier 1 of BestSetResolver |
| Per-exercise — Best reps | TextField | Rep count for the best weight |
| Per-exercise — Body parts | Multi-select chips | Tags for workout-map distribution constraints |
| Per-exercise — RIR target | TextField / Slider | Target Reps In Reserve for the block |
| Per-exercise — Preferred days | Day chips | Hints workout-map assignment to specific weekdays |
| Week schedule tab — exercise cell | GestureDetector | Opens SelectedExerciseDetailsPanel for that day's exercise |
| Week schedule tab — group-by-templates toggle | IconButton (folder_copy) | Toggles `_groupByTemplates`; injects template name headers between exercise rows |
| Template assignment (per day) | Dropdown / Picker | Assigns a template to a specific day; writes `templateAssignments` field on block doc |
| Save Block | ElevatedButton | Validates → calls `BlockPlanningService.saveBlock()` → generates schedule → saves to Firestore → navigates to PlannedBlocksPage |

#### WeekScheduleTab (`lib/block_planning/week_schedule_tab.dart`)

| Element | Type | Action |
|---------|------|--------|
| Group-by-templates toggle | IconButton | Sets `_groupByTemplates = !_groupByTemplates`; passed to each WeekSchedulerCard |
| Week header row | Display only | Shows week number |
| Exercise cell | GestureDetector | Opens exercise detail panel |
| Template name header (when grouped) | Display (injected) | Renders template name above its exercise rows |

---

### 1.4 Workout Session Screen (`lib/screens/workout_session/workout_session_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Workout name | TextField | Editable session label |
| Date picker button | IconButton / TextButton | Opens DatePicker; changes `_selectedDate`; reloads schedule |
| Circuit card — expand/collapse | InkWell / ExpansionTile header | Expands or collapses the circuit |
| Circuit card — drag handle | Draggable | Reorders circuits |
| Circuit card — delete circuit | IconButton | Removes entire circuit |
| Exercise row — name tap | GestureDetector | Navigates to ExerciseDetailsScreen (history) |
| Exercise row — check icon (complete) | IconButton | Marks exercise complete; disables set editing |
| Exercise row — check icon (tap again) | IconButton | **Un-completes** exercise; clears all actuals (weight/reps/rir/e1rm); resets set rows via `ValueKey` |
| Exercise row — drag handle | Draggable | Reorders exercises within circuit |
| Exercise row — delete exercise | IconButton | Removes exercise from circuit |
| Exercise row — history button | IconButton | Opens ExerciseDetailsScreen |
| Exercise row — top sets button | IconButton | Opens TopSetsScreen |
| Set row — Weight field | TextField | Logs actual weight (kg or lb depending on WeightUnitController) |
| Set row — Reps field | TextField | Logs actual rep count |
| Set row — RIR field | TextField | Logs Reps In Reserve |
| Set row — Notes field | TextField | Optional set notes |
| Set row — E1RM display | Display | Shows computed E1RM (updates on weight/reps/rir change) |
| Set row — drag handle | Draggable | Reorders sets within an exercise |
| Set row — menu (⋮) | PopupMenuButton | Options: Delete set, Duplicate set |
| Add Set | TextButton | Appends new empty set to exercise |
| Add Exercise (+ button) | IconButton | Opens TemplatesScreen or ExercisePicker to add exercise to a circuit |
| Add Circuit | TextButton / FAB | Creates new empty circuit |
| Save Workout | ElevatedButton | Validates sets → writes logs to Firestore → calls `BestsService.updateFromWorkoutSets()` → calls `onLogsSaved` callback → pops |
| Templates button | IconButton | Opens TemplatesScreen to load or swap template |
| `_firestorePushTimer` (debounced) | Internal | 4 s after each `_cacheDraft()` call, pushes to Firestore `users/{uid}/sessionDrafts/{date}` |

#### CircuitCard / SetRow (`lib/screens/workout_session/widgets/circuit_card.dart`)

| Element | Type | Action |
|---------|------|--------|
| Check circle icon (completed exercise) | IconButton | Un-completes exercise: sets `ex.completed = false`, clears `weight/reps/rir/e1rm` on all `loggedSets`, removes `editedWeight/editedReps/editedRir` from metadata; calls `widget.onChanged()` |
| `ValueKey('${ex.exercise}_${ex.completed}_$j')` on SetRow | Framework key | Forces full state recreation (clears `_userTypedWeight/_userTypedReps/_userTypedRir` flags) whenever `ex.completed` changes |

---

### 1.5 Templates Screen (`lib/screens/workout_session/templates_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Template card | InkWell / ExpansionTile | Expands to show exercises in template |
| Edit template name | IconButton (pencil) | Opens inline edit dialog → updates Firestore |
| Delete template | IconButton (trash) | Confirmation → deletes from Firestore |
| History button (if `template.version > 0`) | IconButton (history) | Navigates to TemplateHistoryScreen |
| Use template | Button | Loads template circuits into WorkoutSessionScreen |
| Add Template | FAB | Navigates to CreateTemplateScreen |
| Block/day assignment dropdown | DropdownButton | Assigns template to a specific block week/day |
| Filter — active/previous/upcoming/unassigned | Toggle chips | Filters visible templates |
| Filter — planned-only | Toggle | Shows only templates without personal-best data |

#### TemplateHistoryScreen (`lib/screens/workout_session/template_history_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Version list | ListView (FutureBuilder) | Loads `TemplateVersionService.loadVersionHistory()` |
| `_VersionCard` — expand | ExpansionTile | Shows version number, date, exercise list |

---

### 1.6 Exercise History & Analytics

#### ExerciseDetailsScreen (`lib/screens/exercise_history/exercise_details_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Exercise selector | DropdownButton | Switches between all exercises with logged data |
| Trend range buttons (7d, 14d, 1m, 6m, 1y, 2y) | ToggleButtons | Filters displayed history |
| Include RIR toggle | Switch | Adds RIR to E1RM calculation for chart data |
| Rep group input | TextField | e.g. "5, 8-12" — filters displayed sets to matching rep ranges |
| Line chart data point | GestureDetector | Shows tooltip with date / weight / reps / E1RM |
| Top Sets button | ElevatedButton | Navigates to TopSetsScreen |

#### TopSetsScreen (`lib/screens/exercise_history/top_sets_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Set row | InkWell | Navigates to WorkoutDetailsScreen for that date |
| Sort header | TapDetector | Sorts by E1RM / weight / date |

#### ProgressDashboard (`lib/screens/analytics/progress_dashboard.dart`)

| Element | Type | Action |
|---------|------|--------|
| Exercise selector | DropdownButton | Switches exercise being analyzed |
| Full history toggle | Switch | Loads complete history vs. recent window |

---

### 1.7 Weight Tracking

#### WeightScreen (`lib/screens/weight/weight_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Range selector | DropdownButton | Last month / 3mo / 6mo / 1yr |
| Calculation method | DropdownButton | Standard / 3-day avg / 7-day avg |
| Line chart | Interaction | Shows body-weight trend; tap for date details |
| Add Entry | FAB | Navigates to NewWeightEntryScreen |
| View History | TextButton | Navigates to WeightHistoryScreen |

#### NewWeightEntryScreen

| Element | Type | Action |
|---------|------|--------|
| Weight field | TextField | Numeric; kg or lb based on user preference |
| Date picker | TextButton | Selects entry date |
| Notes field | TextField | Optional |
| Save | ElevatedButton | Writes to `users/{uid}/weight_entries/{date}`; pops |

#### WeightHistoryScreen

| Element | Type | Action |
|---------|------|--------|
| Entry row | ListTile | Shows date, weight, notes |
| Delete entry | IconButton (trash) | Removes entry from Firestore |

---

### 1.8 Social Features

#### SocialHubScreen — Feed Tab

| Element | Type | Action |
|---------|------|--------|
| Create Post | FAB | Opens CreatePostSheet |
| Post card | InkWell | Navigates to PostDetailScreen |
| Like button | IconButton (heart) | Toggles like status |
| Comment button | IconButton | Opens inline comment input |
| Share button | IconButton | Platform share sheet |
| Add Gym Buddy | Button | Opens AddGymBuddyScreen |
| Infinite scroll | ListView | Auto-loads next page via `FeedPaginationController` |

#### SocialHubScreen — Leaderboard Tab

| Element | Type | Action |
|---------|------|--------|
| Lift filter | DropdownButton | Squat / Bench / Deadlift / OHP |
| User row | InkWell | Navigates to ProfileScreen (read-only) |

#### SocialHubScreen — My Posts Tab

| Element | Type | Action |
|---------|------|--------|
| Post card | InkWell | Navigates to PostDetailScreen |
| Edit post | IconButton | Opens CreatePostSheet in edit mode |
| Delete post | IconButton | Removes from Firestore |

#### SocialHubScreen — Requests Tab

| Element | Type | Action |
|---------|------|--------|
| Accept | TextButton | Approves coach-athlete relationship |
| Decline | TextButton | Rejects request |

#### ProfileScreen

| Element | Type | Action |
|---------|------|--------|
| Upload avatar | IconButton / GestureDetector | Opens image picker → uploads to Firebase Storage |
| Edit personal details | IconButton | Opens dialog with TextFields for age/height/weight |
| View analytics | TextButton | Navigates to ProgressDashboard |
| Post card | InkWell | Navigates to PostDetailScreen |
| Add / Remove coach | Button | Navigates to RequestAthleteAccessPage or shows remove confirmation |

#### DirectMessagesScreen

| Element | Type | Action |
|---------|------|--------|
| Conversation row | InkWell | Opens chat detail view |
| New message | IconButton | Opens AddGymBuddyScreen |
| Message input | TextField | Type message |
| Send | IconButton | Calls `DirectMessagesService.send()` |

---

### 1.9 Coach Dashboard (`lib/screens/coach/coach_dashboard_screen.dart`)

| Element | Type | Action |
|---------|------|--------|
| Athlete search | TextField | Filters athletes list |
| Athlete row | InkWell | Loads selected athlete's data |
| Training calendar (athlete view) | TrainingCalendar | Shows athlete's schedule; same interactions as personal calendar |
| Edit block | IconButton | Navigates to BlockPlannerScreen with `targetUid = athlete.uid` |
| Start workout | Button | Navigates to WorkoutSessionScreen with `targetUid = athlete.uid` |
| Accept / Decline request | TextButton | Approves or rejects coach request |

---

## 2. Navigation Map

```
LoginScreen
  ├─ Sign In success         → HomeScreen
  ├─ Google Sign In          → HomeScreen  (via CreateNewAccountScreen if new)
  ├─ Sign Up                 → CreateNewAccountScreen
  └─ Forgot Password         → ForgotPasswordScreen

CreateNewAccountScreen
  └─ Account created         → HomeScreen

HomeScreen
  ├─ Calendar: tap date      → WorkoutSessionScreen (scheduledDate = tapped day)
  ├─ Calendar: empty "Start" → WorkoutSessionScreen (scheduledDate = selected day)
  ├─ Blocks tab              → PlannedBlocksPage
  ├─ Templates tab           → TemplatesScreen
  └─ More tab
       ├─ Social             → SocialHubScreen
       ├─ Messages           → DirectMessagesScreen
       ├─ Profile            → ProfileScreen
       └─ Coach              → CoachDashboardScreen

PlannedBlocksPage
  ├─ Tap block               → BlockPlannerScreen (edit)
  └─ Add Block               → BlockPlannerScreen (new)

BlockPlannerScreen
  └─ Save                    → PlannedBlocksPage

TemplatesScreen
  ├─ Use template            → WorkoutSessionScreen (initialCircuits from template)
  └─ History button          → TemplateHistoryScreen

WorkoutSessionScreen
  ├─ Tap exercise name       → ExerciseDetailsScreen
  ├─ Top sets button         → TopSetsScreen
  ├─ Save Workout (success)  → pops; triggers onLogsSaved (increments refreshToken)

ExerciseDetailsScreen
  └─ Top Sets                → TopSetsScreen

TopSetsScreen
  └─ Tap set row             → WorkoutDetailsScreen

ProfileScreen
  ├─ View analytics          → ProgressDashboard
  └─ Add coach               → RequestAthleteAccessPage

SocialHubScreen
  ├─ Tap post                → PostDetailScreen
  ├─ Tap user (leaderboard)  → ProfileScreen (read-only)
  └─ Add gym buddy           → AddGymBuddyScreen

CoachDashboardScreen
  ├─ Edit block (athlete)    → BlockPlannerScreen (targetUid)
  └─ Start workout (athlete) → WorkoutSessionScreen (targetUid)
```

---

## 3. Progression & Calculation Reference

### 3.1 E1RM Formula

```
totalReps = reps + rir

If totalReps ≤ 25:  E1RM = weight × (36 / (37 − totalReps))   [Brzycki]
If totalReps > 25:  E1RM = weight × (1 + 0.0333 × totalReps)  [Epley]
```

Inverse — working weight from target E1RM:
```
If totalReps ≤ 25:  weight = E1RM × (37 − totalReps) / 36
If totalReps > 25:  weight = E1RM / (1 + 0.0333 × totalReps)
```

### 3.2 Best Set Resolver — 8-Tier Cascade

| Tier | Source | Condition |
|------|--------|-----------|
| 1 | Block planner `bestWeight` + `bestReps` | `bestWeight > 0` |
| 2 | Onboarding `plannedEntry['e1rm']` | `plannedE1rm > 0` |
| 3 | Onboarding string `"100 X 5"` (maxWeightByReps_manual / maxWeightXReps) | Parseable |
| 4 | Pre-computed `targets.sessions[].impliedE1RM` | First non-zero value |
| 5 | Workout history via `E1rmHistoryService.computeBaseE1rm()` | `topSets` non-empty |
| 6 | Related exercise planned entry (scaled) | Related exercise found in `allPlannedEntries` |
| 7 | Related exercise history (scaled) | Related exercise found in `allTopSets` |
| 8 | Equipment-type default | Fallback |

Equipment defaults (kg E1RM):
- Bodyweight exercises → 0 (skip)
- Barbell OHP → 10
- Other barbell / squat / deadlift / bench press → 20
- Dumbbell / cable → 10
- Machine / smith → 30
- Everything else → 5

### 3.3 Bests Service — Data Written on Each Save

On `WorkoutSessionScreen.Save`:
1. `BestsService.updateFromWorkoutSets(uid, exerciseName, sets)` called per exercise.
2. Per exercise doc at `users/{uid}/bests/{docId}`:
   - `maxE1rm` — all-time highest E1RM
   - `maxWeightAtReps["{n}"]` — best weight for exactly n reps
   - `topSetHistory` — best set per day, newest first, max 24 entries
   - `lastUpdated` — server timestamp

Doc ID derivation: `exerciseName.toLowerCase().replaceAll(/[^a-z0-9]+/, '_')`.
Example: `"Bench Press, Barbell"` → `"bench_press__barbell"`.

### 3.4 WorkoutSessionCache — Bidirectional Sync (GAP 6)

**Local key**: `workout_draft_{uid}_{blockId}_{date}`

**Firestore path**: `users/{uid}/sessionDrafts/{dateStr}` (dateStr = "2026-03-28")

**Conflict resolution** on `_loadDraft()`:
1. Read local draft via SharedPreferences.
2. Pull remote draft from Firestore.
3. Resolve:
   - If `remote.lastEditedBy == 'coach'` → remote wins always.
   - Else most-recent `updatedAt` wins.
   - Tie or both null → local wins (offline-first).
4. If remote won, persist it locally for offline continuity.

**Debounced push** in `_cacheDraft()`: 4 s after last edit → `pushToFirestore()`.

---

## 4. Test Cases

### 4.1 Authentication

| ID | Scenario | Steps | Expected Result |
|----|----------|-------|-----------------|
| AUTH-01 | Valid email/password login | Enter correct credentials → tap Sign In | Navigates to HomeScreen; user doc is loaded |
| AUTH-02 | Wrong password | Enter correct email, wrong password → Sign In | Error snackbar: "Wrong password" or Firebase message; stays on LoginScreen |
| AUTH-03 | Non-existent email | Enter unknown email → Sign In | Error snackbar: "No user found"; stays on LoginScreen |
| AUTH-04 | Empty fields | Tap Sign In with empty fields | Validation error shown; no network call |
| AUTH-05 | Google sign-in (new user) | Tap Google → complete Google flow | Creates user doc → navigates to HomeScreen (or CreateNewAccountScreen for username setup) |
| AUTH-06 | Google sign-in (existing) | Tap Google → complete Google flow | Authenticates existing user → HomeScreen |
| AUTH-07 | Forgot password | Enter email → Send Reset Link | Success message; Firebase sends reset email |
| AUTH-08 | Forgot password — bad email | Enter malformed email → Send Reset Link | Validation error; no Firebase call |

---

### 4.2 Account Creation

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| AC-01 | All fields valid | Account created; 3 default blocks bootstrapped; templates bootstrapped; navigates to HomeScreen |
| AC-02 | Passwords don't match | "Passwords do not match" validation error; form not submitted |
| AC-03 | Username already taken | Username field shows "Username taken" indicator; Create Account button disabled |
| AC-04 | Username available | Green checkmark shown after debounce |
| AC-05 | Invalid DOB (e.g., 31/02/xxxx) | Validation error |
| AC-06 | Email already registered | Firebase error displayed; user prompted to sign in |

---

### 4.3 Block Planning

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| BP-01 | Create block with 3 exercises, 4-day week, 8-week duration | Block saved to `users/{uid}/blocks/{id}`; schedule generated; calendar shows workouts for correct dates |
| BP-02 | Edit existing block — change start date | Schedule re-generated; old cached schedule invalidated (plan signature changes) |
| BP-03 | Add exercise with `bestWeight=100, bestReps=5` | Tier 1 resolver used; E1RM = `100 × (36/(37−5))` = 112.5 kg |
| BP-04 | Delete exercise from active block | Exercise removed from week schedule immediately; Firestore updated |
| BP-05 | Assign template to Monday | `templateAssignments['0']['1'] = templateId` written to block doc |
| BP-06 | Toggle group-by-templates | Week schedule renders template name headers between exercise rows |
| BP-07 | Save block without any exercises | Validation error; save blocked |
| BP-08 | Save block with end date before start date | Validation error; save blocked |
| BP-09 | Drag to reorder exercises | Order persisted to Firestore on save |

---

### 4.4 Schedule Screen (Week Schedule Tab)

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| SCH-01 | Open WeekScheduleTab for a 3x/week block | Three day columns populated with exercises; rest days empty |
| SCH-02 | Body part cap — add 3 chest exercises to 3-day block | Third chest exercise assigned to a different day (daily body-part cap = 2) |
| SCH-03 | Exercise with weekly frequency 2 in a 3-day block | Exercise appears on exactly 2 of 3 training days |
| SCH-04 | Exercise with preferred day = Wednesday | Exercise preferentially placed on Wednesday column |
| SCH-05 | Group-by-templates enabled | Template name header renders above first exercise belonging to each template |
| SCH-06 | Group-by-templates disabled (default) | No template headers; exercises listed flat |
| SCH-07 | Plan signature changes when template exercise changes | On next open, cached draft discarded; fresh schedule loaded |

---

### 4.5 Workout Session Screen

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| WSS-01 | Open session for today (has scheduled workout) | Circuits populated from schedule; weight/rep hints shown |
| WSS-02 | Open session for today (no scheduled workout) | Empty session; user can add exercises manually |
| WSS-03 | Tap exercise name | Navigates to ExerciseDetailsScreen with exercise pre-selected |
| WSS-04 | Tap check icon on exercise (complete) | Check icon turns green; all set fields become read-only |
| WSS-05 | Tap check icon again (un-complete) | Exercise becomes editable; all actual values cleared; SetRow keys change → `_userTyped*` flags reset |
| WSS-06 | Enter weight + reps + RIR in a set | E1RM display updates immediately |
| WSS-07 | Delete a set | Set removed; remaining sets renumber |
| WSS-08 | Add a set | New empty row appended; inherits planned values as hints |
| WSS-09 | Drag to reorder sets | Order visually updated; persisted in draft |
| WSS-10 | Save with all sets empty | Validation error; no Firestore write |
| WSS-11 | Save with all sets filled | Writes logs; calls `BestsService.updateFromWorkoutSets()`; triggers `onLogsSaved`; pops screen |
| WSS-12 | Navigate away mid-session (back button) | Draft saved to SharedPreferences; Firestore push queued (fires in ≤4 s) |
| WSS-13 | Return to same date session | Draft restored from local cache (or remote if coach edited) |
| WSS-14 | Coach edits session remotely | On next `_loadDraft()`, remote wins; local is overwritten; session updates |
| WSS-15 | Change date via date picker | `_selectedDate` updates; `_draftKey` rebuilds; new draft loaded for that date |
| WSS-16 | Load session for a date that had a saved draft from legacy key format | `readWithMigration()` finds legacy key; migrates to canonical key; draft loaded correctly |

---

### 4.6 Set Progression — Expected Values

This section defines the exact numeric values the app should compute for specific inputs. Use these for regression testing of the E1RM and weight-hint pipeline.

#### E1RM Calculations

| Input (weight × reps @ RIR) | totalReps | Formula | Expected E1RM |
|-----------------------------|-----------|---------|---------------|
| 100 kg × 5 reps @ 0 RIR | 5 | Brzycki | 100 × (36/32) = **112.50 kg** |
| 100 kg × 5 reps @ 1 RIR | 6 | Brzycki | 100 × (36/31) = **116.13 kg** |
| 100 kg × 8 reps @ 0 RIR | 8 | Brzycki | 100 × (36/29) = **124.14 kg** |
| 100 kg × 8 reps @ 2 RIR | 10 | Brzycki | 100 × (36/27) = **133.33 kg** |
| 80 kg × 12 reps @ 0 RIR | 12 | Brzycki | 80 × (36/25) = **115.20 kg** |
| 80 kg × 12 reps @ 3 RIR | 15 | Brzycki | 80 × (36/22) = **130.91 kg** |
| 60 kg × 20 reps @ 0 RIR | 20 | Brzycki | 60 × (36/17) = **127.06 kg** |
| 60 kg × 25 reps @ 0 RIR | 25 | Brzycki | 60 × (36/12) = **180.00 kg** |
| 60 kg × 26 reps @ 0 RIR | 26 | Epley | 60 × (1 + 0.0333×26) = **111.95 kg** |
| 40 kg × 30 reps @ 0 RIR | 30 | Epley | 40 × (1 + 0.0333×30) = **79.96 kg** |

> **Note**: The Epley formula intentionally produces lower values than Brzycki for the same rep count — this is why the boundary at 25 reps causes a discontinuity. The app switches formulas at `totalReps > 25`.

#### Reverse Weight (working weight from E1RM target)

Given target E1RM = 120 kg:

| reps | RIR | totalReps | Formula | Expected working weight |
|------|-----|-----------|---------|------------------------|
| 5 | 0.5 | 5.5 | Brzycki | 120 × (31.5/36) = **105.00 kg** |
| 8 | 0.5 | 8.5 | Brzycki | 120 × (28.5/36) = **95.00 kg** |
| 12 | 0.5 | 12.5 | Brzycki | 120 × (24.5/36) = **81.67 kg** |
| 3 | 0.5 | 3.5 | Brzycki | 120 × (33.5/36) = **111.67 kg** |

> These are the values shown as weight hints in the workout session screen.

#### Reverse Reps (effective reps from weight + E1RM target)

Given target E1RM = 120 kg, weight = 90 kg, RIR = 0.5:
```
ratio = 120 / 90 = 1.3333
totalReps = 37 − (36 / 1.3333) = 37 − 27 = 10
reps = totalReps − rir = 10 − 0.5 = 9.5 → rounds to display
```
Expected: **~9–10 reps**

---

### 4.7 E1RM Calculation Test Cases

| ID | Input | Expected E1RM | Tolerance |
|----|-------|---------------|-----------|
| E1-01 | 100 kg × 5 @ 0 RIR | 112.50 kg | ±0.01 |
| E1-02 | 100 kg × 5 @ 1 RIR | 116.13 kg | ±0.01 |
| E1-03 | 100 kg × 8 @ 0 RIR | 124.14 kg | ±0.01 |
| E1-04 | 80 kg × 12 @ 0 RIR | 115.20 kg | ±0.01 |
| E1-05 | 80 kg × 12 @ 3 RIR | 130.91 kg | ±0.01 |
| E1-06 | 60 kg × 25 @ 0 RIR | 180.00 kg | ±0.01 |
| E1-07 | 60 kg × 26 @ 0 RIR | 111.95 kg | ±0.01 (Epley boundary) |
| E1-08 | 0 kg × 8 @ 0 RIR | null (invalid weight) | — |
| E1-09 | 80 kg × 0 @ 0 RIR | null (invalid reps) | — |
| E1-10 | `calculateE1rmSafe(weight: null, ...)` | null | — |
| E1-11 | Hierarchy: logged=100/5, planned=80/5 | 112.50 kg (logged wins) | ±0.01 |
| E1-12 | Hierarchy: logged=null, edited=80/8 | 98.76 kg | ±0.01 |

---

### 4.8 Best Set Resolver — Tier Cascade Tests

| ID | Scenario | Expected source | Expected E1RM |
|----|----------|-----------------|---------------|
| BSR-01 | `bestWeight=100, bestReps=5` in block planner | `manual` | 112.50 kg |
| BSR-02 | No bestWeight; `plannedEntry.e1rm=120` | `onboarding_e1rm` | 120.00 kg |
| BSR-03 | No bestWeight, no e1rm; `maxWeightByReps_manual="100 X 5"` | `onboarding_manual` | 112.50 kg |
| BSR-04 | No manual data; `targets.sessions[0].impliedE1RM=115` | `targets` | 115.00 kg |
| BSR-05 | No manual data; top sets exist with best 100kg × 5 | `history` | ~112.50 kg (history-computed) |
| BSR-06 | Exercise "DB Bench Press"; related "Bench Press, Barbell" with E1RM 130; scale=0.8 | `related_planned` | 104.00 kg |
| BSR-07 | Exercise "Barbell Squat"; no data anywhere | `equipment_default` | 20.00 kg (barbell default) |
| BSR-08 | Exercise "Pull Up"; no data | `equipment_default` | 0.00 kg (bodyweight → skipped) |
| BSR-09 | Exercise "Dumbbell Curl"; no data | `equipment_default` | 10.00 kg |
| BSR-10 | Exercise "Leg Press Machine"; no data | `equipment_default` | 30.00 kg |

---

### 4.9 Calendar & Auto-Refresh

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| CAL-01 | Save workout from calendar day | `_calendarRefreshToken` increments → `TrainingCalendar.didUpdateWidget()` detects token change → re-fetches data |
| CAL-02 | Navigate to date with no logs | Calendar cell is empty; "Start Workout" FilledButton shown in detail area |
| CAL-03 | Navigate to date with logged workouts | Workout summary tiles shown; exercises listed; E1RMs displayed |
| CAL-04 | Workout logged outside active block | Tile shows block name annotation (via `activeBlockId` + `blockNames` map) |
| CAL-05 | Two workouts on same day (different blocks) | Both show; each annotated with its block name |
| CAL-06 | `refreshToken` unchanged, same day selected | `didUpdateWidget()` does NOT re-fetch (no flicker) |

---

### 4.10 Templates

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| TPL-01 | Create template with 2 circuits, 3 exercises each | Saved to `users/{uid}/templates/{id}`; appears in TemplatesScreen |
| TPL-02 | Assign template to block day | `templateAssignments['0']['1'] = templateId` on block doc |
| TPL-03 | Load template into WorkoutSession | `initialCircuits` populated; exercises + planned sets shown |
| TPL-04 | Template version = 0 | History button NOT shown on template card |
| TPL-05 | Template version = 1 | History button (clock icon) shown; navigates to TemplateHistoryScreen |
| TPL-06 | Delete template | Removed from Firestore; removed from TemplatesScreen; block `templateAssignments` should still reference old id (not cascaded) |
| TPL-07 | Plan signature changes when template exercise list changes | Cached schedule invalidated on next session load |

---

### 4.11 Personal Records (Bests)

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| PR-01 | First-ever log: Bench Press 80kg × 8 @ 0 RIR | Creates bests doc; `maxE1rm = 98.76`; `maxWeightAtReps["8"] = 80`; `topSetHistory` has 1 entry |
| PR-02 | Second log same day: Bench Press 85kg × 5 @ 0 RIR (E1RM 95.63) | `maxE1rm` stays 98.76 (previous was higher); `maxWeightAtReps["5"] = 85`; `topSetHistory` still has 1 entry (best set per day) |
| PR-03 | New day log: Bench Press 90kg × 8 @ 0 RIR (E1RM 110.34) | `maxE1rm` updates to 110.34; `topSetHistory` gains 1 entry (now 2 entries total) |
| PR-04 | After 24 days of training | `topSetHistory` has exactly 24 entries (capped at `_maxHistoryEntries`) |
| PR-05 | Doc ID for "Bench Press, Barbell" | `"bench_press__barbell"` |
| PR-06 | Doc ID for "Dumbbell Curl" | `"dumbbell_curl"` |
| PR-07 | Save with sets missing weight or reps | Those sets silently skipped; only valid sets contribute to bests |

---

### 4.12 Exercise History & Analytics

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| EH-01 | Open ExerciseDetailsScreen with 6 months of Bench Press data | Line chart renders; trend line shown; data points match logged E1RMs |
| EH-02 | Switch rep group to "5" | Chart filters to sets where reps = 5; other sets excluded |
| EH-03 | Switch trend range to 7d | Only last 7 days of data visible |
| EH-04 | Include RIR toggle on | E1RM recalculated with RIR included in totalReps |
| EH-05 | Include RIR toggle off | E1RM uses only reps (rir=0) for chart display |
| EH-06 | Exercise with no history | Chart empty; "No data" message shown |

---

### 4.13 Weight Tracking

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| WT-01 | Add weight entry: 80 kg on 2026-03-28 | Written to `users/{uid}/weight_entries/2026-03-28`; appears in chart |
| WT-02 | Switch to 7-day average | Chart shows rolling 7-day average line; individual points may be smoothed |
| WT-03 | Delete weight entry | Removed from Firestore; chart updates |
| WT-04 | Weight unit set to lbs | Display shows 80 kg as 176.4 lbs; new entries accepted in lbs and stored as kg |

---

### 4.14 Social Features

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| SOC-01 | Create post (text only) | Post written to `posts/{id}`; appears in feed |
| SOC-02 | Like a post | Like toggled; like count increments; unlike on second tap |
| SOC-03 | Add comment | Comment appended to post; appears in PostDetailScreen |
| SOC-04 | Delete own post | Removed from Firestore; removed from feed |
| SOC-05 | Leaderboard filter: Bench Press | Ranks users by Bench Press E1RM descending |
| SOC-06 | Send coach request | Relationship doc created with `status: pending` |
| SOC-07 | Accept coach request | `status` updated to `accepted`; coach can now view athlete |

---

### 4.15 Coach Dashboard

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| CD-01 | Coach views athlete's calendar | TrainingCalendar renders with `targetUid = athlete.uid`; shows athlete's logs |
| CD-02 | Coach edits athlete's block | BlockPlannerScreen opens with `targetUid`; saves to athlete's `users/{athleteUid}/blocks/{id}` |
| CD-03 | Coach starts workout for athlete | WorkoutSessionScreen opens with `targetUid`; drafts saved under athlete's uid |
| CD-04 | Coach saves session for athlete | Logs written to `users/{athleteUid}/workout_logs/…`; athlete's bests updated |
| CD-05 | Coach edits session mid-flight | Session pushed to `users/{athleteUid}/sessionDrafts/{date}` with `lastEditedBy: 'coach'` |
| CD-06 | Athlete opens same session after coach edits | Conflict resolution: `lastEditedBy == 'coach'` → remote wins; athlete sees coach's version |

---

## 5. RE-Test-Main Progression Comparison

*This section documents how the progression logic in the `origin/RE-Test-Main` branch compares with the current `claude-dev-02` branch, and identifies confirmed gaps that require implementation work.*

---

### 5.1 Branch Architecture Overview

| Aspect | RE-Test-Main | claude-dev-02 |
|--------|-------------|---------------|
| Architecture | Monolithic `workout_entry_screen.dart` (~16k lines) + `progression_engine.dart` | Modular: `circuit_card.dart` → `set_hint_resolver.dart` → `set_fatigue_service.dart` → `best_set_resolver.dart` |
| State | `_weightControllers[exIdx][setIdx]` TextEditingControllers per set | `SetLog.weight/reps/rir` fields on `ExerciseSession.loggedSets` |
| Hint computation | Async `FutureBuilder` calling `_weightHintText()` / `_repsHintText()` per set | Synchronous `_buildSetHints()` loop in `_CircuitCardState` |
| Type safety | Loose `dynamic` maps throughout | Typed `SetHintInputs` / `SetHintResult` / `SetHintOutputs` |
| Cascade anchor tracking | `_actualE1RMForSet()` reads typed-or-hint value from controllers | `set1E1rm` variable re-anchored at each set with logged weight |

---

### 5.2 Feature A — Multi-set Weight Propagation

**Desired behaviour:** Editing weight on Set N propagates updated hints to Sets N+1, N+2 … without affecting Sets 1 … N−1.

#### RE-Test-Main implementation
File: `workout_entry_screen.dart`

Key functions:
- `_typedOrHintWeightAbs(exIdx, setIdx)` — returns user-typed weight if present in controller, otherwise the last-computed hint value
- `_targetE1RMForSet(exIdx, setIdx)` — if `setIdx == 0`, computes from plan/history; for `setIdx ≥ 1`, bases on previous set's actual E1RM + RIR-gated drop
- `_synthesizeHintsForSet(exIdx, setIdx)` — solves for weight/reps range at the target E1RM

Cascade logic:
```
Set N weight typed
  → _typedOrHintWeightAbs(N) returns typed value
  → _actualE1RMForSet(N) = E1RM(typedWeight_N, typedOrHintReps_N, rir_N)
  → _targetE1RMForSet(N+1) uses _actualE1RMForSet(N) as base
  → _synthesizeHintsForSet(N+1) resolves weight range at targetE1RM(N+1)
```

Upstream blocking: Enforced by the call direction — `_targetE1RMForSet(k)` only ever reads from `k-1`, never from `k+1`.

#### Current branch implementation
File: `circuit_card.dart`, function `_buildSetHints()` (line 467)

```dart
if (index == 0 || log.weight != null) {
  final liveE1rm = calculateE1rmSafe(
    weight: log.weight,
    reps: log.reps ?? targetReps,
    rir: log.rir ?? targetRir,
  );
  if (liveE1rm != null) set1E1rm = liveE1rm;
  else if (index == 0) set1E1rm = result.targetE1rm;
}
```

When a logged weight exists on Set N, `set1E1rm` is updated to that set's live E1RM. The `computeTargetE1rmForSet()` in `set_fatigue_service.dart` then applies progressive drops from this new base for all subsequent sets.

**Status: EQUIVALENT** — both branches propagate weight changes downstream and block upstream propagation.

---

### 5.3 Feature B — Ad-hoc Workout History Lookup

**Desired behaviour:** When the session has no block/schedule context (ad-hoc workout), hints are computed from logged workout history — the same code path as scheduled workouts.

#### RE-Test-Main implementation
Unified path: `_targetE1RMForSet()` → calls `_actualE1RMForSet()` → reads `PeriodizationModelUtils.topSetsByExercise[exerciseName]` for history. No separate ad-hoc branch exists.

#### Current branch implementation
`BestSetResolver.resolve()` (`best_set_resolver.dart`):
- Tier 5: `E1rmHistoryService.computeBaseE1rm(topSets, ...)` — searches history using a 4-level priority (recent match ≤28d, 2-week avg, last-4 avg, all-avg)
- The same resolver is called regardless of whether the session was started from a schedule or as ad-hoc

The `WorkoutSessionScreen` loads `topSets` for each exercise from `BestsService` before the session starts; this data feeds `BestSetResolver` in both scheduled and ad-hoc contexts.

**Status: EQUIVALENT** — both branches use a unified history-lookup path for ad-hoc and scheduled workouts. The current branch's `BestSetResolver` 8-tier cascade is more robust than the RE-Test-Main approach.

---

### 5.4 Feature C — Dynamic Reps Ranges and Rep-Anchored Weight Hints *(CONFIRMED GAP — LARGER THAN INITIALLY DOCUMENTED)*

**Desired behaviour:** For Sets 2+, both the reps hint and weight hint are computed dynamically from the previous set's weight, not from a static planned value. Reps are shown as a range (e.g. "6–8") that narrows with fatigue. Weight options span a ±7.5% tolerance band of valid increments.

#### RE-Test-Main implementation — `_synthesizeHintsForSet(exIdx, setIdx)`

This function (Sets 2+ only) is the core of the cascade. For each Set N:

```
1. prevWAbs = previous set's effective weight (_typedOrHintWeightAbs(N-1))
2. targetE1RM = fatigue-dropped E1RM for Set N (_targetE1RMForSet(N))

3. repsNeeded = reverseCalculateReps(targetE1RM, weight=prevWAbs, rir)
   → "at the previous set's weight, how many reps hit this set's target E1RM?"

4. repsMid = repsNeeded.round()
   repsRange = {repsMid-1, repsMid, repsMid+1}

5. weightMid = reverseCalculateWeight(targetE1RM, repsMid, rir)
   weightRange = valid increment options within ±7.5% of weightMid
                 (capped: never exceeds previous set's weight)

6. Cross-filter: keep only (reps, weight) pairs where
   |E1RM(weight, reps, rir) − targetE1RM| ≤ tolKg
   (tolKg = 0.3 for Group D isolation, 0.7 for all other groups)

7. Return: repsRange (filtered list), weightRangeDisplay (filtered list)
   Displayed as "6–8" for reps, "90–92.5" for weight
```

**Real example from the user (105 kg × 3 reps → changed to 8 reps on Set 1):**
```
Set 1: weight=105, reps typed as 8
  → Set 1 E1RM = E1RM(105, 8, rir) ≈ 130 kg

Set 2 synthesis:
  prevWAbs = 105 kg (Set 1's weight)
  targetE1RM_set2 = 130 − fatigueDrop ≈ 125.6 kg
  repsNeeded = reverseCalculateReps(125.6, weight=105, rir)
             = reps where E1RM(105, r, rir) = 125.6 → ~7
  repsRange = {6, 7, 8} → displayed as "6–8"
  weightMid = reverseCalculateWeight(125.6, 7, rir) ≈ 100 kg
  weightRange = valid increments near 100 kg

Set 3 synthesis:
  prevWAbs = Set 2's hint weight ≈ 100 kg
  targetE1RM_set3 ≈ 121.2 kg
  repsNeeded = reverseCalculateReps(121.2, weight=100, rir) → ~6
  repsRange = {5, 6, 7} → after tolerance filtering collapses to "6"
  weightRange = valid increments near reverseWeight(121.2, 6, rir)
```

#### Current branch — what is missing

The current `SetHintResolver` and `WeightRepsHintResolver`:
- Use `plannedReps` from the schedule as the reps hint — **not dynamically computed from prevWAbs**
- Return a **single `repsHintValue`** — no range
- Return a **single `weightHintKg`** — no range
- Do not call `reverseCalculateReps(targetE1RM, prevSetWeight, rir)` for downstream sets
- Do not cross-filter (reps, weight) pairs by E1RM tolerance
- Do not enforce the "never exceed previous set's weight" cap on the weight range

The re-anchor fix applied to `_buildSetHints()` (line 539) correctly ensures the E1RM anchor updates when reps are logged. However, this only propagates when the user has already *typed* a value. The underlying hint computation for unedited downstream sets still uses planned reps, not dynamically synthesised reps.

#### Practical impact

| User action | RE-Test-Main result | Current branch result |
|-------------|--------------------|-----------------------|
| Set 1: change reps 3→8 (weight unchanged) | Set 2 shows "6–8 reps" + weight range; Set 3 shows "6 reps" + weight | Set 2 shows planned reps; weight hint unchanged unless weight was also logged |
| Set 1: type weight 100 | Set 2 reps range adjusts to match new anchor weight | Set 2 weight hint adjusts; reps hint stays at planned value |
| Set 2: type reps only | Sets 3+ reps ranges recalculate from Set 2's hint weight + new reps | Re-anchors E1RM correctly (post-fix); reps hint stays at planned value |
| No user input at all | Shows synthesised reps range + weight range for Sets 2+ | Shows planned reps + single weight hint |

#### What needs to be built

This is a standalone feature addition. The key work is:

1. **`_synthesizeHintsForSet` equivalent** — a new method in `SetHintResolver` (or a dedicated `SetRangeSynthesiser` service) that implements the algorithm above: takes `prevSetWeightKg`, `targetE1rm`, `rir`, `incrementOptions`, `toleranceKg` and returns `({List<int> repsRange, List<double> weightRangeKg})`.

2. **`SetHintResult` extension** — add `repsRangeMin`, `repsRangeMax`, `weightRangeMinKg`, `weightRangeMaxKg` alongside existing single-value fields, so the UI can display "6–8" or collapse to "6" when min == max.

3. **`_buildSetHints` wiring** — pass `previous.effectiveWeightKg` as the anchor weight for Set N's synthesis, replacing the current `plannedReps`-based approach for cascade sets (`isCascadeSet == true`).

4. **UI display** — update `_SetRow` in `circuit_card.dart` to render hint text as a range when `repsRangeMin != repsRangeMax`.

---

### 5.5 Summary Gap Table

| Feature | RE-Test-Main | claude-dev-02 | Action required |
|---------|-------------|---------------|-----------------|
| Weight edit on Set N → downstream weight hints update | ✅ | ✅ | None |
| Ad-hoc workout uses same history path as scheduled | ✅ | ✅ | None |
| Reps edit on Set N (with logged weight) → downstream updates | ✅ | ✅ (post re-anchor fix) | None |
| Reps edit on Set N (no logged weight) → downstream anchor updates | ✅ | ✅ (post re-anchor fix) | None |
| RIR edit on Set N → downstream gating updates | ✅ | ✅ (`previousSetRirs` list) | None |
| Upstream sets never changed by downstream edit | ✅ | ✅ (forward-only loop) | None |
| Sets 2+ reps hint dynamically solved from prevSetWeight + targetE1RM | ✅ | ✗ (uses plannedReps) | New `_synthesizeHintsForSet` logic |
| Sets 2+ reps shown as a range (e.g. "6–8") | ✅ | ✗ (single value only) | Extend `SetHintResult` + UI |
| Sets 2+ weight shown as a range (e.g. "90–92.5") | ✅ | ✗ (single value only) | Extend `SetHintResult` + UI |
| (reps, weight) cross-filtered by E1RM tolerance | ✅ | ✗ | Part of new synthesis logic |
| Weight range capped at previous set's weight | ✅ | ✗ | Part of new synthesis logic |

---

### 5.6 Test Cases — Progression Cascade

These complement the existing §4.6 test cases and specifically target the cascade behaviour.

| ID | Scenario | Setup | Expected Result (RE-Test-Main) | Current branch |
|----|----------|-------|--------------------------------|----------------|
| PC-01 | Weight edit Set 1 → Sets 2, 3 update | Set 1: log weight=100. Sets 2, 3 empty | Sets 2 and 3 weight hints increase from new 100 kg anchor | ✓ Working |
| PC-02 | Weight edit Set 2 → Sets 3, 4 update; Set 1 unchanged | Set 2: log weight=90. Sets 3, 4 empty | Set 1 hint unchanged; Sets 3 and 4 recompute from Set 2 anchor | ✓ Working |
| PC-03 | Reps edit Set 1 from 3→8 | Set 1: weight=105, reps changed to 8 | Set 2: "6–8 reps" + weight range near 100 kg; Set 3: "6 reps" + lower weight | ✗ Gap (reps range) |
| PC-04 | Reps edit Set 2, weight also logged | Set 2: log weight=85, reps=10. Sets 3, 4 empty | Set 2 E1RM = E1RM(85, 10, rir); Sets 3 and 4 re-anchor and synthesise | ✓ Working (anchor); ✗ Gap (reps range) |
| PC-05 | RIR edit Set 2 → Set 3 gating changes | Set 2: log rir=0. Set 3 empty | Set 3 receives full fatigue drop (rir < 1.8 → 100% of rawDrop) | ✓ Working |
| PC-06 | Ad-hoc workout — no block context | Session outside any block, add "Bench Press, Barbell" | Set 1 hint from BestsService history (or 20 kg default) | ✓ Working |
| PC-07 | Ad-hoc workout — exercise with prior logs | Prior log: Bench Press 100×5 | Set 1 hint = `reverseWeight(E1rm_from_history, plannedReps, rir)` | ✓ Working |
| PC-08 | Group A fatigue (Bench Press, 3 sets, RIR=2) | Set 1 E1RM = 133 kg. RIR 2.0 → 80% gating → 4.4 kg drop | Set 2 target = **128.6 kg**; Set 3 = **124.2 kg** | ✓ Working |
| PC-09 | Group A, easy previous set (RIR > 2) | Set 1 E1RM = 133 kg. Set 1 RIR = 3.0 | Set 2 target = **133 kg** (0% gating) | ✓ Working |
| PC-10 | Group D isolation (Bicep Curl) | Set 1 E1RM = 50 kg. RIR = 1.5 | Set 2 target = **49.7 kg** (0.3 kg drop) | ✓ Working |
| PC-11 | Group B overhead (OHP), 4 sets, RIR = 1.5 | Set 1 E1RM = 80 kg | Set 2: **78.5**; Set 3: **74.2**; Set 4: **72.7** | ✓ Working |
| PC-12 | Reps range — no user input, Sets 2+ | Set 1 E1RM = 133 kg (Group A). Set 2 empty, prevWeight = 100 kg | Set 2 reps range = reverseReps(128.6, 100, rir) ± 1 → e.g. "6–8" | ✗ Gap |
| PC-13 | Weight range cap — never exceeds prev set | Set 2 weight band computed. Set 1 weight = 100 kg | All Set 2 weight candidates ≤ 100 kg | ✗ Gap |

---

### 5.7 Fatigue Drop Reference Table

| Exercise Group | Examples | Drop per set (kg E1RM) | RIR > 2.0 | RIR 1.8–2.0 | RIR < 1.8 |
|----------------|----------|----------------------|-----------|-------------|-----------|
| A — Heavy Compounds | Bench Press, Squat, Deadlift, Chin-Up | 5.5 | 0.0 | 4.4 | 5.5 |
| B — Overhead | OHP, Military Press, Push Press | 1.5 (S2), 4.3 (S3), 1.5 (S4+) | 0.0 | ×0.8 | ×1.0 |
| C — Other Compounds | Rows, Dips, Lunges, DB Press | 1.0 | 0.0 | 0.8 | 1.0 |
| D — Isolation | Curls, Laterals, Extensions, Flies | 0.3 | 0.0 | 0.24 | 0.3 |

---

## Appendix A: Known Behavioral Nuances

1. **E1RM discontinuity at 25 reps**: Brzycki produces significantly higher values than Epley at 25 reps (e.g., 180 kg vs ~112 kg for the same input). This is mathematically correct per the formulas but may surprise users. No fix is applied — both formulas are industry-standard.

2. **`_userTyped*` stale flag fix**: If an exercise is marked complete then un-completed, the `_SetRow` widget is fully recreated via `ValueKey('${ex.exercise}_${ex.completed}_$j')`, clearing all internal state. Without this, hint labels would stay suppressed even though actuals were cleared.

3. **Legacy key migration**: Three old cache key formats are automatically migrated to the canonical format on first read. This happens silently — users will not notice.

4. **Schedule invalidation**: When the plan signature stored in a draft no longer matches the current schedule's signature (e.g., after template changes), the draft is discarded and a fresh schedule is loaded. The signature is a content hash computed after templates are loaded.

5. **Offline-first**: On draft load, if Firestore is unreachable, the local SharedPreferences draft is used. The Firestore push is fire-and-forget (errors logged, not surfaced to UI).

6. **Block body-part cap**: The workout-map distributer applies a cap of 2 exercises per body part per training day (`kDailyBodyPartCap`). Exercises without body-part tags are distributed round-robin with no cap.

7. **Bodyweight exercise E1RM display**: For pull-ups, dips, etc., the displayed E1RM subtracts the user's logged bodyweight so it represents "added weight" strength — not total-weight E1RM.