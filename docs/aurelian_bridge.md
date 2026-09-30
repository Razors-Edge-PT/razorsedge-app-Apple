# Aurelian voice bridge (GoodLift side)

Aurelian is Richard's personal, sideloaded Android voice assistant. From Aurelian Milestone 2 it
controls GoodLift through this first-party bridge rather than by tapping the screen: GoodLift runs
each voice command with its own code, through the same WES2 controller, save and durable-outbox
paths as the ordinary UI. Android only; iOS is untouched (nothing is attached off Android).

```
Aurelian ─explicit Intent─► MainActivity ─► AurelianBridge (native)
             verify caller ─► parse & bound ─► queue until Dart is ready
             "command" over MethodChannel goodlift/aurelian ─► AurelianCommandBus (Dart)
             screen handler (Home / WES2 / picker / Analytics / root) ─► canonical operation
             result ─► Aurelian's one-shot reply PendingIntent (exactly once)
```

## Protocol (version 1)

Mirrored exactly in Aurelian's `execution/goodlift/GoodLiftProtocol.kt`.

| | |
|---|---|
| Target | package `com.goodlift.razorsedge`, activity `com.goodlift.razorsedge.MainActivity` (the canonical current package; legacy Good Lift packages are never used) |
| Action | `com.goodlift.razorsedge.action.AURELIAN_COMMAND` (intent filter on MainActivity, category DEFAULT) |
| Extras | `aurelian.protocol` (Int = 1), `aurelian.requestId` (`[A-Za-z0-9-]{1,64}`), `aurelian.command`, `aurelian.sentAtElapsed` (Long, `SystemClock.elapsedRealtime()`), `aurelian.caller` (immutable PendingIntent, caller proof), `aurelian.reply` (one-shot reply PendingIntent) |
| Arguments | `aurelian.arg.<name>`; only the names and types each command allows (below). Names ≤ 80 chars, the one spoken-list `phrase` ≤ 200, `choices` a string list of ≤ 8 × ≤ 80, doubles finite |
| Reply extras | `aurelian.requestId`, `aurelian.status`, `aurelian.message` (≤ 200), optional `aurelian.candidates` (≤ 8 × ≤ 80), `aurelian.context` (≤ 80) |
| Statuses | `ok`, `ambiguous`, `not_found`, `not_handled` (no GoodLift screen can do it; Aurelian then taps instead, used by "select"), `unavailable`, `unsupported`, `invalid`, `failed` |

| Command | Arguments | What runs |
|---|---|---|
| `open_workout` | — | Home's own Enter Workout path (block-readiness check, gated WES2 for the selected athlete); on WES2 already: brings it forward |
| `open_analytics` | — | Home's Analytics card path: `ExerciseDetailsScreen` for the selected athlete (`pushExerciseAnalytics`) |
| `add_exercise` | — | WES2 `_onAddExercise` → the existing `Wes2ExercisePicker` (not the custom-exercise dialog) |
| `select_exercise` | `name`, optional `choice` | picker open: picks from its real list (everything not already in the day) and closes it like a tap; Analytics in front: the dropdown's own pick path; WES2: sets the voice target |
| `next_exercise`, `previous_exercise` | — | moves the WES2 voice target in the workout's order and scrolls its card into view |
| `set_fields` | `setNumber` (1-based), any of `weight` (+ optional `weightUnit` `kg`/`lb`), `reps`, `rir`, `velocity` | the typed-entry path for each value on the voice target (see WES2 parity) |
| `open_set_note` | `setNumber` | the existing set-note dialog (`_onOpenSetNoteDialog(row, setNumber - 1)`), note field focused |
| `open_exercise_note` | — | the existing exercise execution-note dialog |
| `add_set` | — | `_onAddSet` |
| `mark_exercise_done` | optional `exercise`, `choices` | the Done coordinator (`_onToggleMarkedDone`), only when the card itself offers "Completed?" |
| `analytics_metric` | `metric` (`e1rm` / `velocity`) | Analytics `_setMetric` |

Added in the voice UX expansion (still protocol v1: new commands and new optional arguments only; an
older GoodLift answers `unsupported` for a command it does not know):

