// Coach bi-weekly check-ins — Firebase-bound layer.
//
// Pure business logic lives in the sibling modules (e1rm, pb_engine,
// coverage, bodyweight, praise, message, draft, enrollment, authz,
// analytics_store, checkin_txns); this file wires it to Firestore, triggers,
// the scheduler and callables. Style follows the existing functions/index.js:
// CommonJS + firebase-functions v2 APIs.
//
// See docs/coach_checkins/COACH_CHECKINS.md for the full schema and design.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');
const crypto = require('crypto');

const { E1RM_FORMULA_VERSION } = require('./e1rm');
const cov = require('./coverage');
const bwx = require('./bodyweight');
const { buildDraftText } = require('./draft');
const enrollment = require('./enrollment');
const authz = require('./authz');
const {
  dayDocId, applyWorkoutDay, bulkRebuild,
} = require('./analytics_store');
const {
  TxnError, copyTransaction, undoTransaction, skipTransaction,
} = require('./checkin_txns');

try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

const ANALYTICS_VERSION = 2; // v2: bounded exerciseDays storage shape
const VERSIONS = { formulaVersion: E1RM_FORMULA_VERSION, analyticsVersion: ANALYTICS_VERSION };
const DEFAULT_TZ = 'Pacific/Auckland';
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

// ── Small helpers ───────────────────────────────────────────────────────────

const analyticsRef = (uid) => db.collection('coachAnalytics').doc(uid);
const coachRef = (coachUid) => db.collection('coachCheckIns').doc(coachUid);
const athleteSettingsRef = (coachUid, athleteUid) =>
  coachRef(coachUid).collection('athletes').doc(athleteUid);
const reportRef = (coachUid, athleteUid, checkpointKey) =>
  coachRef(coachUid).collection('reports').doc(`${athleteUid}_${checkpointKey}`);

const isCoachFor = (coachUid, athleteUid) => authz.isCoachFor(db, coachUid, athleteUid);

function safeTz(tz) {
  return cov.safeTimezone(tz) || DEFAULT_TZ;
}

function todayKeyIn(tz) {
  return cov.localDateKey(new Date(), safeTz(tz));
}

async function coachTimezone(coachUid) {
  const snap = await coachRef(coachUid).get();
  return safeTz(snap.exists ? snap.data().timezone : null);
}

/** Resolve gender/first-name from users/{uid} (never inferred from a name). */
async function resolveAthleteIdentity(athleteUid) {
  const snap = await db.collection('users').doc(athleteUid).get();
  const data = snap.exists ? snap.data() : {};
  let gender = null;
  const sex = typeof data.sex === 'string' ? data.sex.toUpperCase() : null;
  if (sex === 'M') gender = 'male';
  else if (sex === 'F') gender = 'female';
  if (!gender) {
    const pg = data.profile && typeof data.profile.gender === 'string'
      ? data.profile.gender.toLowerCase() : null;
    if (pg === 'male' || pg === 'female') gender = pg;
  }
  const nameSource = firstNonEmpty([data.fullName, data.displayName, data.username]);
  const firstName = nameSource ? String(nameSource).trim().split(/\s+/)[0] : null;
  return { gender, firstName, displayName: nameSource || athleteUid };
}

function firstNonEmpty(values) {
  for (const v of values) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return null;
}

/** Weigh-in entries from users/{uid}/weights since a cutoff dateKey, with
 *  explicit chronological ordering so same-day/same-TOD duplicates resolve
 *  deterministically to the latest timestamp (matches BodyWeightTracker).
 *  Weigh-ins are stamped at device-local noon; the coach timezone recovers
 *  the intended calendar day. */
async function loadWeightEntries(athleteUid, sinceKey, tz) {
  const [y, m, d] = sinceKey.split('-').map(Number);
  const cutoff = admin.firestore.Timestamp.fromDate(new Date(Date.UTC(y, m - 1, d - 1)));
  const snap = await db.collection('users').doc(athleteUid)
    .collection('weights')
    .where('timestamp', '>=', cutoff)
    .orderBy('timestamp', 'asc')
    .get();
  const entries = [];
  for (const doc of snap.docs) {
    const w = doc.data();
    const ts = w.timestamp;
    if (!ts || typeof ts.toDate !== 'function') continue;
    const weight = Number(w.weight);
    if (!Number.isFinite(weight) || weight <= 0) continue;
    entries.push({
      dateKey: cov.localDateKey(ts.toDate(), safeTz(tz)),
      weightKg: weight,
      tod: (typeof w.tod === 'string' && w.tod.toLowerCase() === 'pm') ? 'pm' : 'am',
      tsMillis: ts.toMillis(),
    });
  }
  return entries;
}

/** Latest weigh-in dateKey (any age). One indexed read. */
async function latestWeighInKey(athleteUid, tz) {
  const snap = await db.collection('users').doc(athleteUid)
    .collection('weights')
    .orderBy('timestamp', 'desc')
    .limit(1)
    .get();
  if (snap.empty) return null;
  const ts = snap.docs[0].data().timestamp;
  if (!ts || typeof ts.toDate !== 'function') return null;
  return cov.localDateKey(ts.toDate(), safeTz(tz));
}

/** Live bodyweight numbers as of coach-local today (goal/milestone are
 *  attached later — milestone needs transactional praise state). */
