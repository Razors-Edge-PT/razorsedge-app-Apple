// Firestore adapter, triggers and the daily reconciliation for the RE Points
// leaderboard. The scoring and folding live in reducer.js / store.js; this
// file only moves documents.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   users/{uid}/rePointDays/{dateKey}          private (owner read, server write)
//   users/{uid}/showcase/leaderboardState      private build marker
//   leaderboards/{periodKey}                   { periodKey, kind, status, ... }
//   leaderboards/{periodKey}/entries/{uid}     public ranked entry
//   leaderboardRecalcQueue/{uid}               private retry queue (server only)
//
// ── Who calls what ──────────────────────────────────────────────────────────
//   showcaseOnWorkoutWrite   → applyForWorkout      (after profile V2 changed)
//   showcaseOnWeightWrite    → applyForWeighIn      (the dates it can affect)
//   showcaseOnSexChange      → applyRequest full    (every date re-scored)
//   leaderboardOnPublicProfileWrite (users_public)  → all-time entry + identity
//   leaderboardReconcileDaily (scheduled)           → queue, stale, month close
// A failed recomputation is queued, never lost; every path is idempotent.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const showcaseFs = require('../showcase/firestore_store');
const { localDateKey } = require('../coach/coverage');
const {
  BODYWEIGHT_TZ,
  bodyweightCutoffMillis,
  weighInDateKey,
  weightEntryOfDoc,
} = require('../showcase/bodyweight');
const { canonicalJson } = require('../showcase/store');
const {
  LEADERBOARD_FORMULA_VERSION,
  ALL_TIME_PERIOD,
  isMonthPeriod,
  identityOf,
  sameIdentity,
} = require('./reducer');
const { isBuilt, applyRequest, refreshAllTime } = require('./store');
const { runReconciliation, requestsOfItem, mergeQueueItem } = require('./reconcile');

const QUEUE_COLLECTION = 'leaderboardRecalcQueue';

function db() {
  return admin.firestore();
}
function userRef(uid) {
  return db().collection('users').doc(uid);
}
function daysCol(uid) {
  return userRef(uid).collection('rePointDays');
}
function stateRef(uid) {
  return userRef(uid).collection('showcase').doc('leaderboardState');
}
function periodRef(periodKey) {
  return db().collection('leaderboards').doc(periodKey);
}
function entryRef(periodKey, uid) {
  return periodRef(periodKey).collection('entries').doc(uid);
}
function queueRef(uid) {
  return db().collection(QUEUE_COLLECTION).doc(uid);
}
function publicRef(uid) {
  return db().collection('users_public').doc(uid);
}
function serverTime() {
  return admin.firestore.FieldValue.serverTimestamp();
}

/**
 * The period key of "now" on the calendar the athletes train on. Only used to
 * decide which months are over and which entry carries a live identity —
 * never to date a workout, which always uses its own dateKey.
 */
function currentPeriodKey(nowMs) {
  return localDateKey(new Date(nowMs || Date.now()), BODYWEIGHT_TZ).slice(0, 7);
}

/**
 * Buffered leaderboard store for one athlete. V2 contributions, weigh-ins and
 * sex are read through the showcase V2 store (same queries, same rules as the
 * profile); writes are queued and handed over by flush().
 */
