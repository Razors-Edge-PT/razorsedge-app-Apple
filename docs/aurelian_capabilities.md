# Aurelian ↔ GoodLift capability contract

Version: **aurelian.tools.v1** (planner tools) / **action envelope schema 1** (bridge). Status: phase one
implemented; later groups specified below and not yet implemented.

Aurelian (Richard's personal Android voice assistant) plans natural speech into a short list of actions
from a closed catalogue. Each GoodLift action reaches GoodLift as one versioned envelope over the
authenticated bridge (`execute_action`, docs/aurelian_bridge.md) and is run by GoodLift's own
**action service** (`lib/aurelian/actions/`). The planner never gets unrestricted control: it can only
name actions from this contract, with typed bounded arguments, and GoodLift validates, authorises,
confirms, executes, verifies and journals every one itself.

The same catalogue is mirrored in Aurelian (`app/.../orchestration/ToolCatalog.kt`) and in Aurelian's
Worker (`orchestrator-worker/schema/aurelian-tools.v1.json`). The shapes are plain (name + typed
arguments + structured result) so they map one-to-one onto Android AppFunctions later, without depending
on the experimental API now.

## Risk classes and confirmation rules

| Class | Examples | Rule |
|---|---|---|
| **Read-only** | `athlete.current`, `workout.read`, analytics reads | No confirmation. |
| **Navigation** | `workout.open`, general timer, open screens | No confirmation. |
| **Low-risk personal mutation** | set values, notes, add exercise/set, move, explicit completion | No confirmation; undoable. Entering values never marks an exercise completed; completion only on an explicit instruction. |
| **Destructive / overwrite** | delete a populated exercise or set, replace a populated exercise, load a template over logged data, delete a populated circuit, copy over a populated set | `requires_confirmation` with a single-use token bound to the exact request (60 s); Aurelian asks "say yes"; nothing runs before the token comes back. Empty targets run directly (as GoodLift's own buttons do). |
| **Outgoing / person-directed** | DMs (later) | Recipient must resolve unambiguously; "write/type" only drafts; only an explicit "send" sends. |
| **Coach / admin mutation** | `athlete.switch`, service-category changes (later) | Coach authorisation re-checked by GoodLift (roster rules = firestore.rules `isCoachFor`) on every call; admin changes read the current value, confirm, save and read back. |

The personalised "Aurelian" wake word is a convenience gate, **not** security authentication for
high-risk actions: GoodLift's own account, coach authorisation and confirmations apply regardless.

## Envelope (schema 1)

```json
{ "schemaVersion": 1, "requestId": "<[A-Za-z0-9-]{1,64}>", "idempotencyKey": "<[A-Za-z0-9-]{8,64}>",
  "action": "set.update", "payload": { "exercise": "bench press", "set": 1, "weight": 150, "reps": 5, "rir": 1 },
  "confirmationToken": "<optional>" }
```

- ≤ 4096 characters; unknown fields, actions or arguments, wrong types and out-of-range values are
  refused (`invalid`). There is **no user id** anywhere: GoodLift always acts for its signed-in account
  and the athlete it currently acts on, re-checked against the coach roster.
- `choices`: labels picked in answer to earlier `ambiguous` candidates; accepted only if among the
  candidates GoodLift finds again now.
- Idempotency: the same key with the same request returns the first result (10 min, 64 entries); the
  same key with a different request is a `conflict`.

Result: `{ schemaVersion, requestId, status, summary, verified, data?, candidates?, undoToken?,
confirmationToken? }`, ≤ 4096 characters. Statuses: `success`, `requires_confirmation`, `ambiguous`,
`not_found`, `invalid`, `unauthorized`, `conflict`, `unsupported`, `failure`. `verified` is true only when
GoodLift read the state back after the change and it matched; Aurelian reports success only then.

## Phase one (implemented)

| Action | Arguments | Notes |
|---|---|---|
| `athlete.current` | — | Label only, never ids. |
| `athlete.switch` | `query` | Coach accounts only. Matches only the coach's roster (+ self): exact/partial username, full name, email, spelled letters, profile/business name, username without trailing digits, honorific + surname. One clear match switches through `UserContext.switchAthlete` (Coach Dashboard's state); several close ones → `ambiguous`; nothing confident → `not_found`. The current screen stays; an open workout reopens for the same day for the new athlete. Undo switches back if still current. |
| `workout.open` | `date?` (YYYY-MM-DD) | Home's Enter Workout path (membership/readiness checks), then the date. |
| `workout.read` | — | Day, exercises (name, circuit, sets, logged, done, timed), workout timer. |
| `template.load` | `template?` | Named, or today's (active block, block day number or weekday). Several → `ambiguous`. Over logged data → confirmation. Undo only when the day had no logged data (removes the template's exercises, restores the previous ones) — never a snapshot rewrite. |
| `exercise.add` | `exercise`, `circuit?` | Into an existing circuit or the next new one. |
| `exercise.delete` | `exercise` | Populated → confirmation (mirrors the Delete dialog). Undo re-adds it and replays its sets, notes and completion through the ordinary paths. |
| `exercise.replace` | `exercise`, `replacement` | Populated → confirmation. Undo replaces back and replays. |
| `exercise.move` | `exercise`, `circuit` | Existing circuit or the next new one. Undo moves back if it was not moved again. |
| `exercise.note` | `exercise?`, `text` | The note dialog's save path. |
| `exercise.complete` | `exercise?`, `completed` | Explicit only; the Done coordinator; needs a logged set to mark completed. |
| `circuit.add` | `exercise` | A new circuit starting with that exercise. |
| `circuit.rename` | `circuit`, `name` | `unsupported`: GoodLift circuits are numbered, not named. |
| `circuit.delete` | `circuit` | Deletes its exercises; populated → confirmation; undo restores them. |
| `set.update` | `exercise?`, `set`, any of `weight`, `unit?`, `reps`, `rir`, `velocity` | `planSetEntry` validation and units (the exercise's unit unless said); the typed-entry save path for each value. Undo restores only the fields it wrote, only while they still hold what it wrote. |
| `set.note` | `exercise?`, `set`, `text` | The set-note dialog's save path. |
| `set.add` | `exercise?` | Undo removes the set while it is still empty. |
| `set.delete` | `exercise?`, `set` | Logged values → confirmation (as the Remove Set button). BB3-planned rows refused (as the button). Undo only for the last set (a middle set's successors were renumbered; GoodLift's own Undo covers that). |
| `set.clear` | `exercise?`, `set` | Clears logged values (set, note and video stay). |
| `set.copy` | `exercise?`, `set`, `toSet?` | Into a new set, or over another (populated → confirmation). |
| `timer.exercise.start` | `exercise?`, `set` | Timed exercises only (plank): starts that set's own stopwatch (`Wes2SetTimerHub`), exactly as tapping it. Undo cancels without saving. |
| `timer.exercise.stop` | `exercise?` | Stops the running set stopwatch and saves the seconds through the cell's own stop path. |
| `timer.general.start` / `.stop` | — | The general Enter Workout timer (three-dot menu), not a set stopwatch. |
| `undo` | `undoToken` | Only the latest journaled change; refused (`conflict`) when the state moved on since. |

Exercise names resolve in order: exact canonical name → normalised name → explicit alias map
(`exercise_resolution.dart`: "bench press" → Bench Press, Barbell; "dumbbell bench" → Flat Bench Dumbbell
Press; "Larson/Larsen press" → both Larsen entries, so it asks) → the athlete's history (a clear
favourite only) → the current workout → `ambiguous`. Destructive actions never use spelling guesses or
history.