async function liveBodyweightBase(athleteUid, tz, goal) {
  const todayKey = todayKeyIn(tz);
  const entries = await loadWeightEntries(athleteUid, cov.addDaysKey(todayKey, -21), tz);
  const rolling = bwx.rollingComparison(entries, todayKey);
  const lastWeighKey = await latestWeighInKey(athleteUid, tz);
  return {
    currentAvg: rolling.currentAvg,
    currentCount: rolling.currentCount,
    previousAvg: rolling.previousAvg,
    previousCount: rolling.previousCount,
    trend: bwx.classifyTrend(goal, rolling.currentAvg, rolling.previousAvg),
    lastWeighInKey: lastWeighKey,
    weighInStatus: bwx.weighInStatus(lastWeighKey, todayKey),
  };
}

// ── Firestore adapter for the analytics store interface ─────────────────────

/** Transaction-bound store: reads via tx.get (docs and queries), writes via
 *  tx.set/tx.delete. reconcileExercise performs all reads before writes,
 *  satisfying the transaction contract. */
function txStore(tx, base) {
  return {
    async getSummary(exerciseId) {
      const s = await tx.get(base.collection('exercises').doc(exerciseId));
      return s.exists ? s.data() : null;
    },
    async getDay(exerciseId, dateKey) {
      const s = await tx.get(base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey)));
      return s.exists ? s.data().day : null;
    },
    async listDaysForExercise(exerciseId) {
      const s = await tx.get(base.collection('exerciseDays').where('exerciseId', '==', exerciseId));
      return s.docs.map((d) => ({ dateKey: d.data().dateKey, day: d.data().day }));
    },
    async listExerciseIdsForDate(dateKey) {
      const s = await tx.get(base.collection('exerciseDays').where('dateKey', '==', dateKey));
      return [...new Set(s.docs.map((d) => d.data().exerciseId))];
    },
    async listEventIdsForExercise(exerciseId) {
      const s = await tx.get(base.collection('events').where('exerciseId', '==', exerciseId));
      return s.docs.map((d) => d.id);
    },
    async setDay(exerciseId, dateKey, day) {
      tx.set(base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey)),
        { exerciseId, dateKey, day });
    },
    async deleteDay(exerciseId, dateKey) {
      tx.delete(base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey)));
    },
    async setSummary(exerciseId, data) {
      tx.set(base.collection('exercises').doc(exerciseId), {
        ...data,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    },
    async deleteSummary(exerciseId) {
      tx.delete(base.collection('exercises').doc(exerciseId));
    },
    async setEvent(ev) {
      tx.set(base.collection('events').doc(ev.id), ev);
    },
    async deleteEvent(eventId) {
      tx.delete(base.collection('events').doc(eventId));
    },
    async withExerciseLock() {
      throw new Error('nested exercise locks are not supported');
    },
    async flush() {},
  };
}

/**
 * Buffered-write store over coachAnalytics/{athleteUid}. Writes queue into a
 * batch (flushed at 400 ops and before every read). withExerciseLock runs
 * its body inside a Firestore transaction, serialising concurrent
 * reconciliation per exercise (concurrent triggers retry and converge).
 */
function firestoreStore(athleteUid) {
  const base = analyticsRef(athleteUid);
  let batch = db.batch();
  let ops = 0;

  async function flush() {
    if (ops > 0) {
      const b = batch;
      batch = db.batch();
      ops = 0;
      await b.commit();
    }
  }
  async function queue(fn) {
    fn(batch);
    ops += 1;
    if (ops >= 400) await flush();
  }

  return {
    async getSummary(exerciseId) {
      await flush();
      const s = await base.collection('exercises').doc(exerciseId).get();
      return s.exists ? s.data() : null;
    },
    async getDay(exerciseId, dateKey) {
      await flush();
      const s = await base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey)).get();
      return s.exists ? s.data().day : null;
    },
    async listDaysForExercise(exerciseId) {
      await flush();
      const snap = await base.collection('exerciseDays')
        .where('exerciseId', '==', exerciseId).get();
      return snap.docs.map((d) => ({ dateKey: d.data().dateKey, day: d.data().day }));
    },
    async listExerciseIdsForDate(dateKey) {
      await flush();
      const snap = await base.collection('exerciseDays')
        .where('dateKey', '==', dateKey).get();
      return [...new Set(snap.docs.map((d) => d.data().exerciseId))];
    },
    async setDay(exerciseId, dateKey, day) {
      await queue((b) => b.set(
        base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey)),
        { exerciseId, dateKey, day }));
    },
    async deleteDay(exerciseId, dateKey) {
      await queue((b) => b.delete(
        base.collection('exerciseDays').doc(dayDocId(exerciseId, dateKey))));
    },
    async setSummary(exerciseId, data) {
      await queue((b) => b.set(base.collection('exercises').doc(exerciseId), {
        ...data,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }));
    },
    async deleteSummary(exerciseId) {
      await queue((b) => b.delete(base.collection('exercises').doc(exerciseId)));
    },
    async listEventIdsForExercise(exerciseId) {
      await flush();
      const snap = await base.collection('events')
        .where('exerciseId', '==', exerciseId).get();
      return snap.docs.map((d) => d.id);
    },
    async setEvent(ev) {
      await queue((b) => b.set(base.collection('events').doc(ev.id), ev));
    },
    async deleteEvent(eventId) {
      await queue((b) => b.delete(base.collection('events').doc(eventId)));
    },
    async withExerciseLock(exerciseId, fn) {
      await flush(); // buffered writes must land before the txn reads
      await db.runTransaction(async (tx) => fn(txStore(tx, base)));
    },
    flush,
  };
}

