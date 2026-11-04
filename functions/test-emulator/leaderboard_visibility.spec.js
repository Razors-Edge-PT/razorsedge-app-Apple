'use strict';

// PRODUCTION-ADAPTER tests for "Show me on leaderboards"
// (users/{uid}.leaderboardVisible) and the friend-gated users_showcase
// relocation, against the Firestore emulator (project rules-test — never
// production). Real workouts go through the real showcase and leaderboard
// adapters; each trigger's handler is called directly, as in the other specs.
//
// Boards use months in 2043 to stay isolated from the other specs; "now" is
// passed explicitly where a function takes it.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';
const CLOSED = '2043-02';
const LIVE = '2043-03';
const NOW = Date.parse('2043-03-20T00:00:00.000Z');

let showcase;
let lb;
let ageFs;
let medalsFs;
let seed;
let migrate;
let EXCLUDED;

test.before(() => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run through `npm run test:emulator`');
  if (!admin.apps.length) admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  showcase = require('../showcase/firestore_store');
  lb = require('../leaderboard/firestore_store');
  ageFs = require('../leaderboard/age_firestore');
  medalsFs = require('../leaderboard/medals_firestore');
  seed = require('../scripts/seed_leaderboard_visibility');
  migrate = require('../scripts/migrate_profile_showcase_private');
  EXCLUDED = require('../leaderboard/eligibility').EXCLUDED_LEADERBOARD_UIDS;
});

const db = () => admin.firestore();
const workout = (...rows) => ({ exercises: rows.map(([exerciseId, sets]) => ({ exerciseId, name: 'x', sets })) });
let seq = 0;
const created = new Set();
const freshUid = (tag) => {
  const uid = `vis_${tag}_${Date.now()}_${(seq += 1)}`;
  created.add(uid);
  return uid;
};

test.after(async () => {
  if (!admin.apps.length) return;
  for (const p of [CLOSED, LIVE]) {
    for (const col of ['leaderboards', 'leaderboardsAge', 'leaderboardPublic', 'leaderboardMedals', 'leaderboardMedalQueue']) {
      await db().recursiveDelete(db().collection(col).doc(p));
    }
    await db().recursiveDelete(db().collection('leaderboardPublic').doc(`${p}_age`));
    for (const sex of ['male', 'female']) {
      for (const col of ['leaderboards', 'leaderboardsAge', 'leaderboardPublic']) {
        await db().recursiveDelete(db().collection(col).doc(`${p}_${sex}`));
      }
      await db().recursiveDelete(db().collection('leaderboardPublic').doc(`${p}_age_${sex}`));
    }
  }
  for (const uid of [...created, EXCLUDED[0]]) {
    await db().recursiveDelete(db().collection('users').doc(uid));
    await db().collection('users_public').doc(uid).delete().catch(() => {});
    await db().collection('users_showcase').doc(uid).delete().catch(() => {});
    for (const col of ['leaderboards', 'leaderboardsAge']) {
      await db().collection(col).doc('all_time').collection('entries').doc(uid).delete().catch(() => {});
    }
    await lb.queueRef(uid).delete().catch(() => {});
    await showcase.jobRef(uid).delete().catch(() => {});
  }
});

/** An athlete with a private profile, a public identity and a weigh-in. */
async function makeAthlete(tag, extra) {
  const uid = freshUid(tag);
  await db().collection('users').doc(uid).set(Object.assign({ sex: 'M', dob: '10-05-1980' }, extra || {}));
  await db().collection('users_public').doc(uid).set({ username: `${tag}_${seq}`, photoURL: null });
  await db().collection('users').doc(uid).collection('weights')
    .add({ weight: 80, unit: 'kg', tod: 'am', timestamp: admin.firestore.Timestamp.fromMillis(Date.UTC(2043, 0, 1)) });
  return uid;
}

/** What showcaseOnWorkoutWrite + its leaderboard hooks + the worker do. */
async function logWorkout(uid, dateKey, data) {
  await db().collection('users').doc(uid).collection('workouts').doc(dateKey).set(data);
  await showcase.applyWorkoutDayTransactionally(uid, dateKey, data); // V1
  const v2 = await showcase.applyWorkoutDayV2Transactionally(uid, dateKey, data);
  if (v2.changed && v2.path !== 'queued') await lb.applyForWorkout(uid, dateKey);
  await showcase.runRebuildFor(uid);
  await fireShowcase(uid);
}

