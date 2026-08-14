'use strict';

// Emulator integration tests: exercise the REAL Firestore adapter,
// transactions and bootstrap ownership against the Firestore emulator
// (Admin SDK bypasses rules, as in production Cloud Functions).
//   npm run test:rules
//
// emulators:exec sets FIRESTORE_EMULATOR_HOST for this process.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'rules-test';
process.env.FUNCTIONS_EMULATOR = 'true';

const admin = require('firebase-admin');
const coach = require('../coach');
const { applyWorkoutDay, bulkRebuild } = require('../coach/analytics_store');
const { copyTransaction, undoTransaction, skipTransaction, TxnError } = require('../coach/checkin_txns');
const enrollment = require('../coach/enrollment');
const { E1RM_FORMULA_VERSION } = require('../coach/e1rm');

const { firestoreStore, claimBootstrap, runBootstrap, generateReport } = coach._internals;
const db = admin.firestore();

assert.ok(process.env.FIRESTORE_EMULATOR_HOST,
  'integration.spec.js must run under firebase emulators:exec');

const VERSIONS = { formulaVersion: E1RM_FORMULA_VERSION, analyticsVersion: 2 };

let seq = 0;
function freshUid(prefix) {
  seq += 1;
  return `${prefix}${Date.now()}_${seq}`;
}

const bench = (w, reps = 5) => ({
  exercises: [{
    exerciseId: 'bench', name: 'Bench Press, Barbell',
    sets: [{ weight: w, reps }],
  }],
});

async function seedWorkout(uid, dateKey, data) {
  await db.doc(`users/${uid}/workouts/${dateKey}`).set(data);
}

async function analyticsSnapshot(uid) {
  const base = db.doc(`coachAnalytics/${uid}`);
  const [exs, evs, days] = await Promise.all([
    base.collection('exercises').get(),
    base.collection('events').get(),
    base.collection('exerciseDays').get(),
  ]);
  const norm = (snap) => snap.docs
    .map((d) => [d.id, stripTs(d.data())])
    .sort(([a], [b]) => (a < b ? -1 : 1));
  return JSON.stringify({ exercises: norm(exs), events: norm(evs), days: norm(days) });
}

function stripTs(data) {
  const out = { ...data };
  delete out.updatedAt;
  return out;
}

// ── Adapter: fast path + rebuild parity on real Firestore ───────────────────

test('emulator: incremental applyWorkoutDay equals a clean rebuild', async () => {
  const uidA = freshUid('intA');
  const uidB = freshUid('intB');
  const seqDays = [
    ['2026-01-05', bench(100)],
    ['2026-01-12', bench(102.5)],
    ['2026-01-19', bench(101)],
  ];
  // Incremental on athlete A.
  for (const [dateKey, data] of seqDays) {
    const s = firestoreStore(uidA);
    await applyWorkoutDay(s, dateKey, data);
    await s.flush();
  }
  // Edit + delete self-heal.
  const sEdit = firestoreStore(uidA);
  await applyWorkoutDay(sEdit, '2026-01-12', bench(99));
  await sEdit.flush();

  // Control: clean bulk build on athlete B with the final truth.
  const sB = firestoreStore(uidB);
  await bulkRebuild(sB, [
    ['2026-01-05', bench(100)], ['2026-01-12', bench(99)], ['2026-01-19', bench(101)],
  ]);
  await sB.flush();

  const a = (await analyticsSnapshot(uidA)).replaceAll(uidA, 'X');
  const b = (await analyticsSnapshot(uidB)).replaceAll(uidB, 'X');
  assert.equal(a, b);
});