// ── Incremental analytics trigger ───────────────────────────────────────────

/**
 * Trigger: keeps coach analytics in sync with workout writes (create, edit,
 * delete). The decision (skip / defer-to-bootstrap / apply) is taken inside
 * a transaction on the analytics state doc, so it serialises against the
 * bootstrap's claim and completion transactions.
 * Runs alongside (never replaces) the existing repointsMonthlyAggregator.
 */
const coachAnalyticsOnWorkoutWrite = onDocumentWritten(
  // retry: analytics maintenance is idempotent (deterministic ids/content),
  // and without retries a crashed invocation would silently lose this
  // workout's PB analytics until the next edit of the same day.
  { document: 'users/{uid}/workouts/{workoutId}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const workoutId = event.params.workoutId;
    if (!DATE_KEY_RE.test(workoutId)) return; // only date-keyed workout docs

    try {
      const decision = await db.runTransaction(async (tx) => {
        const snap = await tx.get(analyticsRef(uid));
        const state = snap.exists ? snap.data() : null;
        const dec = enrollment.workoutTriggerDecision(state);
        if (dec === 'defer') {
          tx.update(analyticsRef(uid), {
            dirtyDates: admin.firestore.FieldValue.arrayUnion(workoutId),
          });
        }
        return dec;
      });
      if (decision !== 'apply') return;

      const store = firestoreStore(uid);
      const afterData = event.data.after.exists ? event.data.after.data() : null;
      await applyWorkoutDay(store, workoutId, afterData);
      await store.flush();
    } catch (err) {
      logger.error('coachAnalyticsOnWorkoutWrite failed', { uid, workoutId, error: err });
      throw err;
    }
  }
);

// ── Historical bootstrap (atomic ownership) ─────────────────────────────────

/**
 * Atomically claims bootstrap ownership. Returns the new runId when this
 * caller owns a fresh run, or null when a live run exists / analytics are
 * already ready. A formula-version change additionally stamps
 * e1rmRebaselinedAtKey (E1RM praise floor — see draft.js).
 */
async function claimBootstrap(athleteUid, { maintenanceWasOff }) {
  const stateRef = analyticsRef(athleteUid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(stateRef);
    const state = snap.exists ? snap.data() : null;
    const decision = enrollment.claimDecision(state, Date.now(), VERSIONS, maintenanceWasOff);
    if (decision !== 'claim') return null;

    const runId = `${Date.now()}_${crypto.randomBytes(6).toString('hex')}`;
    const claim = {
      bootstrapStatus: 'running',
      bootstrapRunId: runId,
      bootstrapAt: admin.firestore.FieldValue.serverTimestamp(),
      bootstrapAtMs: Date.now(),
      dirtyDates: [],
    };
    if (enrollment.isFormulaRebaseline(state, E1RM_FORMULA_VERSION)) {
      claim.e1rmRebaselinedAtKey = todayKeyIn(DEFAULT_TZ);
    }
    tx.set(stateRef, claim, { merge: true });
    return runId;
  });
}

/**
 * Bounded, idempotent per-athlete backfill, owned by runId.
 *
 * Concurrency contract: while this run owns bootstrapStatus 'running', the
 * workout trigger defers every write into dirtyDates (transactionally).
 * After the bulk rebuild, a reconciliation loop drains dirtyDates by
 * replaying each day from its CURRENT workout doc; the completion
 * transaction flips to 'complete' only when dirtyDates is empty AND this
 * run still owns the state. A superseded run (stale owner replaced by a
 * newer claim) aborts silently without touching the newer run's state.
 */
