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

const {
  firestoreStore, claimBootstrap, runBootstrap, generateReport, VERSIONS,
} = coach._internals;
const db = admin.firestore();

assert.ok(process.env.FIRESTORE_EMULATOR_HOST,
  'integration.spec.js must run under firebase emulators:exec');

// VERSIONS comes from the production module rather than being restated here,
// so an analyticsVersion bump (the re-bootstrap mechanism) can never leave
// this suite asserting against a stale generation.
assert.equal(VERSIONS.formulaVersion, E1RM_FORMULA_VERSION);

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
  assert.ok(a.text.startsWith('• 102.5kg for 6 reps on the bench press'));
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
  // The draft carries no completion message any more, so no week is consumed.
  assert.ok(!settings.praisedWeeks || !settings.praisedWeeks['2026-08-04']);
  assert.doesNotMatch(copied.text, /workouts in/);

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

test('emulator: Undo still removes a praisedWeeks entry an OLDER copy recorded', async () => {
  const coachUid = freshUid('undoLegacy');
  const athleteUid = freshUid('ath');
  await seedDraftReport(coachUid, athleteUid, '2026-08-10', {
    status: 'copied', finalText: 'legacy text', coverageStart: '2026-08-03', coverageEnd: '2026-08-10',
    praisedWeekKey: '2026-08-03', milestoneAwarded: null, prevLastFinalizedCoverageEnd: null,
  });
  await db.doc(`coachCheckIns/${coachUid}/athletes/${athleteUid}`).set({
    reportingEnabled: true, lastFinalizedCoverageEnd: '2026-08-10',
    praisedWeeks: { '2026-08-03': `${athleteUid}_2026-08-10`, '2026-07-27': 'otherReport' },
  });
  await undoTransaction(db, { coachUid, athleteUid, checkpointKey: '2026-08-10', todayKey: '2026-08-11' });
  const settings = (await db.doc(`coachCheckIns/${coachUid}/athletes/${athleteUid}`).get()).data();
  assert.deepEqual(settings.praisedWeeks, { '2026-07-27': 'otherReport' });
});

// ── Recap: attendance week, weigh-in detail, drafts, refresh (production path) ─

const TZ = 'Pacific/Auckland';
// Before NZ DST (27 Sep 2026) Auckland is UTC+12.
const nzMidnight = (key) => admin.firestore.Timestamp.fromMillis(Date.parse(`${key}T00:00:00Z`) - 12 * 3600e3);
const nzNoon = (key) => admin.firestore.Timestamp.fromMillis(Date.parse(`${key}T00:00:00Z`));

const done = (id, name, weight, reps) => ({ exerciseId: id, name, sets: [{ weight, reps }] });

async function seedBlock(uid, blockId, { name, start, end, active, templates = 0 }) {
  await db.doc(`users/${uid}/planned_blocks/${blockId}`).set({
    name, startDate: nzMidnight(start), endDate: nzMidnight(end), isActive: active,
  });
  for (let i = 0; i < templates; i++) {
    await db.doc(`users/${uid}/templates/${blockId}_t${i}`).set({ name: `T${i}`, blockId });
  }
}

async function seedScreenshotWeek(uid) {
  // Tue 8: completed on a day the planner says "No exercises planned".
  await seedWorkout(uid, '2026-09-08', { exercises: [done('sq', 'Back Squat, Barbell', 120, 5)], wesPlannedExercises: [] });
  // Thu 10: two sessions merged into the one date document.
  await seedWorkout(uid, '2026-09-10', {
    exercises: [done('bb', 'Bench Press, Barbell', 100, 5), done('lp', 'Bench Press, Larsen Press', 80, 4),
      done('bb', 'Bench Press, Barbell', 90, 8)],
  });
  // Fri 11: planned-only placeholder; Sat 12: opened but nothing logged.
  await seedWorkout(uid, '2026-09-11', { wesPlannedExercises: [{ exerciseId: 'dl' }], exercises: [] });
  await seedWorkout(uid, '2026-09-12', { exercises: [{ exerciseId: 'dl', name: 'Deadlift, Conventional', sets: [{ weight: 0, reps: 0 }] }] });
  // Sun 13: legacy set fields.
  await seedWorkout(uid, '2026-09-13', { exercises: [{ id: 'rc', name: 'Seated Row, Cable', sets: [{ actualWeight: 60, actualReps: 10 }] }] });
  // Mon 14 (the checkpoint day) belongs to the NEXT report.
  await seedWorkout(uid, '2026-09-14', { exercises: [done('sq', 'Back Squat, Barbell', 125, 5)] });
}