| Command | Arguments | What runs |
|---|---|---|
| `set_fields` (extended) | optional `exercise`, `choices` | as above, on the named exercise, which becomes the voice target |
| `navigate` | `destination`: `body_weight_tracker`, `workout_planner`, `profile`, `block_planner_2`, `week_planner`, `settings`, `coach_dashboard`, `coaching`, `feed`, `leaderboard`, `buddy_hub`, `messages`, `menu` | Home's own card / top-bar handlers (`_openWorkoutPlanner`, `_openWeekPlanner`, … `BuddyHubButton.open`, `DmBadgeButton.open`, `openDrawer`), with the cards' readiness checks; Coach Dashboard only for coach accounts and Coaching only for athlete accounts, as on the Home screen; Feed/Leaderboard through the section's own switch (`HomeCommunityController`) and Menu only while Home is the screen in front |
| `workout_action` | `action`: `load_template`, `select_date`, `previous_day`, `next_day`, `add_circuit`, `exercise_settings`, `exercise_details`, `top_sets`, `current_exercise` | the WES2 buttons' own handlers (`_showTemplatePicker`, `_onSelectDate`, `_onPrevDay`, `_onNextDay`, `_onAddCircuit`, `_showExerciseSettingsDialog`, `_navigateToExerciseDetails`, `_navigateToTopSets`); `current_exercise` names the voice target |
| `add_exercises` | `phrase`, optional `choices` | splits the spoken list against the Add Exercise picker's catalogue (`ExerciseCatalog.loadCombinedExercisesForUser`, minus the day's exercises), resolves EVERY name first (≤ 10), then adds each through `_addExerciseFromPicker`; with the picker open, a single name is picked there |
| `clear_set` | `setNumber`, optional `exercise`, `choices` | for each logged field of that set, the typed-entry path with empty text (`updateSetField` + `_onFieldUnfocused`: an explicit null reaches the outbox). The set, its note and its video stay |
| `remove_set` | `setNumber`, optional `exercise`, `choices` | `_removeSetConfirmed` (the Remove Set core). Refused for the only set (name the exercise to delete it) and for BB3-planned rows, as the button refuses them |
| `delete_exercise` | optional `exercise`, `choices` | `_deleteExerciseConfirmed` (the Delete Exercise core) |
| `replace_exercise` | `replacement`, optional `exercise`, `choices` | resolves `replacement` in the Replace picker's list, then `_applyReplacement` (the Replace core) |
| `add_exercise_to_circuit` | `circuit` (1-based, existing) | the circuit header's `_onAddExerciseToCircuit` picker |
| `move_to_circuit` | `circuit` (1-based, existing), optional `exercise`, `choices` | `_moveExerciseToCircuitConfirmed` (the Move core) |

**Exercise names** are resolved by GoodLift, never by Aurelian, against what the screen really offers:
the workout's rows, or the picker's catalogue when adding or replacing
(`lib/aurelian/aurelian_exercise_match.dart`). Tiers: exact words → same letters without spaces → same
words in any order (plurals ignored) → every spoken word is one of the exercise's words → a close
spelling (≤ 2 edits, ≤ a fifth of the length, never within 1 edit of another exercise). Several matches
are answered `ambiguous` ("Which bench press?", ≤ 8 labels); Aurelian's follow-up ("the second one") is
sent back as `choices`, the labels picked so far, and GoodLift accepts one only if it is among the
candidates it finds again now. Clearing, removing, deleting, replacing and moving never accept the
close-spelling tier. A command naming several exercises asks about one at a time.

**Destructive voice commands** run the same cores as the buttons, after the explicit spoken command in
place of the confirmation dialog, and offer Undo exactly when the buttons do (logged values). WES2's
undo restores rows in memory without re-queuing the restored structure to the durable outbox for
ordinary rows, so voice never offers an Undo the button would not.

## Authentication

A request is accepted only if its `aurelian.caller` PendingIntent

1. was created by package `com.razorsedgesystems.aurelian`,
2. whose creator UID really owns that package (`getPackagesForUid`), and
3. which is signed with an allowed certificate (`PackageManager.hasSigningCertificate(…, CERT_INPUT_SHA256)`, Android 9+).

Anything else is dropped without a reply. A PendingIntent's creator cannot be forged, and neither can
a signing certificate; the package name alone could be claimed by another app. The allowed
certificate is `AurelianCallerPolicy.ALLOWED_AURELIAN_CERT_SHA256`: the SHA-256 of the Android debug
certificate on Richard's build machine, which is the only key Aurelian (a personal, sideloaded app)
is signed with. The same allowance applies to GoodLift debug and release builds. Certificate hashes
are public identifiers, not secrets. If Aurelian ever gets its own release key, add that
certificate's SHA-256 there. `<queries><package android:name="com.razorsedgesystems.aurelian"/>`
makes the check possible under package visibility.

The reply PendingIntent must also have Aurelian as its creator. Request ids, command names and
argument names/types are validated natively (`AurelianRequestParser`) and again in Dart
(`AurelianCommand.fromBridge`). Unknown protocol versions and commands are refused; there is no
free-form payload, method name, file path or code of any kind. Requests older than 15 s are refused
(no stale replay), and the Intent's action and extras are cleared once read, so an activity
recreation never re-runs a command. Logs name commands and statuses only: no workout data, no tokens.

## Lifecycle

- **Warm** (GoodLift running): `onNewIntent` hands the Intent to the bridge, which delivers it at
  once. It is never treated as a notification tap.
- **Cold** (Aurelian starts GoodLift): `onCreate` hands the launch Intent to the bridge (not on a
  recreation). The request waits in a bounded native queue (4) until Dart says it is ready.