async function runBootstrap(athleteUid, runId) {
  const stateRef = analyticsRef(athleteUid);
  try {
    // 1) Chronological scan (doc ids are YYYY-MM-DD), paged.
    const entries = []; // [dateKey, data]
    const PAGE = 300;
    let last = null;
    for (;;) {
      let q = db.collection('users').doc(athleteUid).collection('workouts')
        .orderBy(admin.firestore.FieldPath.documentId())
        .limit(PAGE);
      if (last) q = q.startAfter(last);
      const page = await q.get();
      if (page.empty) break;
      for (const doc of page.docs) {
        if (DATE_KEY_RE.test(doc.id)) entries.push([doc.id, doc.data()]);
      }
      last = page.docs[page.docs.length - 1];
      if (page.size < PAGE) break;
    }

    // 2) Deterministic wholesale rebuild (only the owner may destroy).
    if (!(await stillOwns(stateRef, runId))) return;
    await deleteCollection(stateRef.collection('exerciseDays'));
    await deleteCollection(stateRef.collection('exercises'));
    await deleteCollection(stateRef.collection('events'));
    const store = firestoreStore(athleteUid);
    const exerciseCount = await bulkRebuild(store, entries);
    await store.flush();

    // 3) Drain writes that raced the scan, then complete atomically.
    const MAX_ROUNDS = 20;
    for (let round = 0; ; round++) {
      if (round >= MAX_ROUNDS) {
        throw new Error('bootstrap reconciliation did not settle');
      }
      const outcome = await db.runTransaction(async (tx) => {
        const snap = await tx.get(stateRef);
        const state = snap.exists ? snap.data() : null;
        if (!enrollment.ownsRun(state, runId)) return { superseded: true };
        const dd = Array.isArray(state.dirtyDates) ? state.dirtyDates : [];
        if (dd.length === 0) {
          tx.set(stateRef, {
            bootstrapStatus: 'complete',
            bootstrapError: admin.firestore.FieldValue.delete(),
            e1rmFormulaVersion: E1RM_FORMULA_VERSION,
            analyticsVersion: ANALYTICS_VERSION,
          }, { merge: true });
          return { complete: true };
        }
        tx.set(stateRef, { dirtyDates: [] }, { merge: true });
        return { dirty: dd };
      });
      if (outcome.superseded) {
        logger.warn('bootstrap superseded by a newer run', { athleteUid, runId });
        return;
      }
      if (outcome.complete) break;

      for (const dateKey of [...new Set(outcome.dirty)]) {
        if (!DATE_KEY_RE.test(dateKey)) continue;
        const snap = await db.collection('users').doc(athleteUid)
          .collection('workouts').doc(dateKey).get();
        const s = firestoreStore(athleteUid);
        await applyWorkoutDay(s, dateKey, snap.exists ? snap.data() : null);
        await s.flush();
      }
    }

    logger.info('coach bootstrap complete', { athleteUid, runId, exercises: exerciseCount });
  } catch (err) {
    logger.error('coach bootstrap failed', { athleteUid, runId, error: err });
    // Record the error only if this run still owns the state.
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(stateRef);
      if (enrollment.ownsRun(snap.exists ? snap.data() : null, runId)) {
        tx.set(stateRef, {
          bootstrapStatus: 'error',
          bootstrapError: String(err && err.message ? err.message : err),
        }, { merge: true });
      }
    });
    throw err;
  }
}

async function stillOwns(stateRef, runId) {
  const snap = await stateRef.get();
  return enrollment.ownsRun(snap.exists ? snap.data() : null, runId);
}

async function deleteCollection(colRef) {
  for (;;) {
    const page = await colRef.limit(400).get();
    if (page.empty) return;
    const batch = db.batch();
    page.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    if (page.size < 400) return;
  }
}

/** Claims + runs a bootstrap when the state requires one. Returns true when
 *  analytics are ready afterwards. */
async function bootstrapIfNeeded(athleteUid, { maintenanceWasOff }) {
  const runId = await claimBootstrap(athleteUid, { maintenanceWasOff });
  if (runId) await runBootstrap(athleteUid, runId);
  const snap = await analyticsRef(athleteUid).get();
  return enrollment.analyticsReady(snap.exists ? snap.data() : null, VERSIONS);
}

// ── Enrollment / settings / assignment triggers ─────────────────────────────

/**
 * Trigger: coach flips reporting on/off for an athlete (or the settings doc
 * is deleted). Also stamps the server-authoritative goal phase: goalSetAt
 * changes ONLY when the goal value genuinely changes (or was never stamped),
 * so unrelated settings writes and same-goal resaves cannot reset milestone
 * praise eligibility.
 */
const coachOnAthleteSettingsWritten = onDocumentWritten(
  { document: 'coachCheckIns/{coachUid}/athletes/{athleteUid}', timeoutSeconds: 540, memory: '512MiB' },
  async (event) => {
    const { coachUid, athleteUid } = event.params;
    const before = event.data.before.exists ? event.data.before.data() : null;
    const after = event.data.after.exists ? event.data.after.data() : null;

    // Server-authoritative goal phase.
    if (after && after.goal
        && (!before || before.goal !== after.goal || after.goalSetAt == null)) {
      await athleteSettingsRef(coachUid, athleteUid).set({
        goalSetAt: Date.now(),
      }, { merge: true });
    }

    const action = enrollment.settingsTransition(before, after);
    if (action === 'none') return;

    if (action === 'register') {
      if (!(await isCoachFor(coachUid, athleteUid))) {
        logger.warn('settings write for non-assigned athlete ignored', { coachUid, athleteUid });
        return;
      }
      // Materialise the coach doc so the scheduler's collection scan sees it.
      const coachSnap = await coachRef(coachUid).get();
      if (!coachSnap.exists) {
        await coachRef(coachUid).set({ timezone: DEFAULT_TZ }, { merge: true });
      }

      // Register atomically and learn whether maintenance had been off.
      const maintenanceWasOff = await db.runTransaction(async (tx) => {
        const snap = await tx.get(analyticsRef(athleteUid));
        const enabledBy = snap.exists ? (snap.data().enabledBy || {}) : {};
        const wasOff = Object.keys(enabledBy).length === 0;
        tx.set(analyticsRef(athleteUid), {
          enabledBy: { [coachUid]: true },
        }, { merge: true });
        return wasOff;
      });

      await bootstrapIfNeeded(athleteUid, { maintenanceWasOff });
    } else if (action === 'deregister') {
      await analyticsRef(athleteUid).set({
        enabledBy: { [coachUid]: admin.firestore.FieldValue.delete() },
      }, { merge: true });
    }
  }
);

