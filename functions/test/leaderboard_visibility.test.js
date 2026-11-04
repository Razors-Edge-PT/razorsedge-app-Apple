'use strict';

// "Show me on leaderboards": users/{uid}.leaderboardVisible.
//
// Workouts go through the REAL profile V2 store and the leaderboard store
// (in memory), exactly as in leaderboard.test.js; the Firestore paths —
// withdrawal, triggers, transactions — are covered by
// test-emulator/leaderboard_visibility.spec.js.

const test = require('node:test');
const assert = require('node:assert');

const { applyWorkoutDayV2, memoryStoreV2 } = require('../showcase/store_v2');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { ALL_TIME_PERIOD } = require('../leaderboard/reducer');
const {
  applyRequest,
  refreshAllTime,
  recomputeMonth,
  rebuildUser,
  memoryLeaderboardStore,
} = require('../leaderboard/store');
const {
  EXCLUDED_LEADERBOARD_UIDS,
  LEADERBOARD_VISIBLE_FIELD,
  isLeaderboardEligibleUid,
  isLeaderboardVisible,
  isLeaderboardEligible,
} = require('../leaderboard/eligibility');
const seed = require('../scripts/seed_leaderboard_visibility');
const migrate = require('../scripts/migrate_profile_showcase_private');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';
const workout = (exerciseId, weight, reps) => ({ exercises: [{ exerciseId, name: 'x', sets: [{ weight, reps }] }] });

/** One athlete over shared entries; [visible] is their saved choice. */
function athlete(uid, entries, initialVisible) {
  const weighIns = [{ id: 'w0', dateKey: '2026-08-01', weight: 80 }];
  const bw = (d) => pickBodyweightAsOf(weighIns, d);
  const v2 = memoryStoreV2({ bodyweightAsOf: bw, sex: 'M' });
  let visible = initialVisible;
  const lb = memoryLeaderboardStore(uid, {
    v2Days: () => [...v2._days.values()],
    bodyweightAsOf: bw,
    sex: 'M',
    publicProfile: async () => ({ username: uid, profileShowcaseV2: await v2.getSnapshot() }),
    leaderboardVisible: () => visible,
    entries,
  });
  return {
    uid,
    lb,
    async log(dateKey, data) {
      const r = await applyWorkoutDayV2(v2, dateKey, data);
      if (r.changed) {
        await applyRequest(lb, r.path === 'bootstrap' ? { full: true } : { dateKeys: [dateKey] });
        await refreshAllTime(lb);
      }
    },
    setVisible(v) {
      visible = v;
    },
    entry: (p) => entries.get(`${p}/${uid}`) || null,
    days: () => [...lb._days.values()],
  };
}

function ranking(entries, periodKey) {
  return [...entries.entries()]
    .filter(([k]) => k.startsWith(`${periodKey}/`))
    .map(([, e]) => e)
    .sort((a, b) => b.totalPointsUnits - a.totalPointsUnits)
    .map((e) => e.uid);
}

// ── The choice itself ───────────────────────────────────────────────────────

test('missing document, missing field or true → visible; only an explicit false hides', () => {
  assert.strictEqual(LEADERBOARD_VISIBLE_FIELD, 'leaderboardVisible');
  assert.strictEqual(isLeaderboardVisible(null), true, 'no users document');
  assert.strictEqual(isLeaderboardVisible(undefined), true);
  assert.strictEqual(isLeaderboardVisible({}), true, 'existing user, never chose');
  assert.strictEqual(isLeaderboardVisible({ username: 'new' }), true, 'new user');
  assert.strictEqual(isLeaderboardVisible({ leaderboardVisible: true }), true);
  assert.strictEqual(isLeaderboardVisible({ leaderboardVisible: false }), false);
  // Rules only accept a bool; anything else is NOT read as an opt-out.
  assert.strictEqual(isLeaderboardVisible({ leaderboardVisible: 'false' }), true);
  assert.strictEqual(isLeaderboardVisible({ leaderboardVisible: 0 }), true);
});

test('test/demo exclusions stay excluded whatever their saved choice', () => {
  assert.deepStrictEqual([...EXCLUDED_LEADERBOARD_UIDS], [
    'LWXGJ5SlIzM4OxEkOdTuv6d1c5b2',
    'jhIB7Yi1whYwPvBSmK27KltJGn23',
  ]);
  for (const uid of EXCLUDED_LEADERBOARD_UIDS) {
    assert.strictEqual(isLeaderboardEligibleUid(uid), false);
    assert.strictEqual(isLeaderboardEligible(uid, { leaderboardVisible: true }), false);
    assert.strictEqual(isLeaderboardEligible(uid, {}), false);
  }
  assert.strictEqual(isLeaderboardEligible('ordinary', {}), true);
  assert.strictEqual(isLeaderboardEligible('ordinary', { leaderboardVisible: false }), false);
});

