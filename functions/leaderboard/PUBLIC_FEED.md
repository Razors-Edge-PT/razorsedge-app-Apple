# Website age feed deployment

The website is hosted on Cloudflare Pages. This backend extension lets its
existing public proxy request the app's precomputed age rankings. It changes
publication and HTTP selection, not the scoring model or app build.

Default `?period=current|all_time` remains raw schema 1. Optional `&view=age`
selects schema 2: `view`, `periodKey`, `generatedAt`, `ageModelVersion`,
`rankedCount`, `incompleteCount`, and entries containing only `rank`, public
`username`, `adjustedTotalUnits` and raw `medals`. No UID, DOB, exact age,
individual age band or Silverback flag is in the age response.

The publisher uses the app's existing composite index and tie order across all
complete current-model age entries, then copies the first 20 public rows. It
does not re-rank the raw top 20. Two additional server-only snapshots are written
under existing rules: `leaderboardPublic/{month}_age` and
`leaderboardPublic/all_time_age`. Anonymous requests read one cached public
snapshot and re-apply the allowlist.

## Scoped deployment

From an authenticated release checkout containing this change, install Functions
dependencies with `npm ci`, then deploy only:

```bash
firebase deploy --only "functions:leaderboardPublicPublisher,functions:publicLeaderboard" --project goodlift-us-storage
```

No Flutter rebuild/version bump, repeat backfill, rules/index change or other
function deployment is needed. The scheduled publisher creates age snapshots
at the next hour (minute 0 in Auckland time). Existing raw snapshot fields remain unchanged.

Domain Restricted Sharing stays in place. After deploying, confirm Cloud Run
service `publicleaderboard`, region `us-central1`, project `goodlift-us-storage`,
retains `invoker-iam-disabled=true`. If reset, restore anonymous invocation for
this already-public service only:

```bash
gcloud run services update publicleaderboard --region us-central1 --project goodlift-us-storage --no-invoker-iam-check
```

Do not change organisation policies or grant `allUsers`. Check anonymous GET
for both periods and views returns 200 with JSON/nosniff, matches the app's
corresponding server ranking and exposes only the fields above. Check the same
four queries through `https://goodliftapp.com/api/leaderboard`.

## Checks

Use Node 22 for `node --test` in `functions`. Run the affected Firestore emulator
spec against the isolated `rules-test` project:

```bash
firebase emulators:exec --only firestore --project rules-test "node --test --test-concurrency=1 test-emulator/leaderboard_age.spec.js"
```

The spec covers a raw rank-21 athlete reaching age rank 1, exclusions, public
field allowlists and unchanged-snapshot freshness in both views.

## Cost settings and deployment checks

The website publisher now runs hourly (`0 * * * *`), not every three minutes.
Its existing Scheduler job is reused, with zero retries. Publisher settings:
256 MiB, fractional CPU (`gcf_gen1`, 1/6 CPU), minInstances 0, maxInstances 1,
concurrency 1 and timeout 15 seconds. The public HTTP function uses the same
CPU/memory/instance limits and a five-second timeout. In-memory HTTP caching
is one hour; all responses remain bounded by a 150-minute snapshot age limit.
Cloudflare adds an hourly cache slot and the page checks every 15 minutes.

After deploying verify the actual Scheduler cron, fractional CPU allocation,
instance limits and timeouts on both services. Make one bounded test invocation
of the existing publisher if needed to populate snapshots, rather than restoring
a frequent schedule or running repeated backfills. Verify cold and warm
anonymous reads work within five seconds. If a limit fails, report it rather
than silently raising the limits.

The target is US$0.25/month for additional website leaderboard operation at
current usage. Check the actual Firestore location, free quota usage and measured
function durations before calling that target verified. For illustration only,
744 hourly runs in a 31-day month at 15 seconds each, 1/6 CPU and 256 MiB cost
about US$0.052 in active compute before allowances (excluding startup and HTTP
traffic). At the present board sizes, publisher Firestore operations are about
US$0.029/month at us-central1 rates before allowances. The existing Scheduler
job may already cost US$0.10/month after the account's free jobs.

These are estimates, not a hard cap: visitor/direct HTTP requests, per-location
Cloudflare caches, startup, build/container storage and other shared usage also
count. Ordinary budget alerts do not stop spending. Do not impose a project-wide
Cloud Run spend cap or disable project billing: that could interrupt unrelated
GoodLift functions. Report projected incremental cost and the remaining risk;
do not mark the US$0.25/month target verified without billing evidence.