/**
 * Re-evaluates one coach⇄athlete relationship and server-disables reporting
 * when NO valid assignment source remains. Idempotent; preserves access when
 * either source still authorises.
 */
async function reevaluateEnrollment(coachUid, athleteUid, reason) {
  const settingsSnap = await athleteSettingsRef(coachUid, athleteUid).get();
  const enabled = settingsSnap.exists && settingsSnap.data().reportingEnabled === true;
  if (!enabled) return; // nothing to clean up (deregistration already handled)
  if (await isCoachFor(coachUid, athleteUid)) return; // still authorised

  logger.warn('auto-disabling revoked coach/athlete enrollment', { coachUid, athleteUid, reason });
  await athleteSettingsRef(coachUid, athleteUid).set({
    reportingEnabled: false,
    disabledReason: reason,
    disabledAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  // The settings trigger also deregisters, but remove enabledBy directly so
  // analytics maintenance stops immediately even if trigger delivery lags.
  await analyticsRef(athleteUid).set({
    enabledBy: { [coachUid]: admin.firestore.FieldValue.delete() },
  }, { merge: true });
}

/** Trigger: immediate cleanup when an athlete's assignment doc changes
 *  (approval flipped/removed, coach entry deleted, document deleted). */
const coachOnAthleteAssignmentsWritten = onDocumentWritten(
  'athleteAssignments/{athleteUid}',
  async (event) => {
    const athleteUid = event.params.athleteUid;
    const before = event.data.before.exists ? (event.data.before.data().coaches || {}) : {};
    const after = event.data.after.exists ? (event.data.after.data().coaches || {}) : {};
    const coachUids = new Set([...Object.keys(before), ...Object.keys(after)]);
    for (const coachUid of coachUids) {
      try {
        await reevaluateEnrollment(coachUid, athleteUid, 'assignment-revoked');
      } catch (err) {
        logger.error('athleteAssignments cleanup failed', { coachUid, athleteUid, error: err });
      }
    }
  }
);

/** Trigger: immediate cleanup when a coach's seeded roster changes. */
const coachOnCoachAssignmentsWritten = onDocumentWritten(
  'coachAssignments/{coachUid}',
  async (event) => {
    const coachUid = event.params.coachUid;
    const before = event.data.before.exists ? (event.data.before.data().athletes || {}) : {};
    const after = event.data.after.exists ? (event.data.after.data().athletes || {}) : {};
    // Only athletes REMOVED from the seeded roster can lose access here.
    for (const athleteUid of Object.keys(before)) {
      if (after[athleteUid] != null) continue;
      try {
        await reevaluateEnrollment(coachUid, athleteUid, 'assignment-revoked');
      } catch (err) {
        logger.error('coachAssignments cleanup failed', { coachUid, athleteUid, error: err });
      }
    }
  }
);

// ── Checkpoint report generation ────────────────────────────────────────────

/** Completed-workout day detection identical to HomeV2CalendarService. */
function hasCompletedSets(data) {
  const exercises = data && data.exercises;
  if (!Array.isArray(exercises)) return false;
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    const sets = ex.sets;
    if (!Array.isArray(sets)) continue;
    for (const s of sets) {
      if (!s || typeof s !== 'object') continue;
      const w = Number(s.weight != null ? s.weight : s.actualWeight) || 0;
      const r = Number(s.reps != null ? s.reps : s.actualReps) || 0;
      if (w > 0 && r > 0) return true;
    }
  }
  return false;
}

/** Which of the dateKeys have a completed workout doc. Bounded direct gets. */
async function completedWorkoutDays(athleteUid, dateKeys) {
  const refs = dateKeys.map((k) =>
    db.collection('users').doc(athleteUid).collection('workouts').doc(k));
  if (refs.length === 0) return [];
  const snaps = await db.getAll(...refs);
  const out = [];
  snaps.forEach((snap, i) => {
    if (snap.exists && hasCompletedSets(snap.data())) out.push(dateKeys[i]);
  });
  return out;
}

/** Active block meta ({blockId, startKey, endKey}) or null. */
async function activeBlock(athleteUid, tz) {
  const q = await db.collection('planned_blocks').doc(athleteUid)
    .collection('blocks')
    .where('isActive', '==', true)
    .limit(1)
    .get();
  if (q.empty) return null;
  const doc = q.docs[0];
  const d = doc.data();
  const start = d.startDate && typeof d.startDate.toDate === 'function' ? d.startDate.toDate() : null;
  const end = d.endDate && typeof d.endDate.toDate === 'function' ? d.endDate.toDate() : null;
  if (!start) return null;
  return {
    blockId: doc.id,
    startKey: cov.localDateKey(start, safeTz(tz)),
    endKey: end ? cov.localDateKey(end, safeTz(tz)) : null,
  };
}

/** Planned-workout day count for a block-anchored training week. */
async function plannedCountForWeek(athleteUid, block, weekIndex) {
  const refs = [];
  for (let i = 0; i < 7; i++) {
    refs.push(db.collection('planned_blocks').doc(athleteUid)
      .collection('blocks').doc(block.blockId)
      .collection('weeks').doc(`week_${weekIndex}`)
      .collection('days').doc(`day_${i}`));
  }
  const snaps = await db.getAll(...refs);
  let count = 0;
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const ex = snap.data().exercises;
    if (Array.isArray(ex) && ex.length > 0) count += 1;
  }
  return count;
}