/** leaderboardOnShowcaseWrite for the current users_showcase document. */
async function fireShowcase(uid) {
  const snap = await showcase.showcaseRef(uid).get();
  return lb.handleShowcaseWrite(uid, null, snap.exists ? snap.data() : null);
}

/** What the medal and age entry-write triggers do in production. */
async function settleProjections(uids) {
  for (const p of [CLOSED, LIVE, 'all_time']) await medalsFs.refreshMedals(p);
  for (const uid of uids) {
    for (const p of [LIVE, 'all_time']) await ageFs.recomputeAthleteBoard(uid, p, NOW);
  }
}

async function setVisible(uid, visible) {
  const ref = db().collection('users').doc(uid);
  const before = (await ref.get()).data();
  await ref.set({ leaderboardVisible: visible }, { merge: true });
  return lb.handleVisibilityWrite(uid, before, (await ref.get()).data(), NOW);
}

const entry = async (p, uid) => (await lb.entryRef(p, uid).get()).exists;
const ageEntry = async (p, uid) => (await ageFs.ageEntryRef(p, uid).get()).exists;
const username = async (uid) => (await db().collection('users_public').doc(uid).get()).get('username');

async function publicRows(key) {
  const snap = await ageFs.publicRef(key).get();
  return snap.exists ? (snap.data().entries || []).map((r) => r.username) : [];
}

async function sexBoardUids(col, key) {
  const snap = await db().collection(col).doc(key).get();
  return snap.exists ? (snap.data().entries || []).map((r) => r.uid) : [];
}

async function medalUids(p) {
  const snap = await medalsFs.medalsRef(p).get();
  const cats = (snap.exists && snap.data().categories) || {};
  return [...new Set(Object.values(cats).flat().map((w) => w && w.uid))];
}

// ── Default and opt-out ─────────────────────────────────────────────────────

