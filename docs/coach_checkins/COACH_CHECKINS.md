# Coach Bi-Weekly Check-ins (Monday / Thursday)

Branch: `feature/coach-biweekly-checkins`

A coach-only athlete review + draft check-in system. Reports are prepared for
every enabled athlete **both** Monday and Thursday (coach timezone); the
client-facing message coverage window adapts dynamically to which previous
message was actually copied. Copy/paste only — no outbound messaging, no
runtime LLM. Message text is produced from deterministic templates.

## Architecture

```
workout write ──▶ coachAnalyticsOnWorkoutWrite ──▶ bounded fast-path append
                                                   or per-exercise rebuild
enable athlete ─▶ coachOnAthleteSettingsWritten ─▶ atomic bootstrap claim
assignment edit ▶ coachOnAthleteAssignmentsWritten / coachOnCoachAssignments-
                  Written ─▶ immediate revocation cleanup
hourly ─────────▶ coachCheckpointScheduler ──────▶ Mon/Thu reports + catch-up
dashboard open ─▶ coachReviewContext (callable) ─▶ coach-local today/checkpoint
                                                   + live weigh-in staleness
Copy ───────────▶ coachPrepareCheckInCopy ───────▶ atomic freeze + finalText
Undo ───────────▶ coachUndoCheckIn               Skip ─▶ coachSkipCheckIn
```

Pure business logic lives in `functions/coach/{e1rm,pb_engine,coverage,
bodyweight,praise,message,draft,enrollment,authz,analytics_store,
checkin_txns}.js` (unit-tested with `npm test` → `node --test`). The
Firestore-bound layer is `functions/coach/index.js`. The Flutter mirror of
display-only helpers is `lib/coach_checkins_logic.dart`.

## Assignment / approval model (authoritative)

A coach is authorised for an athlete when EITHER:

1. **Admin-seeded**: `coachAssignments/{coachUid}.athletes[athleteUid]` is any
   non-null entry (the app seeds `{email}` objects), OR
2. **Athlete-approved**: `athleteAssignments/{athleteUid}
   .coaches[coachUid].approved === true` — strictly boolean `true` on an
   object entry. Pending requests, `approved: false`, malformed entries or
   mere key presence grant **nothing**.

Backend (`functions/coach/authz.js`) and rules (`firestore.rules
isCoachFor()`) implement identical checks. Every athlete-specific callable
revalidates the relationship at invocation time. There is exactly one
hardcoded superadmin UID (unchanged from the existing app).

**Immediate revocation**: triggers on both assignment collections re-evaluate
every affected coach⇄athlete pair on write. When no valid source remains the
server disables reporting (`disabledReason: 'assignment-revoked'`) and
removes the coach from `coachAnalytics.enabledBy` immediately; if another
valid source (or another enabled coach) remains, access/analytics are
preserved. The scheduler repeats the check as defence in depth. Rules deny a
revoked coach all reads instantly (settings via `isCoachFor(athleteUid)`,
reports via `isCoachFor(resource.data.athleteUid)` — the report's embedded
athlete identity, not the caller-supplied path).

## Firestore schema (final)

### `coachAnalytics/{athleteUid}` — server-written only
| field | meaning |
|---|---|
| `enabledBy.{coachUid}: true` | which coaches have reporting enabled |
| `analyticsVersion` (2), `e1rmFormulaVersion` (1) | storage/formula generations |
| `bootstrapStatus` | `running` / `complete` / `error` |
| `bootstrapRunId`, `bootstrapAt`, `bootstrapAtMs`, `bootstrapError` | run ownership + freshness |
| `dirtyDates: [dateKey]` | workout days written while a bootstrap runs |
| `e1rmRebaselinedAtKey` | E1RM praise floor set by a formula-change rebaseline |

- `…/exerciseDays/{exerciseId}_{dateKey}`: `{exerciseId, dateKey, day:
  {name, bestByReps, bestE1rm, bestE1rmSet}}` — one small bounded doc per
  exercise per trained day; **no document grows with history**. Lookups are
  single-field queries: `exerciseId ==` (rebuild), `dateKey ==` (touched
  detection), `dateKey <` + orderBy desc limit 1 (last-trained fallback).