test('emulator: Monday 14 Sep report shows 7–13 Sep with the real completed days and target', async () => {
  const coachUid = freshUid('recapMon');
  const uid = freshUid('ath');
  await seedScreenshotWeek(uid);
  await seedBlock(uid, 'blk', { name: 'Prep', start: '2026-08-31', end: '2026-10-25', active: true, templates: 4 });
  await db.collection(`users/${uid}/weights`).add({ weight: 73.2, unit: 'kg', tod: 'am', timestamp: nzNoon('2026-09-10') });

  assert.equal(await generateReport(coachUid, uid, '2026-09-14', TZ), true);
  const r = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`).get()).data();
  const w = r.currentWeekAdherence;
  assert.equal(w.period, 'previousWeek');
  assert.equal(w.weekStart, '2026-09-07');
  assert.equal(w.weekEnd, '2026-09-14');
  assert.deepEqual(w.days.map((d) => `${d.weekday}:${d.trained ? d.exerciseCount : '-'}`),
    ['Mon:-', 'Tue:1', 'Wed:-', 'Thu:2', 'Fri:-', 'Sat:-', 'Sun:1']);
  assert.equal(w.completedCount, 3, 'three distinct days; the merged Thursday counts once');
  assert.equal(w.plannedCount, 4);
  assert.equal(w.plannedKnown, true);
  assert.equal(r.compositionVersion, 2);
  assert.deepEqual(r.bodyweight.lastWeighIn,
    { dateKey: '2026-09-10', weight: 73.2, unit: 'kg', tod: 'am', entryId: r.bodyweight.lastWeighIn.entryId });
  assert.equal(r.bodyweight.lastWeighInKey, '2026-09-10');
  for (const text of [r.draftIfPrevCopied, r.draftIfPrevNotCopied]) {
    assert.doesNotMatch(text, /\b(Hey|Hi|Heya|bro|man)\b|💪|👍/);
  }
});

test('emulator: Thursday report counts through its cutoff; a four-day week reads 4/4', async () => {
  const coachUid = freshUid('recapThu');
  const uid = freshUid('ath');
  for (const k of ['2026-09-14', '2026-09-15', '2026-09-16', '2026-09-17']) {
    await seedWorkout(uid, k, { exercises: [done('sq', 'Back Squat, Barbell', 100, 5)] });
  }
  for (const k of ['2026-09-07', '2026-09-08', '2026-09-10', '2026-09-13']) {
    await seedWorkout(uid, k, { exercises: [done('sq', 'Back Squat, Barbell', 100, 5)] });
  }
  await seedBlock(uid, 'blk', { name: 'Prep', start: '2026-08-31', end: '2026-10-25', active: true, templates: 4 });

  await generateReport(coachUid, uid, '2026-09-17', TZ);
  const thu = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-17`).get()).data().currentWeekAdherence;
  assert.equal(thu.period, 'currentWeek');
  assert.equal(thu.weekStart, '2026-09-14');
  assert.equal(thu.cutoffKey, '2026-09-17');
  assert.deepEqual(thu.days.map((d) => d.counted), [true, true, true, false, false, false, false]);
  assert.equal(thu.days[3].trained, false, 'the checkpoint day is not yet counted');
  assert.equal(thu.completedCount, 3);

  await generateReport(coachUid, uid, '2026-09-14', TZ);
  const mon = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`).get()).data().currentWeekAdherence;
  assert.equal(mon.completedCount, 4);
  assert.equal(mon.plannedCount, 4);
});

test('emulator: a block changed on Monday never lends last week its target', async () => {
  const coachUid = freshUid('recapBlk');
  const uid = freshUid('ath');
  await seedWorkout(uid, '2026-09-08', { exercises: [done('sq', 'Back Squat, Barbell', 100, 5)] });
  await seedBlock(uid, 'old', { name: 'Old', start: '2026-08-10', end: '2026-09-13', active: false, templates: 3 });
  await seedBlock(uid, 'new', { name: 'New', start: '2026-09-14', end: '2026-11-08', active: true, templates: 5 });

  await generateReport(coachUid, uid, '2026-09-14', TZ);
  const w = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`).get()).data().currentWeekAdherence;
  assert.equal(w.plannedCount, 3);
  assert.equal(w.plannedSource, 'weekBlockTemplates');
  assert.equal(w.blockId, 'old');

  // Templates moved to the new block: the old week's target is honestly unknown.
  const uid2 = freshUid('ath');
  await seedWorkout(uid2, '2026-09-08', { exercises: [done('sq', 'Back Squat, Barbell', 100, 5)] });
  await seedBlock(uid2, 'old', { name: 'Old', start: '2026-08-10', end: '2026-09-13', active: false, templates: 0 });
  await seedBlock(uid2, 'new', { name: 'New', start: '2026-09-14', end: '2026-11-08', active: true, templates: 5 });
  await generateReport(coachUid, uid2, '2026-09-14', TZ);
  const w2 = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid2}_2026-09-14`).get()).data().currentWeekAdherence;
  assert.equal(w2.plannedCount, null);
  assert.equal(w2.plannedKnown, false);
  assert.equal(w2.completedCount, 1);
});

test('emulator: preview and copied text come from the same composition', async () => {
  const coachUid = freshUid('recapCopy');
  const uid = freshUid('ath');
  await seedWorkout(uid, '2026-08-31', { exercises: [done('bb', 'Bench Press, Barbell', 140, 8), done('lp', 'Bench Press, Larsen Press', 115, 4)] });
  await seedWorkout(uid, '2026-09-10', { exercises: [done('bb', 'Bench Press, Barbell', 150, 8), done('lp', 'Bench Press, Larsen Press', 125, 4)] });
  await generateReport(coachUid, uid, '2026-09-14', TZ);
  const ref = db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`);
  const report = (await ref.get()).data();
  assert.match(report.draftIfPrevNotCopied, /150kg for 8 reps on the bench press/);
  assert.match(report.draftIfPrevNotCopied, /125kg for 4 reps on the Larsen bench press/);

  const b = report.bodyweight;
  const copied = await copyTransaction(db, {
    coachUid, athleteUid: uid, checkpointKey: '2026-09-14', todayKey: '2026-09-15',
    liveBodyweight: {
      currentAvg: b.currentAvg, currentCount: b.currentCount, previousAvg: b.previousAvg,
      previousCount: b.previousCount, trend: b.trend, lastWeighInKey: b.lastWeighInKey,
      weighInStatus: b.weighInStatus,
    },
  });
  // The previous checkpoint was not copied and nothing clamps: identical text.
  assert.equal(copied.text, report.draftIfPrevNotCopied);
  assert.equal((await ref.get()).data().finalText, copied.text);
  // Copy again returns the frozen text.
  const again = await copyTransaction(db, {
    coachUid, athleteUid: uid, checkpointKey: '2026-09-14', todayKey: '2026-09-15', liveBodyweight: LIVE_BW,
  });
  assert.equal(again.alreadyCopied, true);
  assert.equal(again.text, copied.text);
});