test('no saved choice → visible; opting out withdraws every projection and others move up', async () => {
  const a = await makeAthlete('a');
  const b = await makeAthlete('b');
  await logWorkout(a, `${CLOSED}-10`, workout([BENCH, [{ weight: 160, reps: 3 }]], [SQUAT, [{ weight: 200, reps: 3 }]]));
  await logWorkout(a, `${LIVE}-05`, workout([BENCH, [{ weight: 160, reps: 3 }]], [SQUAT, [{ weight: 200, reps: 3 }]]));
  await logWorkout(b, `${CLOSED}-11`, workout([BENCH, [{ weight: 100, reps: 3 }]]));
  await logWorkout(b, `${LIVE}-06`, workout([BENCH, [{ weight: 100, reps: 3 }]]));
  await settleProjections([a, b]);
  // A silver flag to withdraw as well (normally age.js decides it).
  await ageFs.ageBoardRef(LIVE).set({ silverUids: admin.firestore.FieldValue.arrayUnion(a) }, { merge: true });
  await ageFs.publishAll(NOW);

  for (const p of [CLOSED, LIVE, 'all_time']) assert.ok(await entry(p, a), `a on ${p} before opting out`);
  assert.ok(await ageEntry(LIVE, a));
  assert.ok((await medalUids(LIVE)).includes(a));
  assert.equal((await publicRows(LIVE))[0], await username(a), 'a leads the website board');
  assert.ok((await sexBoardUids('leaderboards', `${LIVE}_male`)).includes(a));

  assert.equal(await setVisible(a, false), 'withdrawn');

  for (const p of [CLOSED, LIVE, 'all_time']) {
    assert.equal(await entry(p, a), false, `no ${p} entry`);
    assert.ok(await entry(p, b), `b keeps ${p}`);
    assert.ok(!(await medalUids(p)).includes(a), `no ${p} medal`);
    assert.ok((await medalUids(p)).includes(b), `b moves up into the ${p} medals`);
  }
  assert.equal(await ageEntry(LIVE, a), false);
  assert.equal(await ageEntry('all_time', a), false);
  assert.ok(!((await ageFs.ageBoardRef(LIVE).get()).data().silverUids || []).includes(a));
  // Republished at once: website raw/age views and the app sex boards.
  const aName = await username(a);
  for (const key of [LIVE, `${LIVE}_age`, `${LIVE}_male`, `${LIVE}_age_male`, 'all_time', 'all_time_age']) {
    assert.ok(!(await publicRows(key)).includes(aName), `website ${key}`);
  }
  assert.equal((await publicRows(LIVE))[0], await username(b), 'b is ranked first now');
  for (const [col, key] of [['leaderboards', `${LIVE}_male`], ['leaderboardsAge', `${LIVE}_male`]]) {
    assert.ok(!(await sexBoardUids(col, key)).includes(a), `${col}/${key}`);
  }
  assert.equal(seed.traceCount(await seed.publicTraces(db(), a)), 0, 'nothing public names a');

  // Private data is untouched.
  assert.ok((await lb.daysCol(a).doc(`${LIVE}-05`).get()).exists, 'rePointDays kept');
  assert.ok((await db().collection('users').doc(a).collection('workouts').doc(`${LIVE}-05`).get()).exists);
  assert.ok(await showcase.readPublishedSnapshotV2(a), 'showcase kept');

  // ── While hidden, no producer republishes ──
  await logWorkout(a, `${LIVE}-12`, workout([BENCH, [{ weight: 170, reps: 3 }]]));
  await lb.applyRequestForUser(a, { dateKeys: [`${LIVE}-12`] });
  await lb.applyRequestForUser(a, { sinceDateKey: '' });
  await showcase.requestRebuildFor(a, { mode: 'leaderboard', reason: 'test' });
  await showcase.runRebuildFor(a);
  await lb.refreshAllTimeForUser(a, 'test');
  await lb.handlePublicProfileWrite(a, { username: 'old' }, { username: 'renamed' });
  await lb.enqueueRecalc(a, { dateKeys: [`${LIVE}-12`] }, 'test');
  const deps = lb.reconcileDeps(NOW);
  const queued = (await deps.listQueue(50)).filter((x) => x.uid === a);
  for (const item of queued) await deps.processItem(item);
  await settleProjections([a, b]);
  await ageFs.publishAll(NOW);
  for (const p of [CLOSED, LIVE, 'all_time']) assert.equal(await entry(p, a), false, `still no ${p} entry`);
  assert.equal(await ageEntry(LIVE, a), false);
  assert.equal(seed.traceCount(await seed.publicTraces(db(), a)), 0);
  assert.ok((await lb.daysCol(a).doc(`${LIVE}-12`).get()).exists, 'new training is still scored privately');

  // ── A stale "turned on" event cannot override the saved "off" ──
  assert.equal(await lb.handleVisibilityWrite(a, { leaderboardVisible: false }, { leaderboardVisible: true }, NOW), 'withdrawn');
  assert.equal(await entry(LIVE, a), false);

  // ── Opting back in rebuilds every board from existing data ──
  assert.equal(await setVisible(a, true), 'rebuild');
  await showcase.runRebuildFor(a); // the worker
  for (const p of [CLOSED, LIVE, 'all_time']) assert.ok(await entry(p, a), `${p} rebuilt`);
  const month = (await lb.entryRef(LIVE, a).get()).data();
  const days = (await lb.daysCol(a).where('periodKey', '==', LIVE).get()).docs.map((d) => d.data());
  assert.equal(month.totalPointsUnits, days.reduce((n, d) => n + d.totalPointsUnits, 0), 'includes the day logged while hidden');
  await settleProjections([a, b]);
  await ageFs.publishAll(NOW);
  assert.ok(await ageEntry(LIVE, a));
  assert.equal((await publicRows(LIVE))[0], await username(a), 'a leads again');
  assert.ok((await medalUids(LIVE)).includes(a));

  // A stale "turned off" event cannot withdraw the saved "on".
  assert.equal(await lb.handleVisibilityWrite(a, { leaderboardVisible: true }, { leaderboardVisible: false }, NOW), 'rebuild');
  assert.ok(await entry(LIVE, a));
});