test('no athlete other than the static test/demo accounts is excluded by UID', () => {
  // The seeded athlete is hidden by her saved preference, never by a UID rule.
  assert.strictEqual(isLeaderboardEligibleUid('GiJXUxez7HgjPBMuFLhkrQvC9nE3'), true);
});

// ── Producers ───────────────────────────────────────────────────────────────

test('a hidden athlete gets no monthly or all-time entry, but private day scores are kept', async () => {
  const entries = new Map();
  const a = athlete('a', entries, false);
  await a.log('2026-09-02', workout(BENCH, 100, 5));
  assert.strictEqual(a.entry('2026-09'), null);
  assert.strictEqual(a.entry(ALL_TIME_PERIOD), null);
  assert.strictEqual(a.days().length, 1, 'rePointDays still maintained');
  assert.ok(a.days()[0].totalPointsUnits > 0);
});

test('opting out withdraws existing entries on every producer path; others move up', async () => {
  const entries = new Map();
  const a = athlete('a', entries, undefined);
  const b = athlete('b', entries, undefined);
  await a.log('2026-09-02', workout(BENCH, 140, 5));
  await b.log('2026-09-03', workout(BENCH, 100, 5));
  assert.deepStrictEqual(ranking(entries, '2026-09'), ['a', 'b']);
  assert.deepStrictEqual(ranking(entries, ALL_TIME_PERIOD), ['a', 'b']);

  a.setVisible(false);
  // A later workout (date path), a month re-sum, the all-time refresh and a
  // whole rebuild each withdraw rather than republish.
  await a.log('2026-09-10', workout(SQUAT, 120, 5));
  assert.strictEqual(a.entry('2026-09'), null);
  assert.strictEqual(await refreshAllTime(a.lb), 'hidden');
  assert.strictEqual(a.entry(ALL_TIME_PERIOD), null);
  assert.strictEqual(await recomputeMonth(a.lb, '2026-09'), null);
  await rebuildUser(a.lb);
  assert.deepStrictEqual(ranking(entries, '2026-09'), ['b']);
  assert.deepStrictEqual(ranking(entries, ALL_TIME_PERIOD), ['b']);
  assert.strictEqual(a.days().length, 2, 'both training days still scored privately');
});

test('repeated or out-of-order recomputations while hidden never republish', async () => {
  const entries = new Map();
  const a = athlete('a', entries, false);
  await a.log('2026-09-02', workout(BENCH, 100, 5));
  for (let i = 0; i < 3; i += 1) {
    await applyRequest(a.lb, { dateKeys: ['2026-09-02'] });
    await applyRequest(a.lb, { sinceDateKey: '' });
    await applyRequest(a.lb, { full: true });
    await refreshAllTime(a.lb);
  }
  assert.strictEqual(ranking(entries, '2026-09').length, 0);
  assert.strictEqual(ranking(entries, ALL_TIME_PERIOD).length, 0);
});

test('opting back in rebuilds the same rankings from existing data — no new workout', async () => {
  const entries = new Map();
  const a = athlete('a', entries, undefined);
  const b = athlete('b', entries, undefined);
  await a.log('2026-08-20', workout(BENCH, 150, 3));
  await a.log('2026-09-02', workout(BENCH, 140, 5));
  await b.log('2026-09-03', workout(BENCH, 100, 5));
  const before = JSON.stringify([...entries.entries()].sort());

  a.setVisible(false);
  await rebuildUser(a.lb);
  assert.deepStrictEqual(ranking(entries, '2026-08'), []);
  assert.deepStrictEqual(ranking(entries, '2026-09'), ['b']);

  a.setVisible(true);
  await rebuildUser(a.lb); // what the opt-in rebuild job runs
  assert.strictEqual(JSON.stringify([...entries.entries()].sort()), before, 'identical to before opting out');
  assert.deepStrictEqual(ranking(entries, '2026-09'), ['a', 'b']);
});

// ── Seed script (pure parts) ────────────────────────────────────────────────