async function seedLegacyV1Draft(coachUid, athleteUid, extra = {}) {
  await seedDraftReport(coachUid, athleteUid, '2026-09-14', {
    prevCheckpointKey: '2026-09-10',
    maxStartKey: '2026-09-07',
    events: [{
      id: '2026-09-10_lp_rep4', type: 'repPB', dateKey: '2026-09-10', exerciseId: 'lp',
      exerciseName: 'Bench Press, Larsen Press', reps: 4, weightKg: 125, prevWeightKg: 120, pctImprovement: 0.04,
    }],
    bodyweight: { goal: 'cut', trend: 'insufficient', weighInStatus: 'overdue', newMilestoneId: null },
    draftIfPrevCopied: 'Hey bro, nice work hitting 125kg for 4 on the Bench Press 💪',
    draftIfPrevNotCopied: 'Hey bro, nice work hitting 125kg for 4 on the Bench Press 💪',
    currentWeekAdherence: {
      weekStart: '2026-09-14', weekEnd: '2026-09-21', completedCount: 0, plannedCount: 4, plannedKnown: true,
      days: [],
    },
    ...extra,
  });
}

test('emulator: an existing v1 draft is refreshed in place — wording and attendance, nothing else', async () => {
  const coachUid = freshUid('refresh');
  const uid = freshUid('ath');
  await seedScreenshotWeek(uid);
  await seedBlock(uid, 'blk', { name: 'Prep', start: '2026-08-31', end: '2026-10-25', active: true, templates: 4 });
  await seedLegacyV1Draft(coachUid, uid);
  await db.doc(`coachCheckIns/${coachUid}/athletes/${uid}`).set({
    reportingEnabled: true, goal: 'cut', lastFinalizedCoverageEnd: '2026-09-07', coachingService: 'fullOnline',
  });
  const ref = db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`);
  const before = (await ref.get()).data();
  const settingsBefore = (await db.doc(`coachCheckIns/${coachUid}/athletes/${uid}`).get()).data();

  assert.equal(await coach._internals.refreshDraftReport(coachUid, uid, '2026-09-14', TZ), 'refreshed');
  const after = (await ref.get()).data();
  const expected = '• 125kg for 4 reps on the Larsen bench press\n\nCan I get you to weigh in please?';
  assert.equal(after.draftIfPrevNotCopied, expected);
  assert.equal(after.draftIfPrevCopied, expected);
  assert.equal(after.compositionVersion, 2);
  assert.equal(after.currentWeekAdherence.weekStart, '2026-09-07');
  assert.equal(after.currentWeekAdherence.completedCount, 3);
  // Untouched: status, events, frozen fields, identity, bodyweight snapshot, settings.
  for (const k of ['status', 'events', 'bodyweight', 'variantSeed', 'prevCheckpointKey', 'maxStartKey']) {
    assert.deepEqual(after[k], before[k], k);
  }
  assert.deepEqual((await db.doc(`coachCheckIns/${coachUid}/athletes/${uid}`).get()).data(), settingsBefore);

  // Idempotent and bounded: a second refresh does nothing.
  assert.equal(await coach._internals.refreshDraftReport(coachUid, uid, '2026-09-14', TZ), 'current');
  assert.equal(await coach._internals.refreshDraftReport(coachUid, uid, '2026-09-17', TZ), 'missing');
});

test('emulator: refresh never rewrites copied or skipped history', async () => {
  const coachUid = freshUid('refreshFinal');
  const uid = freshUid('ath');
  await seedLegacyV1Draft(coachUid, uid, {
    status: 'copied', finalText: 'Hey bro, frozen', coverageStart: '2026-09-07', coverageEnd: '2026-09-14',
  });
  const ref = db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`);
  const before = (await ref.get()).data();
  assert.equal(await coach._internals.refreshDraftReport(coachUid, uid, '2026-09-14', TZ), 'finalized');
  assert.deepEqual((await ref.get()).data(), before);
});