function rangeKeys(startKey, endKeyExclusive) {
  const out = [];
  for (let k = startKey; k < endKeyExclusive; k = cov.addDaysKey(k, 1)) out.push(k);
  return out;
}

/** Weekly-completion candidate (block-anchored week; never split by Mon/Thu
 *  message windows; eligible at the first checkpoint after it is known). */
async function completionCandidate(athleteUid, block, checkpointKey) {
  if (!block) return null;
  const current = cov.trainingWeekOf(block.startKey, cov.addDaysKey(checkpointKey, -1));
  if (!current) return null;

  const evaluate = async (week) => {
    const planned = await plannedCountForWeek(athleteUid, block, week.weekIndex);
    const doneDays = await completedWorkoutDays(athleteUid, rangeKeys(week.weekStart, week.weekEnd));
    return {
      weekKey: week.weekStart,
      weekStart: week.weekStart,
      weekEnd: week.weekEnd,
      weekIndex: week.weekIndex,
      plannedCount: planned,
      completedCount: doneDays.length,
      completedAll: planned > 0 && doneDays.length >= planned,
    };
  };

  const candidates = [await evaluate(current)];
  if (current.weekIndex > 0) {
    const prevWeek = cov.trainingWeekOf(block.startKey, cov.addDaysKey(current.weekStart, -1));
    if (prevWeek) candidates.push(await evaluate(prevWeek));
  }
  const qualifies = (c) => c.completedAll || c.completedCount >= 3;
  const qualifying = candidates.filter(qualifies).sort((a, b) => {
    if (a.completedAll !== b.completedAll) return a.completedAll ? -1 : 1;
    return a.weekStart < b.weekStart ? 1 : -1; // newer first
  });
  if (qualifying.length > 0) return qualifying[0];
  const withActivity = candidates.find((c) => c.completedCount > 0);
  return withActivity || null;
}

/** Most recent trained week (for the no-training coach fallback label).
 *  Derived from the bounded exerciseDays analytics (dateKey desc, limit 1) —
 *  reports only generate on ready analytics, so this is authoritative and
 *  avoids scanning raw workout history. */
async function lastTrainedWeek(athleteUid, block, beforeKey) {
  const q = await analyticsRef(athleteUid).collection('exerciseDays')
    .where('dateKey', '<', beforeKey)
    .orderBy('dateKey', 'desc')
    .limit(1)
    .get();
  if (q.empty) return null;
  const lastKey = q.docs[0].data().dateKey;
  if (block) {
    const wk = cov.trainingWeekOf(block.startKey, lastKey);
    if (wk) {
      const days = await completedWorkoutDays(athleteUid, rangeKeys(wk.weekStart, wk.weekEnd));
      return { weekStart: wk.weekStart, weekEnd: wk.weekEnd, workoutDates: days };
    }
  }
  return { weekStart: lastKey, weekEnd: cov.addDaysKey(lastKey, 1), workoutDates: [lastKey] };
}

/**
 * Generates one athlete's checkpoint report document. Idempotent (create-
 * only). THROWS when analytics are not verifiably ready — a report is never
 * fabricated from missing, failed, mid-bootstrap or wrong-generation
 * analytics; the scheduler leaves the slot empty and retries.
 */