test('seed: dry-run by default and the target must be named and verified', () => {
  const uid = 'GiJXUxez7HgjPBMuFLhkrQvC9nE3';
  const opts = seed.parseArgs(['--uid', uid, '--expect-email', 'a@b.c']);
  assert.strictEqual(opts.apply, false);
  assert.strictEqual(opts.verify, false);
  assert.strictEqual(opts.projectId, 'goodlift-us-storage');
  assert.throws(() => seed.parseArgs(['--expect-email', 'a@b.c']), /--uid/);
  assert.throws(() => seed.parseArgs(['--uid', uid]), /--expect-email/);
  assert.throws(() => seed.parseArgs(['--uid', 'x/../y', '--expect-email', 'a@b.c']), /--uid/);
  assert.throws(() => seed.parseArgs(['--uid', uid, '--expect-email', 'a@b.c', '--apply', '--verify']), /either/);
  assert.strictEqual(seed.emailMatches(' Person@Example.com ', 'person@example.com'), true);
  assert.strictEqual(seed.emailMatches('other@example.com', 'person@example.com'), false);
  assert.strictEqual(seed.emailMatches(undefined, 'person@example.com'), false);
});

test('seed: only an ABSENT choice is seeded; a saved true (or false) always wins', () => {
  assert.strictEqual(seed.planSeed(null), 'missing-user');
  assert.strictEqual(seed.planSeed({}), 'seed');
  assert.strictEqual(seed.planSeed({ username: 'x' }), 'seed');
  assert.strictEqual(seed.planSeed({ leaderboardVisible: true }), 'explicit');
  assert.strictEqual(seed.planSeed({ leaderboardVisible: false }), 'explicit');
});

test('seed --verify passes ONLY for an explicit false with no public projections', () => {
  const none = { entries: [], ageEntries: [], silver: [], medals: [], sexBoards: [], websiteRows: [] };
  const some = Object.assign({}, none, { websiteRows: ['all_time'] });
  const v = (data, traces) => seed.verifyOutcome(data, traces);
  assert.strictEqual(v({}, none).ok, false, 'absent → fails');
  assert.match(v({}, none).reason, /defaults to VISIBLE/);
  assert.strictEqual(v({ leaderboardVisible: true }, none).ok, false, 'true → fails');
  assert.match(v({ leaderboardVisible: true }, none).reason, /saved VISIBLE/);
  assert.strictEqual(v({ leaderboardVisible: 'false' }, none).ok, false, 'a non-boolean is not hidden');
  assert.strictEqual(v(null, none).ok, false, 'missing users/{uid} → fails');
  assert.strictEqual(v({ leaderboardVisible: false }, none).ok, true, 'false, no traces → passes');
  assert.strictEqual(v({ leaderboardVisible: false }, some).ok, false, 'false with traces → fails');
  assert.match(v({ leaderboardVisible: false }, some).reason, /1 public projection/);
});

// ── Showcase migration (pure parts) ─────────────────────────────────────────

test('migration: copy never overwrites newer data; strip only after a private copy', () => {
  assert.throws(() => migrate.parseArgs([]), /Choose one/);
  assert.throws(() => migrate.parseArgs(['--copy', '--strip']), /Choose one/);
  assert.throws(() => migrate.parseArgs(['--verify', '--apply']), /read-only/);
  assert.strictEqual(migrate.parseArgs(['--copy']).apply, false);

  const v1 = { schema: 'profileShowcaseV1', lifts: { bench: 1 } };
  const v2 = { schema: 'profileShowcaseV2', categories: {} };
  const newer = { schema: 'profileShowcaseV2', categories: { x: 1 } };
  assert.deepStrictEqual(
    migrate.planAthlete('copy', { profileShowcaseV1: v1, profileShowcaseV2: v2 }, null),
    { copy: { profileShowcaseV1: v1, profileShowcaseV2: v2 }, strip: [] });
  assert.deepStrictEqual(
    migrate.planAthlete('copy', { profileShowcaseV2: v2 }, { profileShowcaseV2: newer }),
    { copy: {}, strip: [] }, 'server copy is newer and is kept');
  assert.deepStrictEqual(
    migrate.planAthlete('strip', { username: 'x', profileShowcaseV2: v2 }, null),
    { copy: { profileShowcaseV2: v2 }, strip: ['profileShowcaseV2'] }, 'copied in the same transaction');
  assert.deepStrictEqual(
    migrate.planAthlete('strip', { username: 'x' }, { profileShowcaseV2: newer }),
    { copy: {}, strip: [] }, 'identity-only profile: nothing to do');
});