function leaderboardStore(uid, reader) {
  const v2 = showcaseFs.bufferedStore(uid, reader, showcaseFs.LAYOUT_V2);
  const pending = new Map();
  const noted = new Set();
  let profile;
  const queueSet = (ref, data) => pending.set(ref.path, { ref, data, op: 'set' });
  const queueDelete = (ref) => pending.set(ref.path, { ref, op: 'delete' });
  const docs = (q) => q.docs.map((d) => d.data());

  return {
    uid,
    async getState() {
      const s = await reader.get(stateRef(uid));
      return s.exists ? s.data() : null;
    },
    async setState(next) {
      queueSet(stateRef(uid), Object.assign({}, next, { builtAtMs: Date.now() }));
    },
    getV2State: () => v2.getState(),
    async getV2DaysForDates(dateKeys) {
      const out = new Map();
      for (const d of dateKeys) out.set(d, Object.values(await v2.getDaysForDate(d)));
      return out;
    },
    async listV2DaysInRange(since, until) {
      let q = showcaseFs.daysV2Col(uid).where('dateKey', '>=', since || '');
      if (until) q = q.where('dateKey', '<', until);
      return docs(await reader.query(q));
    },
    async listAllV2Days() {
      return docs(await reader.query(showcaseFs.daysV2Col(uid)));
    },
    getBodyweightAsOf: (d) => v2.getBodyweightAsOf(d),
    getBodyweightAsOfMany: (ds) => v2.getBodyweightAsOfMany(ds),
    getScoringSex: () => v2.getScoringSex(),
    async getPublicProfile() {
      if (profile === undefined) {
        const s = await reader.get(publicRef(uid));
        profile = s.exists ? s.data() : null;
      }
      return profile;
    },
    async listRePointDaysForPeriod(p) {
      return docs(await reader.query(daysCol(uid).where('periodKey', '==', p)));
    },
    async listRePointDaysInRange(since, until) {
      let q = daysCol(uid).where('dateKey', '>=', since || '');
      if (until) q = q.where('dateKey', '<', until);
      return docs(await reader.query(q));
    },
    async listAllRePointDays() {
      return docs(await reader.query(daysCol(uid)));
    },
    async setRePointDay(d, doc) {
      queueSet(daysCol(uid).doc(d), Object.assign({}, doc, { updatedAt: serverTime() }));
    },
    async deleteRePointDay(d) {
      queueDelete(daysCol(uid).doc(d));
    },
    async setEntry(p, entry) {
      queueSet(entryRef(p, uid), Object.assign({}, entry, { updatedAt: serverTime() }));
    },
    async deleteEntry(p) {
      queueDelete(entryRef(p, uid));
    },
    notePeriods(list) {
      for (const p of list) noted.add(p);
    },
    periodsNoted() {
      return [...noted];
    },
    async flush() {
      const ops = [...pending.values()];
      pending.clear();
      await reader.commit(ops);
    },
  };
}

/** Period documents already known to exist in this instance. */
const knownPeriods = new Set();

/**
 * Creates each period document once (create-if-absent, outside any
 * transaction, so a hot shared document never enters a per-athlete
 * transaction). A month already over is created closed.
 */
async function ensurePeriods(periodKeys, nowMs) {
  const current = currentPeriodKey(nowMs);
  for (const p of periodKeys) {
    if (knownPeriods.has(p)) continue;
    const month = isMonthPeriod(p);
    try {
      await periodRef(p).create({
        periodKey: p,
        kind: month ? 'month' : 'allTime',
        status: month && p < current ? 'closed' : 'open',
        formulaVersion: LEADERBOARD_FORMULA_VERSION,
        openedAt: serverTime(),
        updatedAt: serverTime(),
        ...(month && p < current ? { closedAt: serverTime() } : {}),
      });
    } catch (err) {
      if (!(err && (err.code === 6 || err.code === 'already-exists'))) throw err;
    }
    knownPeriods.add(p);
  }
}

/**
 * Applies one request for one athlete. A full rebuild (first build, stale
 * formula, change of sex) can touch hundreds of documents and runs batched;
 * an ordinary date/range recomputation runs in ONE transaction so two changes
 * to the same month re-sum it one after the other.
 */
async function applyRequestForUser(uid, request) {
  const req = request || {};
  const stateSnap = await stateRef(uid).get();
  const needsFull = req.full || !isBuilt(stateSnap.exists ? stateSnap.data() : null);
  let result;
  let periods = [];
  if (needsFull) {
    const store = leaderboardStore(uid, showcaseFs.plainReader());
    result = await applyRequest(store, Object.assign({}, req, { full: true }));
    await store.flush();
    periods = store.periodsNoted();
  } else {
    result = await db().runTransaction(async (tx) => {
      const store = leaderboardStore(uid, showcaseFs.transactionReader(tx));
      const r = await applyRequest(store, req);
      await store.flush();
      periods = store.periodsNoted();
      return r;
    });
  }
  await ensurePeriods(periods);
  return result;
}

/** Queues a recomputation (merged with anything already queued). */
async function enqueueRecalc(uid, request, reason) {
  await db().runTransaction(async (tx) => {
    const ref = queueRef(uid);
    const snap = await tx.get(ref);
    const merged = mergeQueueItem(snap.exists ? snap.data() : null, request, reason);
    tx.set(ref, Object.assign({ uid }, merged, { updatedAt: serverTime() }));
  });
}