async function generateReport(coachUid, athleteUid, checkpointKey, tz) {
  const ref = reportRef(coachUid, athleteUid, checkpointKey);
  if ((await ref.get()).exists) return false;

  // Readiness gate (may self-heal an errored/never-run bootstrap).
  let stateSnap = await analyticsRef(athleteUid).get();
  let state = stateSnap.exists ? stateSnap.data() : null;
  if (!enrollment.analyticsReady(state, VERSIONS)) {
    const ready = await bootstrapIfNeeded(athleteUid, { maintenanceWasOff: false });
    if (!ready) {
      throw new Error(`analytics not ready for ${athleteUid} (status=${state && state.bootstrapStatus})`);
    }
    stateSnap = await analyticsRef(athleteUid).get();
    state = stateSnap.data();
  }
  const e1rmPraiseFloorKey = (state && state.e1rmRebaselinedAtKey) || null;

  const settingsSnap = await athleteSettingsRef(coachUid, athleteUid).get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const goal = bwx.GOALS.includes(settings.goal) ? settings.goal : 'maintain';

  const prevKey = cov.previousCheckpointKey(checkpointKey);
  const maxStartKey = cov.previousSameWeekdayKey(checkpointKey);

  // PB events inside the widest possible window [maxStart, checkpoint).
  const eventsSnap = await analyticsRef(athleteUid).collection('events')
    .where('dateKey', '>=', maxStartKey)
    .where('dateKey', '<', checkpointKey)
    .get();
  const events = eventsSnap.docs.map((d) => d.data());

  const workoutDates = await completedWorkoutDays(
    athleteUid, rangeKeys(maxStartKey, checkpointKey));

  const block = await activeBlock(athleteUid, tz);
  const completion = await completionCandidate(athleteUid, block, checkpointKey);
  const fallbackWeek = workoutDates.length === 0
    ? await lastTrainedWeek(athleteUid, block, checkpointKey)
    : null;

  // Bodyweight state at the checkpoint. Milestone suppression is per-coach
  // and per-goal-phase (settings.praisedMilestones / goalSetAt).
  const weightEntries = await loadWeightEntries(athleteUid, cov.addDaysKey(checkpointKey, -21), tz);
  const rolling = bwx.rollingComparison(weightEntries, checkpointKey);
  const trend = bwx.classifyTrend(goal, rolling.currentAvg, rolling.previousAvg);
  const awarded = bwx.awardedForPhase(settings.praisedMilestones, settings.goalSetAt);
  const newMilestoneId = bwx.detectMilestone(goal, rolling.previousAvg, rolling.currentAvg, awarded);
  const lastWeighKey = await latestWeighInKey(athleteUid, tz);
  const weighInStatus = bwx.weighInStatus(lastWeighKey, todayKeyIn(tz));

  const identity = await resolveAthleteIdentity(athleteUid);
  const variantSeed = seedFrom(`${athleteUid}|${checkpointKey}`);

  const bodyweight = {
    goal,
    currentAvg: rolling.currentAvg,
    currentCount: rolling.currentCount,
    previousAvg: rolling.previousAvg,
    previousCount: rolling.previousCount,
    trend,
    newMilestoneId: newMilestoneId || null,
    lastWeighInKey: lastWeighKey,
    weighInStatus,
  };

  const draftFor = (startKey) => buildDraftText({
    events, completion, settings, identity, bodyweight,
    coverageStart: startKey, coverageEnd: checkpointKey, variantSeed,
    e1rmPraiseFloorKey,
  });

  await ref.create({
    athleteUid,
    checkpointKey,
    weekday: cov.weekdayOfKey(checkpointKey),
    status: 'draft',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    variantSeed,
    gender: identity.gender,
    firstName: identity.firstName,
    displayName: identity.displayName,
    prevCheckpointKey: prevKey,
    maxStartKey,
    events,
    workoutDates,
    completion: completion || null,
    fallbackWeek: fallbackWeek || null,
    blockStartKey: block ? block.startKey : null,
    bodyweight,
    e1rmPraiseFloorKey,
    draftIfPrevCopied: draftFor(prevKey),
    draftIfPrevNotCopied: draftFor(maxStartKey),
    analyticsVersion: ANALYTICS_VERSION,
    e1rmFormulaVersion: E1RM_FORMULA_VERSION,
  });
  return true;
}

/** Deterministic 32-bit seed from a string. */
function seedFrom(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

/**
 * Scheduler: hourly sweep with deterministic catch-up. For every coach,
 * computes the bounded list of Mon/Thu checkpoints still unprocessed in
 * their (validated) timezone — so an outage over a whole checkpoint day is
 * recovered on the next run — and generates any missing per-athlete reports.
 *
 * Checkpoint IDENTITY is not derived from the watermark (the dashboard gets
 * it from coachReviewContext), so one failing athlete never hides other
 * athletes' finished reports; the watermark only bounds re-scanning and
 * advances contiguously over fully-successful checkpoints.
 */
const coachCheckpointScheduler = onSchedule(
  { schedule: 'every 60 minutes', timeoutSeconds: 540, memory: '512MiB' },
  async () => {
    const coaches = await db.collection('coachCheckIns').get();
    const now = new Date();

    for (const coachDoc of coaches.docs) {
      const coachUid = coachDoc.id;
      const data = coachDoc.data() || {};
      const tz = safeTz(data.timezone);
      const todayKey = cov.localDateKey(now, tz);
      const pending = cov.pendingCheckpoints(data.lastCheckpointKey || null, todayKey);
      if (pending.length === 0) continue;

      try {
        const athletes = await coachRef(coachUid).collection('athletes')
          .where('reportingEnabled', '==', true)
          .get();

        let watermark = data.lastCheckpointKey || null;
        for (const checkpointKey of pending) {
          let allOk = true;
          for (const aDoc of athletes.docs) {
            const athleteUid = aDoc.id;
            try {
              if (!(await isCoachFor(coachUid, athleteUid))) {
                // Defence in depth — assignment triggers normally handle this.
                await reevaluateEnrollment(coachUid, athleteUid, 'assignment-revoked');
                continue;
              }
              await generateReport(coachUid, athleteUid, checkpointKey, tz);
              await expireStaleDraft(coachUid, athleteUid, checkpointKey);
            } catch (err) {
              allOk = false;
              logger.error('report generation failed', { coachUid, athleteUid, checkpointKey, error: err });
            }
          }
          if (allOk) {
            watermark = checkpointKey; // contiguous advance only
          } else {
            break; // retry this checkpoint (and later ones) next run
          }
        }
        if (watermark && watermark !== (data.lastCheckpointKey || null)) {
          await coachRef(coachUid).set({ lastCheckpointKey: watermark }, { merge: true });
        }
      } catch (err) {
        logger.error('checkpoint sweep failed for coach', { coachUid, error: err });
      }
    }
  }
);

/** Expires the draft two checkpoints back (older than the new "previous"). */
async function expireStaleDraft(coachUid, athleteUid, checkpointKey) {
  const prev = cov.previousCheckpointKey(checkpointKey);
  const prevPrev = cov.previousCheckpointKey(prev);
  const ref = reportRef(coachUid, athleteUid, prevPrev);
  const snap = await ref.get();
  if (snap.exists && snap.data().status === 'draft') {
    await ref.set({ status: 'expired', expiredAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
  }
}

// ── Callables ───────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  return request.auth.uid;
}

function requireArgs(request) {
  const { athleteUid, checkpointKey } = request.data || {};
  if (typeof athleteUid !== 'string' || !DATE_KEY_RE.test(String(checkpointKey || ''))) {
    throw new HttpsError('invalid-argument', 'athleteUid and checkpointKey required.');
  }
  return { athleteUid, checkpointKey };
}

/** Every athlete-specific callable revalidates the approved relationship at
 *  invocation time — a revoked coach cannot copy, undo or skip. */
async function requireAssignment(coachUid, athleteUid) {
  if (!(await isCoachFor(coachUid, athleteUid))) {
    throw new HttpsError('permission-denied', 'Not an assigned coach for this athlete.');
  }
}

function mapTxnError(err) {
  if (err instanceof TxnError) return new HttpsError(err.codeName, err.message);
  return err;
}

/**
 * Server-derived Weekly Review context: coach-local today, checkpoint
 * identity (pure timezone computation — independent of scheduler success)
 * and per-athlete live weigh-in staleness. The device timezone never
 * influences any of these.
 */
// invoker: 'public' grants ONLY the Cloud Run infrastructure permission that
// lets a request reach the callable handler — the standard posture for
// Firebase callables. Without it the initial deploy's failed IAM binding left
// these services rejecting every request with a Cloud Run 401 before any of
// our code ran. Authentication (requireAuth), App Check and the
// coach/super-admin authorisation (requireAssignment) are all still enforced
// inside each handler below.
const CALLABLE_OPTS = { invoker: 'public' };

const coachReviewContext = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  const athleteUids = Array.isArray(request.data && request.data.athleteUids)
    ? request.data.athleteUids.filter((u) => typeof u === 'string').slice(0, 100)
    : [];

  const tz = await coachTimezone(coachUid);
  const todayKey = todayKeyIn(tz);
  const currentCheckpointKey = cov.checkpointOnOrBefore(todayKey);
  const prevCheckpointKey = cov.previousCheckpointKey(currentCheckpointKey);

  const athletes = {};
  await Promise.all(athleteUids.map(async (athleteUid) => {
    if (!(await isCoachFor(coachUid, athleteUid))) return; // silently omit
    const lastWeighInKey = await latestWeighInKey(athleteUid, tz);
    athletes[athleteUid] = {
      lastWeighInKey,
      weighInStatus: bwx.weighInStatus(lastWeighInKey, todayKey),
    };
  }));

  return { timezone: tz, todayKey, currentCheckpointKey, prevCheckpointKey, athletes };
});

