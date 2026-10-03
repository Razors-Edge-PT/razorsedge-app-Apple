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
on its next three-minute cycle. Existing raw snapshot fields remain unchanged.

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
