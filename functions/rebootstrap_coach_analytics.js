/**
 * Versioned, idempotent re-bootstrap of coach PB analytics.
 *
 * Usage (from /functions, needs serviceAccountKey.json like the other admin
 * scripts, or ADC for the project):
 *   node rebootstrap_coach_analytics.js                 # dry-run, all enrolled
 *   node rebootstrap_coach_analytics.js --apply         # rebuild all enrolled
 *   node rebootstrap_coach_analytics.js <uid> --apply   # rebuild one athlete
 *
 * WHY THIS EXISTS
 * ---------------
 * Bumping ANALYTICS_VERSION already makes the deployed backend self-heal: the
 * readiness gate in generateReport() sees a stale generation and claims a
 * bootstrap before producing the next checkpoint's reports. That is the normal
 * path and needs no operator action.
 *
 * This script performs the SAME rebuild on demand, for when you do not want to
 * wait for the next Monday/Thursday checkpoint — e.g. to retract incorrect PB
 * events from the coach dashboard immediately after shipping an engine fix.
 *
 * It mirrors functions/coach/index.js runBootstrap() step for step and reuses
 * the identical pure engine (analytics_store.bulkRebuild), so it cannot drift
 * from what the backend would have produced on its own:
 *   1. claim   – bootstrapStatus='running' with a fresh bootstrapRunId
 *   2. scan    – every users/{uid}/workouts/{YYYY-MM-DD} doc, ascending
 *   3. rebuild – delete exerciseDays/exercises/events, then bulkRebuild
 *   4. stamp   – bootstrapStatus='complete' + analyticsVersion + formula
 *
 * SAFETY
 * ------
 *   - Workout documents are READ-ONLY input. Nothing under users/** is written.
 *   - Nothing under coachCheckIns/** is touched: no report, no draft, no
 *     finalised or copied message, no reportingEnabled toggle, no praise
 *     bookkeeping (praisedWeeks / praisedMilestones).
 *   - Every write is asserted to live under coachAnalytics/{uid}/ before it is
 *     sent; anything else aborts the run.
 *   - Idempotent: rerunning converges on identical documents, because event
 *     ids and content are deterministic functions of the workout history.
 *   - Only athletes with reportingEnabled === true are considered.
 */

'use strict';

const crypto = require('crypto');
const admin = require('firebase-admin');

const { bulkRebuild } = require('./coach/analytics_store');
const { E1RM_FORMULA_VERSION } = require('./coach/e1rm');

// Keep in step with ANALYTICS_VERSION in functions/coach/index.js.
const ANALYTICS_VERSION = 4;
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

const args = process.argv.slice(2);
const APPLY = args.includes('--apply');
const ONLY_UID = args.find((a) => !a.startsWith('--')) || null;

try {
  // eslint-disable-next-line global-require, import/no-unresolved
  const serviceAccount = require('./serviceAccountKey.json');
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
} catch (_) {
  admin.initializeApp(); // fall back to ADC
}
const db = admin.firestore();

/** Store adapter that buffers a wholesale replacement for one athlete. */
function bufferStore(athleteUid, writes) {
  const base = `coachAnalytics/${athleteUid}`;
  const dayDocId = (exerciseId, dateKey) => `${exerciseId}_${dateKey}`;
  const store = {
    // A wholesale rebuild always starts from an empty history.
    async getSummary() { return null; },
    async getDay() { return null; },
    async listDaysForExercise() { return []; },
    async listExerciseIdsForDate() { return []; },
    async listEventIdsForExercise() { return []; },
    async setDay(exerciseId, dateKey, day) {
      writes.push({ path: `${base}/exerciseDays/${dayDocId(exerciseId, dateKey)}`,
        data: { exerciseId, dateKey, day } });
    },
    async deleteDay(exerciseId, dateKey) {
      writes.push({ path: `${base}/exerciseDays/${dayDocId(exerciseId, dateKey)}`, delete: true });
    },
    async setSummary(exerciseId, data) {
      writes.push({ path: `${base}/exercises/${exerciseId}`, data });
    },
    async deleteSummary(exerciseId) {
      writes.push({ path: `${base}/exercises/${exerciseId}`, delete: true });
    },
    async setEvent(ev) { writes.push({ path: `${base}/events/${ev.id}`, data: ev }); },
    async deleteEvent(id) { writes.push({ path: `${base}/events/${id}`, delete: true }); },
    async withExerciseLock(exerciseId, fn) { await fn(store); },
    async flush() {},
  };
  return store;
}

async function idsIn(collectionPath) {
  const snap = await db.collection(collectionPath).select().get();
  return snap.docs.map((d) => d.id);
}

