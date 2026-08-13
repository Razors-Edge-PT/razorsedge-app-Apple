# Coach Bi-Weekly Check-ins (Monday / Thursday)

Branch: `feature/coach-biweekly-checkins`

A coach-only athlete review + draft check-in system. Reports are prepared for
every enabled athlete **both** Monday and Thursday (coach timezone); the
client-facing message coverage window adapts dynamically to which previous
message was actually copied. Copy/paste only — no outbound messaging, no
runtime LLM. Message text is produced from deterministic templates.

## Architecture

```
workout write ──▶ coachAnalyticsOnWorkoutWrite ──▶ per-exercise history +
                                                   deterministic PB events
enable athlete ─▶ coachOnAthleteSettingsWritten ─▶ one-time bounded bootstrap
hourly ─────────▶ coachCheckpointScheduler ──────▶ Mon/Thu report docs
Copy button ────▶ coachPrepareCheckInCopy ───────▶ freeze coverage + live BW
                                                   recheck + final text
Undo ───────────▶ coachUndoCheckIn               Skip ─▶ coachSkipCheckIn
```

Pure business logic lives in `functions/coach/{e1rm,pb_engine,coverage,
bodyweight,praise,message}.js` (no Firebase imports, covered by
`functions/test/*.test.js` via `npm test` → `node --test`). The Flutter
mirror of the coverage/staleness rules is `lib/coach_checkins_logic.dart`
(covered by `test/coach_checkins_logic_test.dart`).

## Firestore schema (new collections)

### `coachAnalytics/{athleteUid}` — server-written only
| field | meaning |
|---|---|
| `enabledBy.{coachUid}: true` | which coaches have reporting enabled |
| `analyticsVersion`, `e1rmFormulaVersion` | engine/formula versioning |
| `bootstrapStatus` | `running` / `complete` / `error` (+ `bootstrapAt`, `bootstrapError`) |
| `milestones.{id}: dateKey` | awarded 10 kg milestones (`cut_110`, `bulk_90`, …) |

- `…/exercises/{exerciseId}`: `name`, `formulaVersion`, `updatedAt`,
  `history: {dateKey: {bestByReps, bestE1rm, bestE1rmSet}}` (compact per-day
  summary), `repBest: {reps: {weightKg, dateKey}}`, `e1rmBest`.
- `…/events/{eventId}`: deterministic ids `YYYY-MM-DD_exerciseId_repN` /
  `YYYY-MM-DD_exerciseId_e1rm`, fields `type`, `dateKey`, `exerciseId`,
  `exerciseName`, `reps`, `weightKg`, `prevWeightKg`, `e1rmKg`, `prevE1rmKg`,
  `pctImprovement`, `formulaVersion`.

### `coachCheckIns/{coachUid}`
- Root doc: `timezone` (IANA, coach-editable, default `Pacific/Auckland`),
  `lastCheckpointKey` (scheduler watermark, server-written).
- `…/athletes/{athleteUid}`: coach-editable `reportingEnabled`, `goal`
  (`cut|bulk|maintain`), `messageExerciseMode` (`automatic|custom`),
  `customExerciseIds[]`, `displayName`, `enabledAt`, `updatedAt`;
  server-written `praisedWeeks: {weekStartKey: reportId}` and
  `lastFinalizedCoverageEnd`.
- `…/reports/{athleteUid}_{checkpointKey}`: server-generated; `status`
  (`draft|copied|skipped|expired`), `checkpointKey`, `weekday`,
  `prevCheckpointKey`, `maxStartKey`, embedded `events[]` (max window),
  `workoutDates[]`, `completion`, `fallbackWeek`, `bodyweight`,
  `variantSeed`, `gender`, `firstName`, `draftIfPrevCopied`,
  `draftIfPrevNotCopied`; after copy also `copiedAt`, `coverageStart/End`,
  `finalText`, `liveBodyweight`, `praisedWeekKey`, `milestoneAwarded`,
  `prevLastFinalizedCoverageEnd` (for undo).

## Key rules of the system

- **E1RM (coach analytics)**: `weight + reps` only, RIR always ignored.
  Matches `PeriodizationModelUtils.calculateE1RM(w, r, 0)`: Brzycki
  `w*36/(37-r)` for ≤25 reps, Epley `w*(1+0.0333r)` above. Versioned via
  `E1RM_FORMULA_VERSION`; bumping the version and re-running the bootstrap
  re-baselines history without creating "new PB today" events (events only
  exist on historical days that strictly improved on prior history).
- **Rep-target PB**: same athlete + exerciseId + exact rep count, strictly
  more weight. First-ever result is a baseline, not a PB. Day-best collapse
  prevents multi-set spam. Sets need weight>0 and reps>0.