/** Copy: live bodyweight recheck + atomic freeze; returns the exact frozen
 *  finalText the client must display and put on the clipboard. */
const coachPrepareCheckInCopy = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = requireArgs(request);
  await requireAssignment(coachUid, athleteUid);

  const tz = await coachTimezone(coachUid);
  const todayKey = todayKeyIn(tz);

  // Live (non-state) prefetch; the goal/milestone/praise parts are resolved
  // inside the transaction from transactional state.
  const reportSnap = await reportRef(coachUid, athleteUid, checkpointKey).get();
  if (!reportSnap.exists) throw new HttpsError('not-found', 'Report not found.');
  const goal = (reportSnap.data().bodyweight && reportSnap.data().bodyweight.goal) || 'maintain';
  const liveBodyweight = await liveBodyweightBase(athleteUid, tz, goal);

  try {
    return await copyTransaction(db, {
      coachUid, athleteUid, checkpointKey, todayKey, liveBodyweight,
    });
  } catch (err) {
    throw mapTxnError(err);
  }
});

/** Undo / Mark-Not-Sent. */
const coachUndoCheckIn = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = requireArgs(request);
  await requireAssignment(coachUid, athleteUid);
  const tz = await coachTimezone(coachUid);
  try {
    return await undoTransaction(db, {
      coachUid, athleteUid, checkpointKey, todayKey: todayKeyIn(tz),
    });
  } catch (err) {
    throw mapTxnError(err);
  }
});

/** Skip check-in. */
const coachSkipCheckIn = onCall(CALLABLE_OPTS, async (request) => {
  const coachUid = requireAuth(request);
  const { athleteUid, checkpointKey } = requireArgs(request);
  await requireAssignment(coachUid, athleteUid);
  try {
    return await skipTransaction(db, { coachUid, athleteUid, checkpointKey });
  } catch (err) {
    throw mapTxnError(err);
  }
});

module.exports = {
  coachAnalyticsOnWorkoutWrite,
  coachOnAthleteSettingsWritten,
  coachOnAthleteAssignmentsWritten,
  coachOnCoachAssignmentsWritten,
  coachCheckpointScheduler,
  coachReviewContext,
  coachPrepareCheckInCopy,
  coachUndoCheckIn,
  coachSkipCheckIn,
  // Exported for emulator integration tests (not deployed as functions):
  _internals: {
    firestoreStore,
    claimBootstrap,
    runBootstrap,
    bootstrapIfNeeded,
    generateReport,
    reevaluateEnrollment,
    liveBodyweightBase,
    loadWeightEntries,
  },
};