- `…/exercises/{exerciseId}`: bounded summary + provenance — `name`,
  `repBest{reps→{weightKg,dateKey}}` (≤ one entry per distinct rep count),
  `e1rmBest`, `latestDateKey` (fast-path watermark), `formulaVersion`,
  `dayCount`, `updatedAt`.
- `…/events/{YYYY-MM-DD_exerciseId_repN | _e1rm}`: deterministic ids;
  `type`, `dateKey`, `exerciseId`, `exerciseName`, `reps`, `weightKg`,
  `prevWeightKg`, `e1rmKg`, `prevE1rmKg`, `pctImprovement`, `formulaVersion`.

### `coachCheckIns/{coachUid}`
- Root doc: `timezone` (IANA, coach-editable, validated in rules AND
  re-validated server-side with a `Pacific/Auckland` fallback so a malformed
  value can never break the scheduler), `lastCheckpointKey` (server-only
  scheduler watermark — bounds catch-up scanning; NOT the dashboard's
  checkpoint identity).
- `…/athletes/{athleteUid}` — coach-editable (whitelisted + value-validated
  in rules, live assignment required): `reportingEnabled` (bool), `goal`
  (`cut|bulk|maintain`), `messageExerciseMode` (`automatic|custom`),
  `customExerciseIds[]` (≤100), `displayName`, `enabledAt`, `updatedAt`.
  Server-only (unreachable from clients, doc undeletable by coaches):
  `goalSetAt` (epoch ms — stamped by the settings trigger ONLY when the goal
  value genuinely changes), `praisedWeeks{weekStartKey→reportId}` (pruned to
  26 weeks at copy), `praisedMilestones{"cut_110@<goalSetAt>"→{reportId,
  dateKey}}` (pruned to the current phase at copy), `lastFinalizedCoverageEnd`,
  `disabledReason`, `disabledAt`.
- `…/reports/{athleteUid_checkpointKey}` — server-generated, client
  read-only: `athleteUid`, `checkpointKey`, `weekday`, `status`
  (`draft|copied|skipped|expired`), `variantSeed`, `gender`, `firstName`,
  `displayName`, `prevCheckpointKey`, `maxStartKey`, embedded `events[]`
  (max window), `workoutDates[]`, `completion`, `fallbackWeek`,
  `blockStartKey`, `bodyweight`, `e1rmPraiseFloorKey`, `draftIfPrevCopied`,
  `draftIfPrevNotCopied`, versions; after copy: `copiedAtMs`,
  `coverageStart/End`, `finalText`, `liveBodyweight`, `praisedWeekKey`,
  `milestoneAwarded`, `prevLastFinalizedCoverageEnd` (undo support).
  `copiedAtMs` is the stand-in for a future `sentAt`.

## Analytics engine

- **Fast path (normal chronological append)** — bounded regardless of
  history size: 1 summary read + 1 day-doc read + 1 day write + ≤(distinct
  reps + 1) event writes + 1 summary write. Applies when the written day is
  strictly later than `latestDateKey` and has no existing day doc. Proven
  equivalent to a full chronological rebuild (property test) and proven
  bounded by instrumented store counters.
- **Rebuild fallback** — edit, delete, out-of-order insert, exercise
  removal, retried delivery of an existing day: reads that ONE exercise's
  day docs + event ids, patches the day in memory, rewrites summary/events
  deterministically (deterministic event ids self-heal stale events).
- **Concurrency**: each exercise reconciles inside `withExerciseLock` — a
  Firestore transaction in production (reads before writes), an async mutex
  in the memory-store tests — so simultaneous triggers for any mix of dates
  and exercises serialise per exercise and converge to the clean-rebuild
  result (emulator-verified). The workout trigger is deployed with
  `retry: true`; every path is idempotent, so at-least-once delivery is safe.

## Bootstrap (atomic ownership)

1. **Claim** (transaction): decides `skip-fresh` (a live run exists) /
   `skip-ready` (analytics already complete on current versions, unless the
   registration follows a maintenance gap) / `claim` — writing
   `bootstrapRunId`, `bootstrapAtMs`, `dirtyDates: []`. A formula-version
   change also stamps `e1rmRebaselinedAtKey`.
2. **Scan + wholesale rebuild**: paged chronological workout scan; the three
   analytics collections are cleared and rebuilt (only the owning run may
   destroy — ownership re-verified before deletion).
