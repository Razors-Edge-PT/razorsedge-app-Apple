// Firestore adapter for the profile showcase projection, plus the always-on
// workout trigger and the reusable per-athlete rebuild used by the backfill.
//
// Documents (see showcase/store.js for the full contract):
//   users/{uid}/showcase/state
//   users/{uid}/showcaseDays/{slot}__{dateKey}
//   users_public/{uid}.profileShowcaseV1
//
// V2 — categories and RE Points (see showcase/store_v2.js), maintained BESIDE
// V1 by the same triggers:
//   users/{uid}/showcase/stateV2
//   users/{uid}/showcase/v2/days/{category}__{slot}__{dateKey}
//   users_public/{uid}.profileShowcaseV2
//
// The mirror onto users_public writes ONE key with { merge: true }. It cannot
// disturb rePoints*, avatar, bio or any other field, which is what keeps the
// rolling 12-month RE / GoodLift calculation and this lifetime projection from
// ever overwriting each other.

'use strict';

const { onDocumentWritten, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const { applyWorkoutDay, rebuildAll, refreshBodyweight, dayDocId } = require('./store');
const {
  applyWorkoutDayV2,
  rebuildAllV2,
  refreshV2,
  memoryStoreV2,
  dayDocIdV2,
} = require('./store_v2');
const { PROFILE_SHOWCASE_SCHEMA } = require('./reducer');
const { PROFILE_SHOWCASE_V2_SCHEMA, RE_SLOT_ORDER } = require('./reducer_v2');
const { scoringSexOf } = require('./re_points');
const { SLOT_ORDER } = require('./big_five');
const {
  BODYWEIGHT_QUERY_LIMIT,
  bodyweightCutoffMillis,
  pickBodyweightAsOf,
  weightEntryOfDoc: weightEntryOf,
  weighInSinceDateKey,
} = require('./bodyweight');

const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;
const SNAPSHOT_FIELD = 'profileShowcaseV1';
const SNAPSHOT_V2_FIELD = 'profileShowcaseV2';

function db() {
  return admin.firestore();
}

function userRef(uid) {
  return db().collection('users').doc(uid);
}

function stateRef(uid) {
  return userRef(uid).collection('showcase').doc('state');
}

function daysCol(uid) {
  return userRef(uid).collection('showcaseDays');
}

function publicRef(uid) {
  return db().collection('users_public').doc(uid);
}

function stateV2Ref(uid) {
  return userRef(uid).collection('showcase').doc('stateV2');
}

function daysV2Col(uid) {
  return userRef(uid).collection('showcase').doc('v2').collection('days');
}

/**
 * Where one projection lives. The V1 layout is the original one; the V2
 * layout nests its days under showcase/, which the rules already reserve for
 * the server.
 */
const LAYOUT_V1 = {
  snapshotField: SNAPSHOT_FIELD,
  stateRef,
  daysCol,
  dayDocId,
  slots: SLOT_ORDER,
};

const LAYOUT_V2 = {
  snapshotField: SNAPSHOT_V2_FIELD,
  stateRef: stateV2Ref,
  daysCol: daysV2Col,
  dayDocId: dayDocIdV2,
  slots: RE_SLOT_ORDER,
};

/**
 * The few most recent weigh-ins that could be the bodyweight for a lift on
 * [dateKey]. Read-only; the exact choice is pickBodyweightAsOf's.
 */
function bodyweightQuery(uid, dateKey) {
  return userRef(uid)
    .collection('weights')
    .where(
      'timestamp',
      '<',
      admin.firestore.Timestamp.fromMillis(bodyweightCutoffMillis(dateKey)),
    )
    .orderBy('timestamp', 'desc')
    .limit(BODYWEIGHT_QUERY_LIMIT);
}

/**
 * Buffered Firestore store, shared by the plain (batched) and the
 * TRANSACTIONAL adapters below.
 *
 * `reader` abstracts the only difference between them:
 *   plain        reads go straight to Firestore, writes commit in batches
 *   transaction  reads go through tx.get / tx.getAll, writes apply to the tx
 *
 * ── Why reads are overlaid with the pending buffer ──────────────────────────
 * Writes accumulate rather than committing one document at a time, so a read
 * issued AFTER a queued write would otherwise see the pre-write value. That
 * matters on the rebuild path: applyWorkoutDay writes the changed day
 * contributions and then calls listDaysForSlot() to re-fold the slot. Without
 * the overlay that fold reads the days as they were BEFORE the edit, and the
 * published snapshot lags one workout write behind the day documents it is
 * supposedly derived from.
 *
 * The in-memory store used by the unit tests never had this problem, because
 * its setDay() writes immediately — which is exactly why the divergence was
 * invisible to them. The overlay makes both adapters behave identically.
 */
function bufferedStore(uid, reader, layout) {
  const L = layout || LAYOUT_V1;
  const FIELD = L.snapshotField;
  const pending = new Map(); // ref path -> { ref, data, op }
  // dayDocId -> contribution, or null for a queued delete.
  const dayOverlay = new Map();
  let snapshotCache;
  let snapshotLoaded = false;
  let stateCache;
  let stateLoaded = false;

  function queueSet(ref, data, options) {
    pending.set(ref.path, { ref, data, op: 'set', options: options || { merge: true } });
  }
  function queueDelete(ref) {
    pending.set(ref.path, { ref, op: 'delete' });
  }

  return {
    async getState() {
      if (!stateLoaded) {
        const snap = await reader.get(L.stateRef(uid));
        stateCache = snap.exists ? snap.data() : null;
        stateLoaded = true;
      }
      return stateCache;
    },
    async setState(next) {
      stateCache = Object.assign({}, next);
      stateLoaded = true;
      queueSet(
        L.stateRef(uid),
        Object.assign({}, next, {
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }),
      );
    },
    async getSnapshot() {
      if (!snapshotLoaded) {
        const snap = await reader.get(publicRef(uid));
        const data = snap.exists ? snap.data() : null;
        snapshotCache = data && data[FIELD] ? data[FIELD] : null;
        snapshotLoaded = true;
      }
      return snapshotCache;
    },
    async setSnapshot(next) {
      snapshotCache = next;
      snapshotLoaded = true;
      const payload = {};
      payload[FIELD] = Object.assign({}, next, {
        updatedAtMs: Date.now(),
      });
      // mergeFields, NOT merge.
      //
      // { merge: true } deep-merges maps, so an omitted key survives instead of
      // being removed. snapshotFromLifts() omits a lift that has no surviving
      // day, which means a plain merge could never take an achievement DOWN:
      // delete the last bench workout and the bench record stays on the public
      // profile forever, proving something the athlete no longer has any data
      // for.
      //
      // mergeFields replaces the WHOLE value at profileShowcaseV1 while
      // leaving every neighbouring field — rePoints*, avatar, bio, username —
      // completely untouched, which is the exact semantic this mirror needs.
      queueSet(publicRef(uid), payload, { mergeFields: [FIELD] });
    },
    async getDaysForDate(dateKey) {
      const refs = L.slots.map((slot) => L.daysCol(uid).doc(L.dayDocId(slot, dateKey)));
      const snaps = await reader.getAll(refs);
      const out = {};
      snaps.forEach((snap, i) => {
        if (snap.exists) out[L.slots[i]] = snap.data();
      });
      // Queued writes win over what is still stored.
      for (const slot of L.slots) {
        const id = L.dayDocId(slot, dateKey);
        if (!dayOverlay.has(id)) continue;
        const queued = dayOverlay.get(id);
        if (queued === null) delete out[slot];
        else out[slot] = queued;
      }
      return out;
    },
    async listDaysForSlot(slot) {
      const q = await reader.query(L.daysCol(uid).where('slot', '==', slot));
      const byDate = new Map();
      for (const d of q.docs) byDate.set(d.id, d.data());
      for (const [id, queued] of dayOverlay) {
        if (queued === null) {
          if (byDate.has(id)) byDate.delete(id);
        } else if (queued.slot === slot) {
          byDate.set(id, queued);
        }
      }
      const out = [...byDate.values()];
      // Deterministic order so the fold cannot depend on Firestore read order.
      out.sort((a, b) => (a.dateKey < b.dateKey ? -1 : a.dateKey > b.dateKey ? 1 : 0));
      return out;
    },
    async setDay(slot, dateKey, day) {
      dayOverlay.set(L.dayDocId(slot, dateKey), day);
      queueSet(L.daysCol(uid).doc(L.dayDocId(slot, dateKey)), day);
    },
    async deleteDay(slot, dateKey) {
      dayOverlay.set(L.dayDocId(slot, dateKey), null);
      queueDelete(L.daysCol(uid).doc(L.dayDocId(slot, dateKey)));
    },
    // The raw users/{uid}.sex value (V2 scoring input; never published).
    async getScoringSex() {
      const snap = await reader.get(userRef(uid));
      const data = snap.exists ? snap.data() : null;
      return data && data.sex !== undefined ? data.sex : null;
    },
    // Every date-keyed workout document, read-only. Used once per athlete by
    // the V2 first-write bootstrap (store_v2.applyWorkoutDayV2).
    async listWorkoutEntries() {
      const q = await reader.query(userRef(uid).collection('workouts'));
      return q.docs
        .filter((d) => DATE_KEY_RE.test(d.id))
        .map((d) => [d.id, d.data()]);
    },
    async getBodyweightAsOf(dateKey) {
      const q = await reader.query(bodyweightQuery(uid, dateKey));
      return pickBodyweightAsOf(q.docs.map(weightEntryOf), dateKey);
    },
    // Many lift dates at once (a weigh-in refresh re-ranks every Chin-Up day
    // it can affect): ONE read of the weigh-ins before the latest cutoff.
    async getBodyweightAsOfMany(dateKeys) {
      const out = new Map();
      if (!dateKeys.length) return out;
      const latest = dateKeys.reduce((a, b) => (a > b ? a : b));
      const q = await reader.query(
        userRef(uid)
          .collection('weights')
          .where(
            'timestamp',
            '<',
            admin.firestore.Timestamp.fromMillis(bodyweightCutoffMillis(latest)),
          ),
      );
      const entries = q.docs.map(weightEntryOf);
      for (const d of dateKeys) out.set(d, pickBodyweightAsOf(entries, d));
      return out;
    },
    async flush() {
      const ops = [...pending.values()];
      pending.clear();
      dayOverlay.clear();
      await reader.commit(ops);
    },
  };
}

/** Reads straight from Firestore; writes commit in bounded batches. */
function plainReader() {
  return {
    get: (ref) => ref.get(),
    getAll: (refs) => db().getAll(...refs),
    query: (q) => q.get(),
    async commit(ops) {
      const CHUNK = 400;
      for (let i = 0; i < ops.length; i += CHUNK) {
        const batch = db().batch();
        for (const op of ops.slice(i, i + CHUNK)) {
          if (op.op === 'delete') batch.delete(op.ref);
          else batch.set(op.ref, op.data, op.options);
        }
        await batch.commit();
      }
    },
  };
}

/**
 * Reads and writes inside ONE Firestore transaction.
 *
 * Every read is issued before any write, which is the transaction contract:
 * applyWorkoutDay only ever queues writes into the buffer, and flush() is what
 * finally hands them to the transaction.
 */
function transactionReader(tx) {
  return {
    get: (ref) => tx.get(ref),
    getAll: (refs) => tx.getAll(...refs),
    query: (q) => tx.get(q),
    async commit(ops) {
      for (const op of ops) {
        if (op.op === 'delete') tx.delete(op.ref);
        else tx.set(op.ref, op.data, op.options);
      }
    },
  };
}

/** The batched, non-transactional store. Used by the offline backfill. */
function firestoreStore(uid) {
  return bufferedStore(uid, plainReader());
}

/** The transactional store. Used by the always-on trigger. */
function transactionalStore(uid, tx) {
  return bufferedStore(uid, transactionReader(tx));
}

/** The batched V2 store. Used by the offline V2 backfill. */
function firestoreStoreV2(uid) {
  return bufferedStore(uid, plainReader(), LAYOUT_V2);
}

/** The transactional V2 store. Used by the always-on triggers. */
function transactionalStoreV2(uid, tx) {
  return bufferedStore(uid, transactionReader(tx), LAYOUT_V2);
}

/**
 * Runs [fn] against a transactional V2 store, then hands its buffered writes
 * to the transaction — every read happens first, exactly as for V1.
 */
async function runV2Transactionally(uid, fn) {
  return db().runTransaction(async (tx) => {
    const store = transactionalStoreV2(uid, tx);
    const result = await fn(store);
    await store.flush();
    return result;
  });
}

/** V2 counterpart of applyWorkoutDayTransactionally (its own transaction). */
async function applyWorkoutDayV2Transactionally(uid, dateKey, workoutData) {
  return runV2Transactionally(uid, (store) => applyWorkoutDayV2(store, dateKey, workoutData));
}

/** Runs store_v2.refreshV2 for one athlete inside a transaction. */
async function refreshV2Transactionally(uid, options) {
  return runV2Transactionally(uid, (store) => refreshV2(store, options));
}

/**
 * Applies ONE workout day to ONE athlete's projection inside a single
 * Firestore transaction.
 *
 * ── Why a transaction and not a batch ───────────────────────────────────────
 * The projection is a READ-MODIFY-WRITE: the trigger reads the published
 * snapshot, folds one day into it, and writes the whole snapshot back. A batch
 * makes the WRITES atomic but does nothing about the read, so two trigger
 * instances for the same athlete — a squat day and a bench day landing
 * together, or an original delivery racing its own retry — can both read the
 * same snapshot, each fold in only their own lift, and each write the result.
 * The second commit wins and the first athlete's lift is silently gone from
 * users_public, even though its showcaseDays document is sitting right there.
 *
 * A transaction makes the read part of the atomic unit. Firestore aborts and
 * REPLAYS the losing attempt against the committed state, so the replay folds
 * its day into a snapshot that already contains the other one and both lifts
 * survive. Contention is per-athlete, and two workouts for the same athlete in
 * the same instant is rare, so the retry cost is negligible.
 *
 * Idempotency is unchanged and still carries the retry safety: document ids
 * are deterministic and every value is derived only from the surviving workout
 * days, so a duplicate delivery converges on the identical result rather than
 * double-counting.
 */
async function applyWorkoutDayTransactionally(uid, dateKey, workoutData) {
  return db().runTransaction(async (tx) => {
    const store = transactionalStore(uid, tx);
    const result = await applyWorkoutDay(store, dateKey, workoutData);
    // Hands the buffered writes to the transaction. Nothing was written to it
    // before this point, so every read above happened first.
    await store.flush();
    return result;
  });
}

/**
 * ALWAYS-ON lifetime Big Five projection. Runs for every user, with no Coach
 * Mode enrolment check — coachAnalytics has its own, separately gated trigger.
 *
 * retry: true is safe because every path is deterministic and idempotent
 * (deterministic document ids, content derived only from the surviving
 * workout days), so at-least-once delivery cannot corrupt the projection.
 */
const showcaseOnWorkoutWrite = onDocumentWritten(
  { document: 'users/{uid}/workouts/{workoutId}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const workoutId = event.params.workoutId;
    if (!DATE_KEY_RE.test(workoutId)) return; // only date-keyed workout docs

    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data()
      : null;
    let failure = null;
    try {
      const result = await applyWorkoutDayTransactionally(uid, workoutId, after);
      if (result.changed) {
        logger.info('showcase updated', {
          uid,
          dateKey: workoutId,
          path: result.path,
          slots: result.slots,
        });
      }
    } catch (err) {
      logger.error('showcaseOnWorkoutWrite failed', { uid, workoutId, error: err });
      failure = failure || err;
    }
    // V2 (categories + RE Points) beside V1, in its own transaction so neither
    // projection's contention or failure can hold the other back. Both are
    // idempotent, so the retry a failure triggers is a no-op for the one that
    // succeeded.
    try {
      const result = await applyWorkoutDayV2Transactionally(uid, workoutId, after);
      if (result.changed) {
        logger.info('showcase V2 updated', {
          uid,
          dateKey: workoutId,
          path: result.path,
          slots: result.slots,
        });
      }
    } catch (err) {
      logger.error('showcaseOnWorkoutWrite V2 failed', { uid, workoutId, error: err });
      failure = failure || err;
    }
    if (failure) throw failure;
  },
);

/**
 * Keeps Chin-Up records in step with the athlete's weigh-ins.
 *
 * A Chin-Up set is ranked at the weigh-in for THAT lift's date. A weigh-in
 * logged afterwards for that date or earlier — the common "trained, then
 * weighed in" morning, or a back-filled week — changes that bodyweight without
 * any workout being written, and with it the set's total load, its E1RM and
 * possibly which set holds the record.
 *
 * Transactional for the same reason the workout trigger is: both write
 * profileShowcaseV1 and the Chin-Up day documents, and a read-modify-write
 * that raced the other could republish a record the workout trigger had just
 * replaced.
 *
 * Idempotent and loop-free: it re-derives everything from the current
 * weigh-ins, writes only what changed, and never writes a weights document,
 * so it cannot re-trigger itself.
 */
async function refreshBodyweightTransactionally(uid, options) {
  return db().runTransaction(async (tx) => {
    const store = transactionalStore(uid, tx);
    const result = await refreshBodyweight(store, options);
    // Every read above happened before this hands the writes to the tx.
    await store.flush();
    return result;
  });
}

const showcaseOnWeightWrite = onDocumentWritten(
  { document: 'users/{uid}/weights/{weightId}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const since = weighInSinceDateKey(event);
    let failure = null;
    try {
      const result = await refreshBodyweightTransactionally(
        uid,
        since ? { sinceDateKey: since } : undefined,
      );
      if (result.changed) {
        logger.info('showcase bodyweight refreshed', { uid, slots: result.slots });
      }
    } catch (err) {
      logger.error('showcaseOnWeightWrite failed', {
        uid,
        weightId: event.params.weightId,
        error: err,
      });
      failure = failure || err;
    }
    // V2: a weigh-in moves the bodyweight EVERY exercise is scored at, for
    // each record dated on or after it — not only the bodyweight-loaded ones.
    try {
      const result = await refreshV2Transactionally(uid, {
        bodyweight: true,
        sinceDateKey: since || '',
      });
      if (result.changed) {
        logger.info('showcase V2 bodyweight refreshed', { uid, slots: result.slots });
      }
    } catch (err) {
      logger.error('showcaseOnWeightWrite V2 failed', {
        uid,
        weightId: event.params.weightId,
        error: err,
      });
      failure = failure || err;
    }
    if (failure) throw failure;
  },
);

/**
 * Re-scores V2 RE Points when the athlete's scoring sex changes.
 *
 * users/{uid} is written often (preferences, identity), so this returns
 * before any read unless `sex` changed in a way that changes the coefficient
 * (re_points.scoringSexOf). It writes only under users/{uid}/showcase and
 * users_public, never users/{uid} itself, so it cannot re-trigger itself.
 */
const showcaseOnSexChange = onDocumentUpdated(
  { document: 'users/{uid}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const before = event.data && event.data.before && event.data.before.exists
      ? event.data.before.data() || {}
      : {};
    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data() || {}
      : null;
    if (!after) return;
    if (scoringSexOf(before.sex) === scoringSexOf(after.sex)) return;
    try {
      const result = await refreshV2Transactionally(uid, { sex: true });
      if (result.changed) {
        logger.info('showcase V2 re-scored for sex change', { uid, slots: result.slots });
      }
    } catch (err) {
      logger.error('showcaseOnSexChange failed', { uid, error: err });
      throw err;
    }
  },
);

/**
 * A plain (non-transactional) bodyweight lookup for one athlete, for the
 * backfill: reads the athlete's weigh-ins ONCE and answers every date from
 * them with the same rule the triggers use.
 */
function bodyweightResolver(uid) {
  let entries = null;
  return async (dateKey) => {
    if (entries === null) {
      const q = await userRef(uid).collection('weights').get();
      entries = q.docs.map(weightEntryOf);
    }
    return pickBodyweightAsOf(entries, dateKey);
  };
}

/**
 * Deterministic full rebuild for ONE athlete. Reads every date-keyed workout
 * document (paged) and never mutates or deletes one.
 *
 * `apply: false` computes the snapshot without writing anything, which is what
 * the migration's dry-run and verify modes use.
 */
async function rebuildAthlete(uid, { apply = true, store } = {}) {
  const entries = [];
  const PAGE = 300;
  let last = null;
  for (;;) {
    let q = userRef(uid)
      .collection('workouts')
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

  const target = store ||
    (apply
      ? firestoreStore(uid)
      : require('./store').memoryStore({ bodyweightAsOf: bodyweightResolver(uid) }));
  const snapshot = await rebuildAll(target, entries);
  if (target.flush) await target.flush();
  return { snapshot, workoutDays: entries.length };
}

/**
 * Deterministic full V2 rebuild for ONE athlete. Reads every date-keyed
 * workout document (paged), and the athlete's weigh-ins and sex; never
 * mutates a workout, a weigh-in or users/{uid}.
 *
 * `apply: false` computes without writing (dry run / verify).
 * Returns { snapshot, dayIds, workoutDays }.
 */
async function rebuildAthleteV2(uid, { apply = true, store } = {}) {
  const entries = [];
  const PAGE = 300;
  let last = null;
  for (;;) {
    let q = userRef(uid)
      .collection('workouts')
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

  let target = store;
  if (!target && apply) target = firestoreStoreV2(uid);
  if (!target) {
    const userSnap = await userRef(uid).get();
    const sex = userSnap.exists ? (userSnap.data() || {}).sex : null;
    target = memoryStoreV2({ bodyweightAsOf: bodyweightResolver(uid), sex });
  }
  const { snapshot, dayIds } = await rebuildAllV2(target, entries);
  if (target.flush) await target.flush();
  return { snapshot, dayIds, workoutDays: entries.length };
}

/** Reads the V2 snapshot currently mirrored onto users_public/{uid}. */
async function readPublishedSnapshotV2(uid) {
  const snap = await publicRef(uid).get();
  const data = snap.exists ? snap.data() : null;
  return data && data[SNAPSHOT_V2_FIELD] ? data[SNAPSHOT_V2_FIELD] : null;
}

/** Removes every stale V2 day document for an athlete (rebuild hygiene). */
async function pruneStaleDaysV2(uid, keepIds) {
  const q = await daysV2Col(uid).get();
  const stale = q.docs.filter((d) => !keepIds.has(d.id));
  const CHUNK = 400;
  for (let i = 0; i < stale.length; i += CHUNK) {
    const batch = db().batch();
    for (const d of stale.slice(i, i + CHUNK)) batch.delete(d.ref);
    await batch.commit();
  }
  return stale.length;
}

/** Reads the snapshot currently mirrored onto users_public/{uid}. */
async function readPublishedSnapshot(uid) {
  const snap = await publicRef(uid).get();
  const data = snap.exists ? snap.data() : null;
  return data && data[SNAPSHOT_FIELD] ? data[SNAPSHOT_FIELD] : null;
}

/** Removes every stale showcaseDays document for an athlete (rebuild hygiene). */
async function pruneStaleDays(uid, keepIds) {
  const q = await daysCol(uid).get();
  const stale = q.docs.filter((d) => !keepIds.has(d.id));
  const CHUNK = 400;
  for (let i = 0; i < stale.length; i += CHUNK) {
    const batch = db().batch();
    for (const d of stale.slice(i, i + CHUNK)) batch.delete(d.ref);
    await batch.commit();
  }
  return stale.length;
}

module.exports = {
  showcaseOnWorkoutWrite,
  showcaseOnWeightWrite,
  showcaseOnSexChange,
  applyWorkoutDayV2Transactionally,
  refreshV2Transactionally,
  firestoreStoreV2,
  transactionalStoreV2,
  rebuildAthleteV2,
  readPublishedSnapshotV2,
  pruneStaleDaysV2,
  daysV2Col,
  stateV2Ref,
  SNAPSHOT_V2_FIELD,
  PROFILE_SHOWCASE_V2_SCHEMA,
  LAYOUT_V1,
  LAYOUT_V2,
  applyWorkoutDayTransactionally,
  refreshBodyweightTransactionally,
  weighInSinceDateKey,
  bodyweightResolver,
  firestoreStore,
  transactionalStore,
  rebuildAthlete,
  readPublishedSnapshot,
  pruneStaleDays,
  daysCol,
  stateRef,
  publicRef,
  SNAPSHOT_FIELD,
  PROFILE_SHOWCASE_SCHEMA,
  DATE_KEY_RE,
};