test('emulator: refresh racing Copy or Skip never overwrites the finalised result', async () => {
  for (let round = 0; round < 3; round++) {
    const coachUid = freshUid('race');
    const uid = freshUid('ath');
    await seedScreenshotWeek(uid);
    await seedLegacyV1Draft(coachUid, uid);
    const [, copied] = await Promise.all([
      coach._internals.refreshDraftReport(coachUid, uid, '2026-09-14', TZ),
      copyTransaction(db, {
        coachUid, athleteUid: uid, checkpointKey: '2026-09-14', todayKey: '2026-09-15', liveBodyweight: LIVE_BW,
      }),
    ]);
    const r = (await db.doc(`coachCheckIns/${coachUid}/reports/${uid}_2026-09-14`).get()).data();
    assert.equal(r.status, 'copied');
    assert.equal(r.finalText, copied.text);
    assert.match(copied.text, /Larsen bench press/);
    const s = (await db.doc(`coachCheckIns/${coachUid}/athletes/${uid}`).get()).data();
    assert.equal(s.lastFinalizedCoverageEnd, '2026-09-14');

    const coach2 = freshUid('raceSkip');
    await seedLegacyV1Draft(coach2, uid);
    const results = await Promise.allSettled([
      coach._internals.refreshDraftReport(coach2, uid, '2026-09-14', TZ),
      skipTransaction(db, { coachUid: coach2, athleteUid: uid, checkpointKey: '2026-09-14' }),
    ]);
    assert.equal(results[1].status, 'fulfilled');
    const skipped = (await db.doc(`coachCheckIns/${coach2}/reports/${uid}_2026-09-14`).get()).data();
    assert.equal(skipped.status, 'skipped');
  }
});

