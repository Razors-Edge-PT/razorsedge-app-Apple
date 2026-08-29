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

const { applyWorkoutDay, rebuildAll, dayDocId } = require('./store');
const { PROFILE_SHOWCASE_SCHEMA } = require('./reducer');
const { SLOT_ORDER } = require('./big_five');

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
 * Buffered Firestore store. Reads go straight through; writes accumulate and
 * are committed by flush() in bounded batches, so one workout write costs one
 * commit rather than one commit per document.
 */
function firestoreStore(uid) {
  const pending = new Map(); // ref path -> { ref, data, op }
  let snapshotCache;
  let snapshotLoaded = false;
  let stateCache;
  let stateLoaded = false;

  function queueSet(ref, data) {
    pending.set(ref.path, { ref, data, op: 'set' });
  }
  function queueDelete(ref) {
    pending.set(ref.path, { ref, op: 'delete' });
  }

  return {
    async getState() {
      if (!stateLoaded) {
        const snap = await stateRef(uid).get();
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
        const snap = await publicRef(uid).get();
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
      queueSet(publicRef(uid), payload);
    },
    async getDaysForDate(dateKey) {
      const refs = SLOT_ORDER.map((slot) => daysCol(uid).doc(dayDocId(slot, dateKey)));
      const snaps = await db().getAll(...refs);
      const out = {};
      snaps.forEach((snap, i) => {
        if (snap.exists) out[SLOT_ORDER[i]] = snap.data();
      });
      return out;
    },
    async listDaysForSlot(slot) {
      const q = await daysCol(uid).where('slot', '==', slot).get();
      const out = q.docs.map((d) => d.data());
      // Deterministic order so the fold cannot depend on Firestore read order.
      out.sort((a, b) => (a.dateKey < b.dateKey ? -1 : a.dateKey > b.dateKey ? 1 : 0));
      return out;
    },
    async setDay(slot, dateKey, day) {
      queueSet(daysCol(uid).doc(dayDocId(slot, dateKey)), day);
    },
    async deleteDay(slot, dateKey) {
      queueDelete(daysCol(uid).doc(dayDocId(slot, dateKey)));
    },
    async flush() {
      const ops = [...pending.values()];
      pending.clear();
      const CHUNK = 400;
      for (let i = 0; i < ops.length; i += CHUNK) {
        const batch = db().batch();
        for (const op of ops.slice(i, i + CHUNK)) {
          if (op.op === 'delete') batch.delete(op.ref);
          else batch.set(op.ref, op.data, { merge: true });
        }
        await batch.commit();
      }
    },
  };
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
      const store = firestoreStore(uid);
      const after = event.data && event.data.after && event.data.after.exists
        ? event.data.after.data()
        : null;
      const result = await applyWorkoutDay(store, workoutId, after);
      await store.flush();
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

  const target = store || (apply ? firestoreStore(uid) : require('./store').memoryStore());
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
  firestoreStore,
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