/**
 * Runs [request] and, if it fails, queues it before rethrowing — so a failure
 * is retried by the trigger AND, should retries run out, by the daily job.
 */
async function applyOrEnqueue(uid, request, reason) {
  try {
    return await applyRequestForUser(uid, request);
  } catch (err) {
    try {
      await enqueueRecalc(uid, request, reason);
    } catch (qErr) {
      logger.error('leaderboard enqueue failed', { uid, error: qErr });
    }
    throw err;
  }
}

/**
 * Workout trigger hook: the workout's own date — or everything, when the
 * profile V2 was just bootstrapped from the whole history.
 */
async function applyForWorkout(uid, dateKey, options) {
  const full = !!(options && options.full);
  return applyOrEnqueue(uid, full ? { full: true } : { dateKeys: [dateKey] }, 'workout');
}

/**
 * The dates a weigh-in change can re-score: from the earliest day it counted
 * for (before or after the change) up to — not including — the next recorded
 * weigh-in day after the latest of them, which supersedes it. Open-ended when
 * there is none.
 */
async function weighInRange(uid, event) {
  const sides = [event.data && event.data.before, event.data && event.data.after]
    .filter((s) => s && s.exists);
  const days = [];
  for (const side of sides) {
    const ts = (side.data() || {}).timestamp;
    const d = weighInDateKey(ts && typeof ts.toMillis === 'function' ? ts.toMillis() : Number.NaN);
    if (!d) return { sinceDateKey: '' };
    days.push(d);
  }
  if (days.length === 0) return { sinceDateKey: '' };
  days.sort();
  const since = days[0];
  const latest = days[days.length - 1];
  const q = await userRef(uid)
    .collection('weights')
    .where('timestamp', '>=', admin.firestore.Timestamp.fromMillis(bodyweightCutoffMillis(latest)))
    .orderBy('timestamp', 'asc')
    .limit(10)
    .get();
  let until = null;
  for (const doc of q.docs) {
    const e = weightEntryOfDoc(doc);
    const d = weighInDateKey(e.tsMillis);
    if (d && d > latest && Number.isFinite(e.weight) && e.weight > 0 && (!until || d < until)) until = d;
  }
  return until ? { sinceDateKey: since, untilDateKey: until } : { sinceDateKey: since };
}

/** Weigh-in trigger hook. */
async function applyForWeighIn(uid, event) {
  const range = await weighInRange(uid, event);
  return applyOrEnqueue(uid, range, 'weigh-in');
}

/** Sex-change hook: every date is re-scored. */
async function applyForSexChange(uid) {
  return applyOrEnqueue(uid, { full: true }, 'sex');
}

function showcaseCategoriesOf(publicData) {
  const s = publicData && publicData.profileShowcaseV2;
  if (!s) return null;
  return { v: [s.schema, s.e1rmFormulaVersion, s.rePointsFormulaVersion], c: s.categories || null };
}

/**
 * The users_public/{uid} change handler, on plain before/after data (null for
 * a missing side).
 */
async function handlePublicProfileWrite(uid, before, after) {
  if (!after) {
    // The public profile is gone (account deletion): withdraw the live
    // entries. Closed months keep their historical snapshot.
    const batch = db().batch();
    batch.delete(entryRef(ALL_TIME_PERIOD, uid));
    batch.delete(entryRef(currentPeriodKey(), uid));
    await batch.commit();
    return 'withdrawn';
  }
  const scoreChanged =
    canonicalJson(showcaseCategoriesOf(before)) !== canonicalJson(showcaseCategoriesOf(after));
  const idChanged = !before || !sameIdentity(before, after);
  if (!scoreChanged && !idChanged) return 'ignored';

  const store = leaderboardStore(uid, showcaseFs.plainReader());
  const res = await refreshAllTime(store);
  await store.flush();
  await ensurePeriods(store.periodsNoted());
  if (res === 'stale') await enqueueRecalc(uid, { full: true }, 'stale-profile');

  if (idChanged) {
    const id = identityOf(await store.getPublicProfile());
    try {
      await entryRef(currentPeriodKey(), uid).update({
        username: id.username,
        photoURL: id.photoURL,
        updatedAt: serverTime(),
      });
    } catch (err) {
      if (!(err && (err.code === 5 || err.code === 'not-found'))) throw err;
    }
  }
  return res;
}