test('emulator: concurrent triggers on the same exercise serialise via transactions', async () => {
  const uid = freshUid('conc');
  const s0 = firestoreStore(uid);
  await applyWorkoutDay(s0, '2026-01-05', bench(100));
  await s0.flush();

  // Two "triggers" running simultaneously with separate stores.
  await Promise.all([
    (async () => {
      const s = firestoreStore(uid);
      await applyWorkoutDay(s, '2026-01-12', bench(102.5));
      await s.flush();
    })(),
    (async () => {
      const s = firestoreStore(uid);
      await applyWorkoutDay(s, '2026-01-19', bench(105));
      await s.flush();
    })(),
  ]);

  const control = freshUid('concCtl');
  const sC = firestoreStore(control);
  await bulkRebuild(sC, [
    ['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)], ['2026-01-19', bench(105)],
  ]);
  await sC.flush();

  const a = (await analyticsSnapshot(uid)).replaceAll(uid, 'X');
  const b = (await analyticsSnapshot(control)).replaceAll(control, 'X');
  assert.equal(a, b);
});

// ── Bootstrap ownership (item E) ────────────────────────────────────────────

test('emulator: two simultaneous claims — exactly one run wins', async () => {
  const uid = freshUid('claim');
  const [r1, r2] = await Promise.all([
    claimBootstrap(uid, { maintenanceWasOff: true }),
    claimBootstrap(uid, { maintenanceWasOff: true }),
  ]);
  const winners = [r1, r2].filter(Boolean);
  assert.equal(winners.length, 1, `expected one winner, got ${winners.length}`);
});

test('emulator: workout written mid-bootstrap is reconciled before completion', async () => {
  const uid = freshUid('boot');
  await seedWorkout(uid, '2026-01-05', bench(100));
  await seedWorkout(uid, '2026-01-12', bench(102.5));

  const runId = await claimBootstrap(uid, { maintenanceWasOff: true });
  assert.ok(runId);

  // Simulate the workout trigger during the run: the athlete edits Jan 12
  // and the (running) status defers the date into dirtyDates.
  await seedWorkout(uid, '2026-01-12', bench(107.5));
  await db.doc(`coachAnalytics/${uid}`).update({
    dirtyDates: admin.firestore.FieldValue.arrayUnion('2026-01-12'),
  });

  await runBootstrap(uid, runId);

  const state = (await db.doc(`coachAnalytics/${uid}`).get()).data();
  assert.equal(state.bootstrapStatus, 'complete');
  assert.equal(enrollment.analyticsReady(state, VERSIONS), true);

  // Final analytics reflect the EDITED workout with no further writes.
  const ev = await db.doc(`coachAnalytics/${uid}`).collection('events').get();
  const repEvents = ev.docs.map((d) => d.data()).filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 1);
  assert.equal(repEvents[0].weightKg, 107.5);
});

test('emulator: a superseded (stale) run cannot damage the new run\'s state', async () => {
  const uid = freshUid('stale');
  await seedWorkout(uid, '2026-01-05', bench(100));

  const run1 = await claimBootstrap(uid, { maintenanceWasOff: true });
  assert.ok(run1);
  // run1 crashes: make its claim stale, then a new run takes over.
  await db.doc(`coachAnalytics/${uid}`).update({
    bootstrapAtMs: Date.now() - enrollment.BOOTSTRAP_FRESH_MS - 1000,
  });
  const run2 = await claimBootstrap(uid, { maintenanceWasOff: true });
  assert.ok(run2 && run2 !== run1);
  await runBootstrap(uid, run2);
  const afterRun2 = (await db.doc(`coachAnalytics/${uid}`).get()).data();
  assert.equal(afterRun2.bootstrapStatus, 'complete');
  assert.equal(afterRun2.bootstrapRunId, run2);

  // The zombie run1 resumes: it must not clear state, mark complete or error.
  await runBootstrap(uid, run1);
  const afterZombie = (await db.doc(`coachAnalytics/${uid}`).get()).data();
  assert.equal(afterZombie.bootstrapStatus, 'complete');
  assert.equal(afterZombie.bootstrapRunId, run2);
  const exercises = await db.doc(`coachAnalytics/${uid}`).collection('exercises').get();
  assert.equal(exercises.size, 1); // analytics intact
});

// ── Report readiness gating (item F) ────────────────────────────────────────