- **Edits/deletes**: the workout trigger recomputes each touched exercise's
  full event stream from its compact per-day history (deterministic ids), so
  PB state self-heals rather than staying stale.
- **Coverage state machine**: reports always run Mon+Thu; the draft's window
  start is the previous checkpoint if that message was *copied*, else the
  same weekday 7 days back, clamped to the last finalised-copied coverage
  end (no overlap/double praise). Drafts stay dynamic until copied; copy
  freezes coverage; undo is allowed while no newer checkpoint is finalised;
  drafts older than the previous checkpoint auto-expire.
- **Weekly completion** is judged per block-anchored training week
  (`weekIndex = daysSinceBlockStart ~/ 7`, planned = day docs with non-empty
  `exercises`, completed = workout day docs with any weight>0 & reps>0 set —
  identical to `HomeV2CalendarService`), independent of Mon/Thu windows, and
  praised at most once per week (`praisedWeeks`).
- **Bodyweight**: `users/{uid}/weights` docs collapsed to one value per day
  (AM preferred, PM fallback; missing `tod` = AM per app back-compat).
  Rolling 7-day average vs the preceding 7 days; a single weigh-in in a
  window is enough. Maintain band = ±1 % of the previous average. Weigh-in
  staleness: 3 days = due, 4+ = overdue, computed from the latest weigh-in at
  read time. Bodyweight is re-checked **live** inside the copy callable;
  training achievements stay frozen to the checkpoint.
- **10 kg milestones** use the rolling averages, are persisted per athlete in
  `coachAnalytics.milestones`, and are only recorded when a copy actually
  goes out (undo un-awards).

## Security

- `coachAnalytics/**`: read via existing `canAccessTraining()` (self,
  assigned coach, super admin); client writes always denied — only Cloud
  Functions (Admin SDK) write, so PB/report integrity can't be forged.
- `coachCheckIns/{coachUid}/**`: readable only by that coach (+ super
  admin). Settings writes are key-restricted; per-athlete settings can only
  be created for athletes passing the existing `isCoachFor()` assignment
  check. Reports are client-read-only; copy/undo/skip go through callables
  which re-verify `coachAssignments` / `athleteAssignments` server-side.
- Existing coach approval model (`athleteAssignments` / `coachAssignments` /
  `accessRequests`) is reused untouched.

## Cost profile

- Dashboard open: per enabled athlete = 2 report direct-gets + 1 latest
  weigh-in read (+ settings listing). No workout scans.
- Workout write: 1 state read; if not enrolled, that's all. If enrolled,
  reads/writes only the touched exercises' docs + their event diffs.
- Scheduler: 1 coach-doc read per coach per hour; full generation only twice
  a week per coach (watermarked), with bounded per-athlete reads
  (~30 docs/athlete/checkpoint).
- Bootstrap: one paged scan of the athlete's workouts, only when a coach
  enables reporting (or after a formula-version bump).

## Indexes

No composite indexes are required. All queries are single-field
(`isActive`, `timestamp`, `reportingEnabled`, `dateKey` range,
`exerciseId` equality, documentId ordering), which Firestore auto-indexes.

## Deployment checklist (manual — nothing is deployed by this branch)

1. **Rules**: apply the updated `firestore_rules/Database_rules_version =
   '2';.txt` in the Firebase console (rules are console-managed in this
   project; the file is the source of truth copy).
2. **Functions**: `cd functions && npm install && npm test && npm run deploy`
   (deploys the six new functions alongside the untouched existing ones).
   The scheduler needs Cloud Scheduler enabled (v2 `onSchedule` provisions
   the job automatically on deploy).
3. **No data migration**: nothing runs until a coach enables an athlete;
   enabling triggers that athlete's bounded bootstrap automatically.
   Re-running a bootstrap is safe (idempotent rebuild).
4. **Timezone**: defaults to `Pacific/Auckland`; coaches can change it from
   the Weekly Review screen (clock icon).

## Known limitations

- Draft previews on the dashboard are the generation-time variants; the
  authoritative text (live bodyweight, praise dedup) is produced at copy
  time and may differ slightly.
- A workout written while a bootstrap is mid-rebuild can interleave; the
  next write or a re-bootstrap converges the state.
- Client-side checkpoint keys use the device timezone; they match the
  server's keys whenever the coach's device timezone equals the configured
  coach timezone (the normal case).
- `copiedAt` is the stand-in for a future `sentAt`; an automated-send system
  can replace the copy callable while keeping the same frozen-coverage state
  machine.