/**
 * Keeps the all-time entry in step with profileShowcaseV2, and the visible
 * identity (current month + all time only) in step with the public profile.
 * Every other users_public write returns before reading anything.
 *
 * Reads the CURRENT public document rather than the event's copy, so an
 * out-of-order delivery can never publish an older snapshot.
 */
const leaderboardOnPublicProfileWrite = onDocumentWritten(
  { document: 'users_public/{uid}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const side = (s) => (s && s.exists ? s.data() : null);
    try {
      await handlePublicProfileWrite(
        uid,
        side(event.data && event.data.before),
        side(event.data && event.data.after),
      );
    } catch (err) {
      logger.error('leaderboardOnPublicProfileWrite failed', { uid, error: err });
      throw err;
    }
  },
);

/** Firestore-backed dependencies for runReconciliation. */
function reconcileDeps(nowMs) {
  return {
    currentPeriodKey: () => currentPeriodKey(nowMs),
    async listOpenPeriods() {
      const q = await db().collection('leaderboards').where('status', '==', 'open').get();
      return q.docs.map((d) => d.id);
    },
    async closePeriod(p) {
      await periodRef(p).set(
        { status: 'closed', closedAt: serverTime(), updatedAt: serverTime() },
        { merge: true },
      );
    },
    async listStaleUids(limit) {
      const out = new Set();
      for (const p of [currentPeriodKey(nowMs), ALL_TIME_PERIOD]) {
        const q = await periodRef(p)
          .collection('entries')
          .where('formulaVersion', '!=', LEADERBOARD_FORMULA_VERSION)
          .limit(limit)
          .get();
        for (const d of q.docs) out.add(d.id);
      }
      return [...out].slice(0, limit);
    },
    enqueue: (uid, request, reason) => enqueueRecalc(uid, request, reason),
    async listQueue(pageSize, after) {
      let q = db().collection(QUEUE_COLLECTION).orderBy('updatedAt').limit(pageSize);
      if (after && after._snap) q = q.startAfter(after._snap);
      const page = await q.get();
      return page.docs.map((d) => Object.assign({ _snap: d }, d.data(), { uid: d.id }));
    },
    async processItem(item) {
      for (const req of requestsOfItem(item)) await applyRequestForUser(item.uid, req);
    },
    async markDone(item) {
      try {
        // Only if nothing was queued for this athlete while it ran.
        await queueRef(item.uid).delete({ lastUpdateTime: item._snap.updateTime });
      } catch (err) {
        if (!(err && (err.code === 9 || err.code === 'failed-precondition'))) throw err;
      }
    },
    async markFailed(item, err) {
      await queueRef(item.uid).set(
        {
          attempts: admin.firestore.FieldValue.increment(1),
          lastError: String((err && err.message) || err).slice(0, 200),
          lastAttemptAt: serverTime(),
        },
        { merge: true },
      );
    },
  };
}

/**
 * Once a day: close finished months, re-queue stale visible entries, and
 * retry queued recomputations — bounded, paginated, idempotent. It never scans
 * users or workouts.
 */
const leaderboardReconcileDaily = onSchedule(
  {
    schedule: 'every day 03:30',
    timeZone: BODYWEIGHT_TZ,
    retryCount: 1,
    timeoutSeconds: 540,
  },
  async () => {
    const { counts, failures } = await runReconciliation(reconcileDeps(Date.now()));
    logger.info('leaderboard reconciliation', counts);
    if (failures.length) logger.warn('leaderboard reconciliation failures', { failures });
  },
);

module.exports = {
  QUEUE_COLLECTION,
  leaderboardOnPublicProfileWrite,
  leaderboardReconcileDaily,
  handlePublicProfileWrite,
  leaderboardStore,
  applyRequestForUser,
  applyForWorkout,
  applyForWeighIn,
  applyForSexChange,
  enqueueRecalc,
  ensurePeriods,
  currentPeriodKey,
  reconcileDeps,
  weighInRange,
  daysCol,
  stateRef,
  periodRef,
  entryRef,
  queueRef,
};