## Later command groups (specified, not implemented)

| Group | Action (proposed name) | Class | Notes |
|---|---|---|---|
| Home & navigation | `nav.open` {destination: enter_workout, week_planner (screen label "Week Planner"; BB3 in code), block_planner, dms, settings, analytics, coach_dashboard} | Navigation | Reuse Home's card handlers (already used by v1 `navigate`). |
| | `blocks.list`, `blocks.select` {block}, `blocks.select_current` | Read-only / navigation | Block Planner's own selection. |
| | `home.select_date` {date} | Navigation | Home calendar. |
| | `leaderboard.show` {range: monthly / all_time} | Navigation | Through `HomeCommunityController`. |
| | `screen.scroll` {direction: up/down/left/right} | Navigation | On compatible scrollables only. |
| Direct messages | `dm.open` {recipient} | Navigation | Recipient resolved among existing conversations; ambiguity → ask. |
| | `dm.draft` {recipient, text} | Personal | "write"/"type" = draft only. |
| | `dm.send` {recipient, text?} | Outgoing | Only on an explicit "send", after unambiguous recipient resolution. |
| | `dm.attach` {kind: photo/document} | Outgoing | Opens the picker; never sends on its own. |
| | `dm.react` {message ref, reaction} | Outgoing | Message must be identified unambiguously. |
| Settings | `settings.theme` {theme} | Personal | |
| | `profile.set` {field: username, full_name, date_of_birth, sex; value} | Personal (identity) | Read back, confirm before saving; usernames checked for collisions with the existing validation. |
| Analytics | `analytics.exercise` {exercise} | Read-only | |
| | `analytics.metric` {e1rm / velocity}, `analytics.velocity_reps` {reps}, `analytics.velocity_weight` {weight} | Read-only | |
| | `analytics.range` {two_weeks, one_month, six_months, one_year, two_years} or {start, end} | Read-only | Read back the selected dates. |
| | `analytics.include_rir` {chart: main / rep_specific, include} | Read-only | Each chart independently. |
| Coach Dashboard | `coach.search` {query}, `coach.select` {athlete} | Read-only / coach | Same matcher as `athlete.switch`. |
| | `coach.weekly_review.open` {athlete}, `coach.review_message.copy` {athlete} | Read-only | Clipboard copy is local. |
| | `coach.service_category.read` / `.set` {full_online, in_person, prospective, eight_week_programme} | Coach/admin | Read current first, confirm, save, read back. |

Each later action will get its own entry in the three catalogue files and tests before it is enabled.