3. **Drain**: while `running`, the workout trigger transactionally defers
   written dateKeys into `dirtyDates`; the run drains them by replaying each
   day from its CURRENT workout doc. The completion transaction flips to
   `complete` only when `dirtyDates` is empty AND the run still owns the
   state — so a mid-bootstrap create/edit/delete is reconciled before
   completion, with no later write needed.
4. **Takeover**: a `running` claim older than 15 minutes is stale; a new
   claim replaces the runId. The zombie run's drain/complete/error writes
   all verify ownership first and abort silently — it can never clear a
   newer run's dirty dates, overwrite its status or mark it complete
   (emulator-verified).

## Reports & scheduling

- **Readiness gate**: `generateReport` throws unless
  `bootstrapStatus == 'complete'` on the current `analyticsVersion` AND
  `e1rmFormulaVersion` (after one self-heal attempt). No report is ever
  fabricated from missing/failed/mid-bootstrap analytics; the slot stays
  empty and retries. Other athletes generate normally (emulator-verified).
- **Catch-up**: each hourly run computes `pendingCheckpoints(watermark,
  coach-local today)` — the ascending Mon/Thu keys still unprocessed,
  bounded to the 4 most recent. A missed Thursday is generated on Friday
  with its training window still frozen to the Thursday cutoff. A new coach
  (no watermark) gets exactly the most recent checkpoint (first-checkpoint
  policy: enabling reporting retroactively generates the latest Mon/Thu
  report, nothing older).
- **Watermark ≠ identity**: the dashboard's checkpoint identity comes from
  `coachReviewContext` (pure timezone computation), so one failing athlete
  never hides other athletes' finished reports; the watermark advances
  contiguously over fully-successful checkpoints purely to bound rescanning.
- Timezones use `Intl` with IANA ids (DST-safe); values are validated and
  fall back to `Pacific/Auckland`.

## Copy / Undo / Skip (atomic)

All decision inputs are re-read INSIDE the transaction: report status,
previous + newer checkpoint statuses, `lastFinalizedCoverageEnd`, praise and
milestone maps, goal phase. Consequences (emulator-verified):
concurrent Copy+Copy is idempotent (identical frozen text; the response IS
the committed `finalText`); Copy vs Skip — exactly one wins; an older draft
cannot finalise after a newer checkpoint (and coverage clamps to the last
finalised end, so overlap is impossible); praise is recorded once; Undo
removes only entries pointing at that report's id, restores the previous
coverage watermark only if unchanged, and is blocked once anything newer is
finalised. Live bodyweight numbers are pre-fetched (athlete data, not state);
the milestone award decision is made in-txn from transactional praise state.

The Flutter copy flow: callable returns `finalText` → the card re-renders
that exact string → the same string goes to the clipboard (failures show a
dialog with the selectable text and a retry — the UI never claims success on
a failed clipboard write; copied cards also offer "copy again").

## PB semantics (analyticsVersion 3)

All PB streams are keyed on the stable exercise id and walked in ascending
`dateKey` order. Comparisons go through `strictlyGreater` / `strictlyLess`
(relative epsilon `1e-9`): float noise is absorbed, exact equality is NEVER an
improvement.

| Achievement | Rule | Rank |
|---|---|---|
| `maxWeightPB` | weight strictly greater than every prior weight on that exercise, any reps | 1 |
| `repPB` | weight strictly greater than the heaviest prior set with **reps ≥ R** | 2 |
| `e1rmPB` | strict improvement on the complete prior lifetime E1RM max | 3 |
| `rirMatchPB` | exact match of the standing PB (same weight and reps) at a strictly lower logged RIR | 4 |

Rep targets are **dominance-aware**: a higher-rep set establishes every lower
rep target at that weight. A previous 25 kg × 15 therefore makes a later
25 kg × 14 dominated, and a previous 28 kg × 15 makes a later 27 kg × 15 not a
PB. `repBest` stores the heaviest weight per *exact* rep count, which makes
the "≥ R" query (`bestWeightAtOrAboveReps`) exact from a bounded structure —
no history scan.

**RIR is excluded from every calculation except `rirMatchPB`**, which is
framed as effort, not strength (the weight and reps did not change). Its RIR
baseline moves down with each event, so one improvement cannot be praised
twice; null, equal or higher RIR never qualifies.