test('a concurrent opt-out wins over recomputations racing it', async () => {
  const a = await makeAthlete('race');
  await logWorkout(a, `${LIVE}-07`, workout([BENCH, [{ weight: 120, reps: 3 }]]));
  assert.ok(await entry(LIVE, a));
  const ref = db().collection('users').doc(a);
  await Promise.all([
    lb.applyRequestForUser(a, { dateKeys: [`${LIVE}-07`] }),
    lb.refreshAllTimeForUser(a, 'race'),
    (async () => {
      await ref.set({ leaderboardVisible: false }, { merge: true });
      await lb.handleVisibilityWrite(a, {}, { leaderboardVisible: false }, NOW);
    })(),
    lb.applyRequestForUser(a, { sinceDateKey: '' }),
  ]);
  // Whatever the interleaving, the withdrawal the opt-out triggers runs after
  // it; delivering it again (a retry) must also leave nothing behind.
  await lb.handleVisibilityWrite(a, {}, { leaderboardVisible: false }, NOW);
  assert.equal(await entry(LIVE, a), false);
  assert.equal(await entry('all_time', a), false);
});

test('test/demo exclusions remain excluded even with a saved "visible"', async () => {
  const { recomputeMonth } = require('../leaderboard/store');
  const day = { dateKey: `${LIVE}-02`, periodKey: LIVE, totalPointsUnits: 5000000, categories: { horizontalPress: { pointsUnits: 5000000 } } };
  const resum = (uid) => db().runTransaction(async (tx) => {
    const store = lb.leaderboardStore(uid, showcase.transactionReader(tx));
    await recomputeMonth(store, LIVE);
    await store.flush();
  });
  const demo = EXCLUDED[0];
  const control = await makeAthlete('control');
  for (const uid of [demo, control]) {
    await db().collection('users').doc(uid).set({ leaderboardVisible: true, sex: 'M' }, { merge: true });
    await lb.daysCol(uid).doc(day.dateKey).set(day);
    await lb.entryRef(LIVE, uid).set({ uid, totalPointsUnits: 999, username: 'stale' });
    await resum(uid);
  }
  assert.equal(await entry(LIVE, demo), false, 'the static exclusion still withdraws it');
  assert.equal((await lb.entryRef(LIVE, control).get()).data().totalPointsUnits, 5000000, 'an ordinary visible athlete is ranked');
  assert.equal(await lb.handleVisibilityWrite(demo, { leaderboardVisible: false }, { leaderboardVisible: true }, NOW), 'excluded',
    'turning "visible" on never schedules a rebuild for an excluded account');
  await lb.daysCol(demo).doc(day.dateKey).delete();
});

// ── The one-time seed ───────────────────────────────────────────────────────

test('seed: an absent choice becomes hidden once; a choice the athlete saved later always wins', async () => {
  const w = await makeAthlete('seeded');
  await logWorkout(w, `${LIVE}-08`, workout([BENCH, [{ weight: 110, reps: 3 }]]));
  assert.ok(await entry(LIVE, w), 'visible before seeding');

  assert.equal(await seed.applySeed(db(), admin, w), 'seed');
  assert.equal((await db().collection('users').doc(w).get()).get('leaderboardVisible'), false);
  await lb.withdrawUser(w, NOW);
  assert.equal(await entry(LIVE, w), false);
  assert.equal(seed.traceCount(await seed.publicTraces(db(), w)), 0);
  assert.equal(await seed.applySeed(db(), admin, w), 'explicit', 'idempotent');

  // She turns it back on herself; re-running the seed never forces it off.
  assert.equal(await setVisible(w, true), 'rebuild');
  await showcase.runRebuildFor(w);
  assert.ok(await entry(LIVE, w));
  assert.equal(await seed.applySeed(db(), admin, w), 'explicit');
  assert.equal((await db().collection('users').doc(w).get()).get('leaderboardVisible'), true);
  assert.ok(await entry(LIVE, w));

  // Every other ordinary athlete is untouched by the seed.
  const other = await makeAthlete('other');
  assert.equal((await db().collection('users').doc(other).get()).get('leaderboardVisible'), undefined);
  assert.equal(await seed.applySeed(db(), admin, 'missing_user_xyz'), 'missing-user');
});