- **Ready** means an `AurelianBridgeScope` is mounted. Like `PushReadyScope`, it sits inside the
  membership gate of the gated Home route and of the restored WES2 route (main.dart). Only then is
  a user signed in, membership confirmed and a navigator present. Signed out or on the paywall, requests
  are refused after 12 s ("GoodLift isn't ready — open it and sign in"), never silently dropped, and
  voice can never step around sign-in, membership or the selected athlete.
- **Routing** (`AurelianCommandBus`): screens register handlers while mounted and unregister on
  dispose. The more specific scope wins (picker › Home/WES2/Analytics › root), and among equals the most
  recently mounted. A handler returns null to pass a command on.
- **Workout commands without a workout**: the bus first runs `open_workout` (Home's path), then waits
  for WES2 to register (lifecycle acknowledgement, max 10 s), then delivers the command. WES2 itself
  waits for its day to finish loading by listening to its controller. There are no fixed sleeps.
- **WES2 behind another page** (Analytics): WES2 pops the pages above it. It never dismisses a dialog
  or bottom sheet (it may hold unsaved text) and answers "Close the open dialog first" instead.
- Every request is answered exactly once: Dart's result, a validation refusal, "busy" when the queue is
  full, or the timeout refusal.

## Why WES2 edits reuse the canonical paths

A voice value must behave exactly like the athlete typing it and leaving the field. So `set_fields`
calls, for each value, the same two things the set row does:

1. `Wes2SessionController.updateSetField` with the canonical kilogram text (the row's `onFieldChanged`):
   the same actual value and the same cascade/hint recomputation;
2. `_onFieldUnfocused` (the row's focus-loss save): parsing through `Wes2FieldParser`, the
   workout-duration segment, the tutorial side effects, and `_saveFieldSilently` →
   `Wes2Mutation.fieldPatch` → durable outbox → sync engine (retryable, offline-safe; the local draft
   is saved on leaving the screen as usual).

Weight in pounds, or with no unit on an exercise shown in pounds, is converted once with
`parseDisplayToKg`, exactly as the lb weight field converts typed text. Every value is validated
before any is applied (`planSetEntry`), so a combined "50 kilos 5 reps 2 RIR" never half-applies; a set
the exercise does not have, a timed exercise, or velocity on an exercise without the field is refused
with a message. Before applying, the focused field (if any) is left and its durable write awaited, so
the athlete's own typing is saved first and cannot overwrite the voice value afterwards.

The voice target (which exercise "set one" means) is session-local and never saved. It starts on the
first exercise, and an exercise added by voice becomes it. Its card gets a thin outline once voice is
used; the outline is always in the tree (transparent when not targeted), so toggling it never rebuilds
a card's own fields. Scrolling uses the existing `_exerciseCardKeys` and `Scrollable.ensureVisible`
(paging the list's own scroll position until a lazily built card exists), never screen coordinates.

`test/wes2_voice_bridge_e2e_test.dart` drives the real `Wes2Screen` both ways and requires the same
model state (actuals and recomputed hints of every set), the same document on the server, and the same
queued outbox mutations offline.

## Tests

- `android/app/src/test/.../AurelianBridgeCoreTest.kt` (JVM): parsing and bounds, protocol version,
  caller policy, cold-start queue, warm delivery, reply exactly once, timeout, bounded queue.
  Run with `android\gradlew.bat :app:testDebugUnitTest -Dorg.gradle.java.home=<JDK 17+>` after one
  `flutter build apk --debug` has generated the wrapper.
- `test/aurelian_bridge_logic_test.dart`: command model, bus routing/readiness/workout bring-up, channel
  binding, exercise matching, set-entry planning and units, voice target.
- `test/wes2_voice_bridge_e2e_test.dart`: WES2 parity, offline outbox, lb conversion, invalid input,
  the real picker (ambiguity, already-added exercises), next/previous/select with scrolling, the set-note
  dialog, add set, Done.
- `test/aurelian_analytics_voice_test.dart`: Analytics selection for the selected athlete, ambiguity,
  metrics, and that a screen alone never makes the bridge ready.
- `test/aurelian_voice_ux_logic_test.dart`: the new commands' model and per-command arguments, matcher
  tiers (plurals, subsets, fuzzy margins, destructive refusal), "which one?" answers, spoken-list
  splitting ("clean and jerk and back squat"), and that Home cards/voice and WES2 dialogs/voice share
  one method each.
- `test/wes2_voice_bridge_e2e_test.dart` (voice UX group): named set entry and target, clear set
  (explicit nulls queued), remove set / delete via the cores, replace with a "which one?", multi-add
  resolving everything first, named Done, circuits, the picker taking "add X".
- `test/home_community_section_test.dart`: voice selects Feed/Leaderboard through the tap's own switch.

## Physical testing

Install this GoodLift build and Aurelian Milestone 2 on the same phone (Aurelian signed with the allowed
debug key). In Aurelian's Engineering panel, "goodlift" should read "bridge available"; an older
GoodLift reads "installed GoodLift has no Aurelian bridge (older build)". "gl last" and "gl screen" show
each command's result and the GoodLift screen that handled it.