A set that is both a `maxWeightPB` and a `repPB` is one achievement: praise.js
presents it once, top-ranked, and the coach dashboard suppresses the duplicate
rep-PB row.

`pb_engine.applyDayToState` is the single step function used by BOTH the bulk
bootstrap walk and the incremental fast-path append, so the two paths cannot
drift; a regression test also asserts they produce identical stores.

### Exercise identity is case-folded

The stream key is `exerciseId.trim().toLowerCase()`. Workout documents written
between **2026-03-03 and 2026-05-07** persisted lowercased copies of the
catalog id, splitting exercises into two independent lifetime streams. Folding
collapses the duplicates for every enrolled athlete: Aja 26 → 19 streams,
Ruby 46 → 26, Richard 59 → 47. A split hides the heavier half of the history
from the PB comparison, which is what published Aja's 27 kg × 15 Face Pull
(2026-08-06) as a new rep and E1RM PB when the real lifetime bests were
28 kg × 15 and E1RM 45.818 (2026-05-04) on the other stream.

Folding reunites them **without modifying any workout record**. The original
casing is kept as `catalogExerciseId` for display/reference, and `praise.js`
folds the coach's `customExerciseIds` so custom-mode selection still matches.
Two casings inside one document (production had this on 2026-04-23) merge.

> **v2 → v3 (2026-08-16).** v2 keyed rep PBs on the *exact* rep count, so each
> rep count was an isolated bucket and a dominated set could publish as a "new
> N rep target PB". Bumping `ANALYTICS_VERSION` is the re-bootstrap mechanism:
> `analyticsReady()` goes false, `generateReport()` self-heals, and
> `runBootstrap()` wholesale-rebuilds from the untouched raw workout docs —
> which *deletes* wrong events rather than merely ceasing to create them.
> Raw workout documents are never modified. Regression fixtures for the
> incident live in `functions/test/coach_pb_regression.test.js`.

## E1RM formula & rebaseline

Exact parity with `PeriodizationModelUtils.calculateE1RM(w, r, 0)`:
Brzycki `w * (36 / (37 - r))` for ≤ 25 reps, Epley `w * (1 + 0.0333 * r)`
above (the repository's exact expression; both suites pin identical
constants). `E1RM_FORMULA_VERSION` is stamped everywhere. A version bump
re-bootstraps and stamps `e1rmRebaselinedAtKey`; E1RM events dated before
that floor stay visible to the coach but are NEVER praise-eligible, so a
formula change alone cannot produce "new E1RM PB" praise; a genuine lift
after the floor praises exactly once. Rep-target history is
formula-independent and untouched.

## Bodyweight

`users/{uid}/weights/{autoId}` read-only, explicit `orderBy(timestamp)`;
per-day collapse prefers AM over PM and resolves same-day/same-TOD
duplicates to the latest timestamp (matches BodyWeightTracker). Rolling
7-day `[D-7,D)` vs preceding `[D-14,D-7)`; one weigh-in per window suffices;
maintain band ±1 %; cut/bulk directional. Staleness (3 days due, 4+ overdue)
is computed in the coach timezone — for the dashboard via
`coachReviewContext`, at copy time inside the callable. 10 kg milestones are
detected from rolling averages; praise suppression is per-coach and
per-goal-phase (`goalSetAt`, server-stamped only on genuine goal changes),
so oscillation can't repeat praise, coaches can't suppress each other, undo
un-awards, and a later legitimate phase can praise the same boundary again.

## Cost profile (bounded everywhere)

- Normal workout append: ~4 reads + ~4 writes per touched exercise,
  independent of history length.
- Edit/delete: one exercise's day docs + events (bounded by that exercise's
  training days), only for touched exercises.
- Bootstrap: one paged scan per athlete, only at enablement/formula change.
- Dashboard: assignment lookups + 1 settings get + 2 report gets per
  athlete + one context callable (1 weigh-in read per athlete). No workout
  scans, no polling.
- Scheduler: 1 coach-doc read per coach per hour when idle; bounded
  generation (≈30 reads/athlete/checkpoint) at most 4 checkpoints deep.
- Praise maps pruned at copy; `dirtyDates` drained by the owning run.

## Indexes

None required: every query is single-field (equality, or range+order on the
same field), which Firestore auto-indexes. `firestore.rules` is the
canonical rules file (the copy in `firestore_rules/` is kept in sync for the
console-managed legacy workflow).