// ── Friend-gated showcase ───────────────────────────────────────────────────

test('showcase snapshots publish to users_showcase (with the transition mirror)', async () => {
  const uid = await makeAthlete('show');
  await logWorkout(uid, `${LIVE}-09`, workout([BENCH, [{ weight: 100, reps: 3 }]]));
  const priv = (await showcase.showcaseRef(uid).get()).data();
  assert.equal(priv.profileShowcaseV2.schema, 'profileShowcaseV2');
  assert.ok(priv.profileShowcaseV1);
  const pub = (await db().collection('users_public').doc(uid).get()).data();
  assert.equal(showcase.MIRROR_SHOWCASE_TO_USERS_PUBLIC, true);
  assert.deepEqual(pub.profileShowcaseV2, priv.profileShowcaseV2, 'mirrored for builds before 1.7.58');
  assert.ok(await entry('all_time', uid), 'all time follows users_showcase');
});

test('an athlete not yet migrated keeps every lift: reads fall back to the legacy field', async () => {
  const uid = await makeAthlete('legacy');
  await logWorkout(uid, `${LIVE}-10`, workout([BENCH, [{ weight: 100, reps: 3 }]]));
  // Simulate the pre-release layout: snapshots only on users_public.
  const priv = (await showcase.showcaseRef(uid).get()).data();
  await showcase.showcaseRef(uid).delete();
  await db().collection('users_public').doc(uid).set(
    { profileShowcaseV1: priv.profileShowcaseV1, profileShowcaseV2: priv.profileShowcaseV2 }, { merge: true });
  assert.deepEqual(await showcase.readPublishedSnapshotV2(uid), priv.profileShowcaseV2);
  assert.equal(await lb.refreshAllTimeForUser(uid, 'test'), 'set', 'all time still built');

  await logWorkout(uid, `${LIVE}-11`, workout([SQUAT, [{ weight: 140, reps: 3 }]]));
  const after = (await showcase.showcaseRef(uid).get()).data();
  assert.ok(after.profileShowcaseV1.lifts.bench, 'bench survived the squat write (V1 append path)');
  assert.ok(after.profileShowcaseV1.lifts.squat);
  const cats = after.profileShowcaseV2.categories;
  assert.ok(cats.horizontalPress && cats.squatPattern, 'both V2 categories present');
});

test('migration copies without overwriting and strips only what is safely copied', async () => {
  const uid = await makeAthlete('mig');
  const v1 = { schema: 'profileShowcaseV1', lifts: {} };
  const v2 = { schema: 'profileShowcaseV2', categories: {} };
  await db().collection('users_public').doc(uid).set({ profileShowcaseV1: v1, profileShowcaseV2: v2 }, { merge: true });
  const newer = { schema: 'profileShowcaseV2', categories: { horizontalPress: {} } };
  await showcase.showcaseRef(uid).set({ profileShowcaseV2: newer });

  assert.deepEqual(await migrate.migrateOne(db(), admin, uid, 'copy'), { copied: ['profileShowcaseV1'], stripped: [] });
  let priv = (await showcase.showcaseRef(uid).get()).data();
  assert.deepEqual(priv.profileShowcaseV2, newer, 'the server copy is kept');
  assert.deepEqual(priv.profileShowcaseV1, v1);

  assert.deepEqual(await migrate.migrateOne(db(), admin, uid, 'strip'),
    { copied: [], stripped: ['profileShowcaseV1', 'profileShowcaseV2'] });
  const pub = (await db().collection('users_public').doc(uid).get()).data();
  assert.equal(pub.profileShowcaseV1, undefined);
  assert.equal(pub.profileShowcaseV2, undefined);
  assert.ok(pub.username, 'identity untouched');
  priv = (await showcase.showcaseRef(uid).get()).data();
  assert.deepEqual(priv.profileShowcaseV1, v1);
  assert.deepEqual(await migrate.migrateOne(db(), admin, uid, 'strip'), { copied: [], stripped: [] }, 'idempotent');
});