test('emulator: one failing athlete does not block another; retry fills the gap', async () => {
  const coachUid = freshUid('coach');
  const okAthlete = freshUid('ok');
  const brokenAthlete = freshUid('broken');
  await seedWorkout(okAthlete, '2026-08-05', bench(100));

  // Broken athlete: analytics stuck in a FRESH running claim (a live run we
  // do not own) → generateReport must throw, not fabricate.
  await db.doc(`coachAnalytics/${brokenAthlete}`).set({
    enabledBy: { [coachUid]: true },
    bootstrapStatus: 'running',
    bootstrapRunId: 'someone-else',
    bootstrapAtMs: Date.now(),
  });

  await assert.rejects(
    () => generateReport(coachUid, brokenAthlete, '2026-08-10', 'Pacific/Auckland'),
    /analytics not ready/);

  // The healthy athlete generates fine in the same sweep.
  const created = await generateReport(coachUid, okAthlete, '2026-08-10', 'Pacific/Auckland');
  assert.equal(created, true);
  const okReport = await db.doc(`coachCheckIns/${coachUid}/reports/${okAthlete}_2026-08-10`).get();
  assert.equal(okReport.data().status, 'draft');

  // Recovery: the stuck run goes stale → retry self-heals and generates.
  await db.doc(`coachAnalytics/${brokenAthlete}`).update({
    bootstrapAtMs: Date.now() - enrollment.BOOTSTRAP_FRESH_MS - 1000,
  });
  const retried = await generateReport(coachUid, brokenAthlete, '2026-08-10', 'Pacific/Auckland');
  assert.equal(retried, true);
  // Idempotent: no duplicate on a further retry.
  const again = await generateReport(coachUid, brokenAthlete, '2026-08-10', 'Pacific/Auckland');
  assert.equal(again, false);
});

// ── Atomic copy / undo / skip (item I) ──────────────────────────────────────

async function seedDraftReport(coachUid, athleteUid, checkpointKey, extra = {}) {
  await db.doc(`coachCheckIns/${coachUid}/reports/${athleteUid}_${checkpointKey}`).set({
    athleteUid,
    checkpointKey,
    weekday: 'Mon',
    status: 'draft',
    variantSeed: 7,
    gender: 'male',
    firstName: 'Tom',
    prevCheckpointKey: '2026-08-06',
    maxStartKey: '2026-08-03',
    events: [{
      id: '2026-08-08_bench_rep6', type: 'repPB', dateKey: '2026-08-08',
      exerciseId: 'bench', exerciseName: 'Bench Press, Barbell', reps: 6,
      weightKg: 102.5, prevWeightKg: 100, pctImprovement: 0.025,
    }],
    completion: null,
    bodyweight: { goal: 'cut' },
    e1rmPraiseFloorKey: null,
    ...extra,
  });
}

const LIVE_BW = {
  currentAvg: 100.8, currentCount: 3, previousAvg: 101.8, previousCount: 4,
  trend: 'onTrack', lastWeighInKey: '2026-08-11', weighInStatus: 'ok',
};

test('emulator: concurrent Copy + Copy is idempotent — identical frozen text', async () => {
  const coachUid = freshUid('cpy');
  const athleteUid = freshUid('ath');
  await seedDraftReport(coachUid, athleteUid, '2026-08-10');

  const args = {
    coachUid, athleteUid, checkpointKey: '2026-08-10',
    todayKey: '2026-08-11', liveBodyweight: LIVE_BW,
  };
  const [a, b] = await Promise.all([
    copyTransaction(db, args),
    copyTransaction(db, args),
  ]);
  assert.equal(a.text, b.text);
  assert.ok(a.text.includes('new 6 rep target PB'));
  const report = (await db.doc(`coachCheckIns/${coachUid}/reports/${athleteUid}_2026-08-10`).get()).data();
  assert.equal(report.status, 'copied');
  assert.equal(report.finalText, a.text); // clipboard text == committed finalText
});

test('emulator: Copy vs Skip on the same report — exactly one wins', async () => {
  const coachUid = freshUid('cs');
  const athleteUid = freshUid('ath');
  await seedDraftReport(coachUid, athleteUid, '2026-08-10');

  const results = await Promise.allSettled([
    copyTransaction(db, {
      coachUid, athleteUid, checkpointKey: '2026-08-10',
      todayKey: '2026-08-11', liveBodyweight: LIVE_BW,
    }),
    skipTransaction(db, { coachUid, athleteUid, checkpointKey: '2026-08-10' }),
  ]);
  const report = (await db.doc(`coachCheckIns/${coachUid}/reports/${athleteUid}_2026-08-10`).get()).data();
  assert.ok(['copied', 'skipped'].includes(report.status));
  const fulfilled = results.filter((r) => r.status === 'fulfilled' && !(r.value && r.value.alreadyCopied));
  const rejected = results.filter((r) => r.status === 'rejected');
  // One transition committed; the other either failed the precondition or,
  // if it was the copy arriving second against 'copied', it cannot happen
  // here since the winner set a non-draft status.
  assert.equal(fulfilled.length + rejected.length, 2);
  assert.equal(rejected.length >= 1 || report.status === 'copied', true);
  if (report.status === 'skipped') {
    assert.equal(rejected.length, 1); // the copy must have failed
  }
});