async function commitAll(ops) {
  const CHUNK = 400;
  for (let i = 0; i < ops.length; i += CHUNK) {
    const batch = db.batch();
    for (const op of ops.slice(i, i + CHUNK)) {
      const ref = db.doc(op.path);
      if (op.delete) batch.delete(ref);
      else batch.set(ref, op.data);
    }
    // eslint-disable-next-line no-await-in-loop
    await batch.commit();
  }
  return ops.length;
}

async function rebootstrapAthlete(athleteUid) {
  console.log(`\n${'='.repeat(70)}\n${athleteUid}\n${'='.repeat(70)}`);

  const stateRef = db.collection('coachAnalytics').doc(athleteUid);
  const stateSnap = await stateRef.get();
  if (!stateSnap.exists) { console.log('  no analytics state — skipping'); return; }
  const state = stateSnap.data() || {};
  const enabledBy = state.enabledBy || {};
  console.log(`  before: analyticsVersion=${state.analyticsVersion}`
    + ` status=${state.bootstrapStatus} enabledBy=${Object.keys(enabledBy).join(',') || '(none)'}`);
  if (Object.keys(enabledBy).length === 0) {
    console.log('  reporting not enabled by any coach — skipping');
    return;
  }

  // 1) Chronological scan of the RAW workout documents (read-only).
  const workouts = await db.collection('users').doc(athleteUid).collection('workouts').get();
  const entries = workouts.docs
    .filter((d) => DATE_KEY_RE.test(d.id))
    .sort((a, b) => (a.id < b.id ? -1 : 1))
    .map((d) => [d.id, d.data()]);
  console.log(`  workouts: ${workouts.size} total, ${entries.length} dated`);

  const [oldDays, oldEx, oldEv] = await Promise.all([
    idsIn(`coachAnalytics/${athleteUid}/exerciseDays`),
    idsIn(`coachAnalytics/${athleteUid}/exercises`),
    idsIn(`coachAnalytics/${athleteUid}/events`),
  ]);
  console.log(`  existing: ${oldDays.length} days, ${oldEx.length} streams, ${oldEv.length} events`);

  // 2) Build the replacement in memory.
  const writes = [];
  const streams = await bulkRebuild(bufferStore(athleteUid, writes), entries);

  const kept = new Set(writes.map((w) => w.path));
  const deletes = [];
  const sweep = (ids, sub) => {
    for (const id of ids) {
      const p = `coachAnalytics/${athleteUid}/${sub}/${id}`;
      if (!kept.has(p)) deletes.push({ path: p, delete: true });
    }
  };
  sweep(oldDays, 'exerciseDays');
  sweep(oldEx, 'exercises');
  sweep(oldEv, 'events');

  const newEvents = writes.filter((w) => w.path.includes('/events/')).length;
  const staleEvents = deletes.filter((w) => w.path.includes('/events/')).length;
  console.log(`  rebuild: ${streams} streams, ${newEvents} events`);
  console.log(`  obsolete to delete: ${deletes.length} (${staleEvents} events)`);

  // Hard safety rail: never write outside this athlete's analytics subtree.
  const stray = [...writes, ...deletes]
    .map((w) => w.path)
    .filter((p) => !p.startsWith(`coachAnalytics/${athleteUid}/`));
  if (stray.length) throw new Error(`aborting: writes outside subtree: ${stray.slice(0, 3)}`);

  if (!APPLY) { console.log('  DRY RUN — nothing written (pass --apply)'); return; }

  // 3) Claim → replace → stamp complete, mirroring runBootstrap's ordering.
  const runId = `${Date.now()}_${crypto.randomBytes(6).toString('hex')}`;
  await stateRef.set({
    bootstrapStatus: 'running',
    bootstrapRunId: runId,
    bootstrapAtMs: Date.now(),
    dirtyDates: [],
  }, { merge: true });

  await commitAll(deletes);
  await commitAll(writes);

  await stateRef.set({
    bootstrapStatus: 'complete',
    analyticsVersion: ANALYTICS_VERSION,
    e1rmFormulaVersion: E1RM_FORMULA_VERSION,
    dirtyDates: [],
  }, { merge: true });
  console.log(`  DONE runId=${runId} analyticsVersion=${ANALYTICS_VERSION}`);
}

(async () => {
  console.log(APPLY ? '*** APPLY MODE ***' : '*** DRY RUN (pass --apply to write) ***');
  if (ONLY_UID) { await rebootstrapAthlete(ONLY_UID); console.log('\ndone.'); return; }

  const targets = new Set();
  const coaches = await db.collection('coachCheckIns').get();
  for (const c of coaches.docs) {
    // eslint-disable-next-line no-await-in-loop
    const athletes = await c.ref.collection('athletes').where('reportingEnabled', '==', true).get();
    athletes.docs.forEach((a) => targets.add(a.id));
  }
  console.log(`reporting-enabled athletes: ${targets.size}`);
  for (const uid of targets) await rebootstrapAthlete(uid);
  console.log('\ndone.');
})().catch((e) => { console.error('FAILED:', e); process.exit(1); });