## Testing

- `cd functions && npm test` — 127 pure unit tests (`node --test`).
- `cd functions && npm run test:rules` — 27 emulator tests: full rules
  matrix (19) + adapter/bootstrap/copy-concurrency integration (8).
  Requires **Java 21+** (firebase-tools ≥ 15); e.g. on a dev machine:
  `JAVA_HOME=<jdk21>` (Android Studio's `jbr` works).
- `flutter test` — includes `test/coach_checkins_logic_test.dart`
  (coverage mirror, checkpoint identity, copy UX, E1RM parity pins).

## ⚠️ Callable functions: required one-time Cloud Run setting

This organisation enforces **Domain Restricted Sharing**
(`constraints/iam.allowedPolicyMemberDomains`), which **rejects granting
`allUsers` the `roles/run.invoker` binding**:

```
FAILED_PRECONDITION: One or more users named in the policy do not belong to a
permitted customer, perhaps due to an organization policy.
```

Firebase callables are normally made reachable via exactly that binding, so a
newly created callable in this project is unreachable — every request is
rejected by Cloud Run with **403 before any application code runs** (observed
in production as `The request was not authorized to invoke this service`).
`firebase deploy` only attempts the binding on function *create*, so a
redeploy does **not** repair it.

The project's existing public functions (e.g. `stripeWebhook`) instead run
with the Cloud Run invoker IAM check disabled. After creating any new
callable, apply once:

```
gcloud run services update <lowercased-function-name> \
  --no-invoker-iam-check --region=us-central1 --project=goodlift-us-storage
```

Applied to: `coachreviewcontext`, `coachpreparecheckincopy`,
`coachundocheckin`, `coachskipcheckin`.

**Verify** (do not trust the CLI exit code):
- `gcloud run services describe <svc> --region=us-central1 --format=json`
  contains `"run.googleapis.com/invoker-iam-disabled": "true"`
- An unauthenticated `POST` to the function URL returns **401** (application
  layer rejecting an anonymous caller) and **not 403** (infrastructure block).

This does not weaken security: it only moves the auth decision from Cloud
Run's IAM layer to the application layer, which is how Firebase callables are
designed. Every handler still enforces `requireAuth`, App Check, and
`requireAssignment` (approved coach or super-admin).

## Deployment (in order — nothing is deployed by this branch)

1. **Rules**: `firebase deploy --only firestore:rules` (deploys
   `firestore.rules`; identical content is mirrored in `firestore_rules/`
   for the console workflow — verify in the console after deploy).
2. **Functions**: `cd functions && npm install && npm test && firebase
   deploy --only functions` — deploys the nine coach functions alongside the
   untouched existing ones (`repointsMonthlyAggregator`, Stripe). The v2
   `onSchedule` auto-provisions the hourly Cloud Scheduler job (enable the
   Cloud Scheduler API once per project).
3. **No migration / backfill**: nothing runs until a coach enables an
   athlete (per-athlete bounded bootstrap on enablement, idempotent, safe to
   retry). If any athlete was enabled on a pre-`analyticsVersion 2` build,
   the readiness gate re-bootstraps them automatically at the next
   checkpoint.
4. **Rollback**: functions can be rolled back by redeploying the previous
   revision; analytics collections are derived data and can be dropped +
   re-bootstrapped at any time; reports/settings are additive and unused by
   the rest of the app.
5. **Monitoring**: watch Cloud Functions logs for `coach bootstrap failed`,
   `report generation failed`, `checkpoint sweep failed`,
   `auto-disabling revoked coach/athlete enrollment`, and Eventarc retry
   volumes on `coachAnalyticsOnWorkoutWrite`.

## Known (non-blocking) limitations

- An extreme single-exercise rebuild (>~450 PB events for one exercise)
  would exceed one transaction's write budget; realistic athletes are far
  below this.
- Continuous pathological writes during a bootstrap could exhaust the
  20 drain rounds → `error` status, self-healed at the next enablement or
  checkpoint; state is never silently wrong, only delayed.
- A workout write racing a revocation may be maintained into the athlete's
  (athlete-owned, objective) analytics once before `enabledBy` cleanup
  lands; the revoked coach can read none of it.
- The timezone picker offers a curated IANA list; other zones require
  extending the list (server validates whatever is stored).