test('emulator: an older draft cannot finalise after a newer checkpoint (concurrent)', async () => {
  const coachUid = freshUid('old');
  const athleteUid = freshUid('ath');
  await seedDraftReport(coachUid, athleteUid, '2026-08-10');
  await seedDraftReport(coachUid, athleteUid, '2026-08-13', {
    weekday: 'Thu', prevCheckpointKey: '2026-08-10', maxStartKey: '2026-08-06',
  });

  // Newer checkpoint finalised first.
  await copyTransaction(db, {
    coachUid, athleteUid, checkpointKey: '2026-08-13',
    todayKey: '2026-08-14', liveBodyweight: LIVE_BW,
  });
  // The older draft must now refuse to copy.
  await assert.rejects(
    () => copyTransaction(db, {
      coachUid, athleteUid, checkpointKey: '2026-08-10',
      todayKey: '2026-08-14', liveBodyweight: LIVE_BW,
    }),
    (err) => err instanceof TxnError && /newer check-in/.test(err.message));
});

test('emulator: Undo restores only bookkeeping created by that copy; blocked after newer finalise', async () => {
  const coachUid = freshUid('undo');
  const athleteUid = freshUid('ath');
  await seedDraftReport(coachUid, athleteUid, '2026-08-10', {
    completion: { weekKey: '2026-08-04', weekStart: '2026-08-04', weekEnd: '2026-08-11', completedAll: true, completedCount: 3, plannedCount: 3 },
  });
  await db.doc(`coachCheckIns/${coachUid}/athletes/${athleteUid}`).set({
    reportingEnabled: true, goal: 'cut', goalSetAt: 1000,
  });

  const copied = await copyTransaction(db, {
    coachUid, athleteUid, checkpointKey: '2026-08-10',
    todayKey: '2026-08-11', liveBodyweight: LIVE_BW,
  });
  assert.ok(copied.text);
  let settings = (await db.doc(`coachCheckIns/${coachUid}/athletes/${athleteUid}`).get()).data();
  assert.equal(settings.lastFinalizedCoverageEnd, '2026-08-10');
  assert.ok(settings.praisedWeeks && settings.praisedWeeks['2026-08-04']);

  await undoTransaction(db, {
    coachUid, athleteUid, checkpointKey: '2026-08-10', todayKey: '2026-08-11',
  });
  settings = (await db.doc(`coachCheckIns/${coachUid}/athletes/${athleteUid}`).get()).data();
  assert.equal(settings.lastFinalizedCoverageEnd, null);
  assert.ok(!settings.praisedWeeks || !settings.praisedWeeks['2026-08-04']);
  const report = (await db.doc(`coachCheckIns/${coachUid}/reports/${athleteUid}_2026-08-10`).get()).data();
  assert.equal(report.status, 'draft');

  // Re-copy, then finalise the newer checkpoint → undo becomes unsafe.
  await copyTransaction(db, {
    coachUid, athleteUid, checkpointKey: '2026-08-10',
    todayKey: '2026-08-11', liveBodyweight: LIVE_BW,
  });
  await seedDraftReport(coachUid, athleteUid, '2026-08-13', {
    weekday: 'Thu', prevCheckpointKey: '2026-08-10', maxStartKey: '2026-08-06',
  });
  await copyTransaction(db, {
    coachUid, athleteUid, checkpointKey: '2026-08-13',
    todayKey: '2026-08-14', liveBodyweight: LIVE_BW,
  });
  await assert.rejects(
    () => undoTransaction(db, {
      coachUid, athleteUid, checkpointKey: '2026-08-10', todayKey: '2026-08-14',
    }),
    (err) => err instanceof TxnError && /no longer safe/.test(err.message));
});