test('emulator: latest weigh-in follows adds, edits and deletes; none is null', async () => {
  const uid = freshUid('weigh');
  const { latestWeighIn } = coach._internals;
  assert.equal(await latestWeighIn(uid, TZ), null);

  const col = db.collection(`users/${uid}/weights`);
  const old = await col.add({ weight: 81.25, unit: 'kg', tod: 'am', timestamp: nzNoon('2026-06-02') });
  assert.deepEqual(await latestWeighIn(uid, TZ),
    { dateKey: '2026-06-02', weight: 81.25, unit: 'kg', tod: 'am', entryId: old.id });

  const recent = await col.add({ weight: 73.2, unit: 'kg', tod: 'am', timestamp: nzNoon('2026-09-10') });
  assert.equal((await latestWeighIn(uid, TZ)).weight, 73.2);

  await recent.update({ weight: 72.9, timestamp: nzNoon('2026-09-11') });
  assert.deepEqual(await latestWeighIn(uid, TZ),
    { dateKey: '2026-09-11', weight: 72.9, unit: 'kg', tod: 'am', entryId: recent.id });

  await recent.delete();
  assert.equal((await latestWeighIn(uid, TZ)).dateKey, '2026-06-02');

  // Same-day AM and PM share the noon stamp: the tracker's document order wins.
  await db.doc(`users/${uid}/weights/aaaa`).set({ weight: 70.1, tod: 'am', timestamp: nzNoon('2026-09-12') });
  await db.doc(`users/${uid}/weights/zzzz`).set({ weight: 70.8, tod: 'pm', timestamp: nzNoon('2026-09-12') });
  const tracker = await db.collection(`users/${uid}/weights`).orderBy('timestamp', 'desc').limit(1).get();
  const latest = await latestWeighIn(uid, TZ);
  assert.equal(latest.entryId, tracker.docs[0].id);
  assert.equal(latest.weight, tracker.docs[0].data().weight);
});

test('emulator: review context pairs status with the latest entry and refreshes the draft first', async () => {
  const coachUid = freshUid('ctx');
  const uid = freshUid('ath');
  await seedScreenshotWeek(uid);
  await seedLegacyV1Draft(coachUid, uid);
  await db.collection(`users/${uid}/weights`).add({ weight: 73.2, unit: 'kg', tod: 'am', timestamp: nzNoon('2026-09-10') });

  const info = await coach._internals.reviewContextForAthlete(coachUid, uid, TZ, '2026-09-15', '2026-09-14');
  assert.equal(info.lastWeighInKey, '2026-09-10');
  assert.equal(info.lastWeighIn.weight, 73.2);
  assert.equal(info.weighInStatus, 'overdue');
  assert.equal(info.draftRefresh, 'refreshed');

  const none = await coach._internals.reviewContextForAthlete(coachUid, freshUid('nobody'), TZ, '2026-09-15', '2026-09-14');
  assert.equal(none.lastWeighIn, null);
  assert.equal(none.lastWeighInKey, null);
  assert.equal(none.weighInError, undefined);
  assert.equal(none.draftRefresh, 'missing');
});
