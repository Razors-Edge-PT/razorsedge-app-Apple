// Firestore adapter for the profile showcase projection, plus the always-on
// workout trigger and the reusable per-athlete rebuild used by the backfill.
//
// Documents (see showcase/store.js for the full contract):
//   users/{uid}/showcase/state
//   users/{uid}/showcaseDays/{slot}__{dateKey}
//   users_public/{uid}.profileShowcaseV1
//
// The mirror onto users_public writes ONE key with { merge: true }. It cannot
// disturb rePoints*, avatar, bio or any other field, which is what keeps the
// rolling 12-month RE / GoodLift calculation and this lifetime projection from
// ever overwriting each other.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const { applyWorkoutDay, rebuildAll, refreshBodyweight, dayDocId } = require('./store');
const { PROFILE_SHOWCASE_SCHEMA } = require('./reducer');
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
function bufferedStore(uid, reader) {
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
        const snap = await reader.get(stateRef(uid));
        stateCache = snap.exists ? snap.data() : null;
        stateLoaded = true;
      }
      return stateCache;
    },
    async setState(next) {
      stateCache = Object.assign({}, next);
      stateLoaded = true;
      queueSet(
        stateRef(uid),
        Object.assign({}, next, {
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }),
      );
    },
    async getSnapshot() {
      if (!snapshotLoaded) {
        const snap = await reader.get(publicRef(uid));
        const data = snap.exists ? snap.data() : null;
        snapshotCache = data && data[SNAPSHOT_FIELD] ? data[SNAPSHOT_FIELD] : null;
        snapshotLoaded = true;
      }
      return snapshotCache;
    },
    async setSnapshot(next) {
      snapshotCache = next;
      snapshotLoaded = true;
      const payload = {};
      payload[SNAPSHOT_FIELD] = Object.assign({}, next, {
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
      queueSet(publicRef(uid), payload, { mergeFields: [SNAPSHOT_FIELD] });
    },
    async getDaysForDate(dateKey) {
      const refs = SLOT_ORDER.map((slot) => daysCol(uid).doc(dayDocId(slot, dateKey)));
      const snaps = await reader.getAll(refs);
      const out = {};
      snaps.forEach((snap, i) => {
        if (snap.exists) out[SLOT_ORDER[i]] = snap.data();
      });
      // Queued writes win over what is still stored.
      for (const slot of SLOT_ORDER) {
        const id = dayDocId(slot, dateKey);
        if (!dayOverlay.has(id)) continue;
        const queued = dayOverlay.get(id);
        if (queued === null) delete out[slot];
        else out[slot] = queued;
      }
      return out;
    },
    async listDaysForSlot(slot) {
      const q = await reader.query(daysCol(uid).where('slot', '==', slot));
      const byDate = new Map();
      for (const d of q.docs) byDate.set(d.id, d.data());
      for (const [id, queued] of dayOverlay) {
        if (!id.startsWith(`${slot}__`)) continue;
        if (queued === null) byDate.delete(id);
        else byDate.set(id, queued);
      }
      const out = [...byDate.values()];
      // Deterministic order so the fold cannot depend on Firestore read order.
      out.sort((a, b) => (a.dateKey < b.dateKey ? -1 : a.dateKey > b.dateKey ? 1 : 0));
      return out;
    },
    async setDay(slot, dateKey, day) {
      dayOverlay.set(dayDocId(slot, dateKey), day);
      queueSet(daysCol(uid).doc(dayDocId(slot, dateKey)), day);
    },
    async deleteDay(slot, dateKey) {
      dayOverlay.set(dayDocId(slot, dateKey), null);
      queueDelete(daysCol(uid).doc(dayDocId(slot, dateKey)));
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

    try {
      const after = event.data && event.data.after && event.data.after.exists
        ? event.data.after.data()
        : null;
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
      throw err;
    }
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
    try {
      const since = weighInSinceDateKey(event);
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
