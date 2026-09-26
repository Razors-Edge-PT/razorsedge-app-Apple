// Firestore adapter and trigger for the leaderboard category medals. The
// allocation lives in medals.js; this file only moves documents.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   leaderboardMedals/{periodKey}       public snapshot (signed-in read, server write)
//   leaderboardMedalQueue/{periodKey}   private dirty-board marker (server only)
//
// ── Refresh ─────────────────────────────────────────────────────────────────
// ONE transaction reads the board's snapshot, decides whether the entry change
// can matter, and — only then — runs five bounded queries (≤ 3 entries each:
// orderBy medalRankKeys.<category>, current formula only) and writes the
// snapshot if its awards changed. The transaction is serializable, so a
// refresh always reflects one consistent set of entries: concurrent, repeated
// or out-of-order entry writes can never leave an older allocation on top of a
// newer one — each entry write triggers a refresh that runs after it.
//
// A refresh that still fails marks the board dirty (and the trigger retries);
// the daily reconciliation refreshes dirty boards and, as a safety net, the
// current month and all time.
//
// ── Cost ────────────────────────────────────────────────────────────────────
//   entry write with unchanged medal order (identity, same score)   0 reads
//   changed score that cannot reach a podium                         1 read
//   changed score that can                                    ≤ 16 reads, ≤ 1 write

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const {
  CATEGORY_KEYS,
  PLACES,
  MEDALS_COLLECTION,
  MEDAL_QUEUE_COLLECTION,
  allocateMedals,
  medalSnapshot,
  entryWriteAffectsMedals,
} = require('./medals');
const { LEADERBOARD_FORMULA_VERSION, ALL_TIME_PERIOD } = require('./reducer');
const { RE_POINTS_FORMULA_VERSION } = require('../showcase/re_points');

function db() {
  return admin.firestore();
}
function medalsRef(periodKey) {
  return db().collection(MEDALS_COLLECTION).doc(periodKey);
}
function medalQueueRef(periodKey) {
  return db().collection(MEDAL_QUEUE_COLLECTION).doc(periodKey);
}
function entriesCol(periodKey) {
  return db().collection('leaderboards').doc(periodKey).collection('entries');
}
function serverTime() {
  return admin.firestore.FieldValue.serverTimestamp();
}

/** The bounded podium query of one category (composite index per category). */
function podiumQuery(periodKey, category) {
  return entriesCol(periodKey)
    .where('formulaVersion', '==', LEADERBOARD_FORMULA_VERSION)
    .orderBy(`medalRankKeys.${category}`)
    .limit(PLACES);
}

const entryOf = (d) => Object.assign({ uid: d.id }, d.data());

/**
 * Recomputes [periodKey]'s snapshot in one transaction. With [change]
 * ({ before, after } entry sides) it first checks, inside the same
 * transaction, whether that change can affect the awards at all.
 *
 * Returns { path: 'unaffected' | 'unchanged' | 'written', revision? }.
 */
async function refreshMedals(periodKey, change) {
  return db().runTransaction(async (tx) => {
    const ref = medalsRef(periodKey);
    const prevSnap = await tx.get(ref);
    const prev = prevSnap.exists ? prevSnap.data() : null;
    if (change && !entryWriteAffectsMedals(change.before, change.after, prev, LEADERBOARD_FORMULA_VERSION)) {
      return { path: 'unaffected' };
    }
    const candidates = {};
    for (const k of CATEGORY_KEYS) {
      const q = await tx.get(podiumQuery(periodKey, k));
      candidates[k] = q.docs.map(entryOf);
    }
    const categories = allocateMedals(candidates, { allTime: periodKey === ALL_TIME_PERIOD });
    const next = medalSnapshot(periodKey, categories, {
      formulaVersion: LEADERBOARD_FORMULA_VERSION,
      rePointsFormulaVersion: RE_POINTS_FORMULA_VERSION,
      prev,
    });
    if (!next) return { path: 'unchanged', revision: prev && prev.revision };
    tx.set(ref, Object.assign({}, next, { updatedAt: serverTime() }));
    return { path: 'written', revision: next.revision };
  });
}

/** Leaves [periodKey] for the daily reconciliation (merged, idempotent). */
async function markMedalBoardDirty(periodKey, reason) {
  await medalQueueRef(periodKey).set(
    {
      periodKey,
      dirty: true,
      reasons: admin.firestore.FieldValue.arrayUnion(String(reason || 'refresh-failed').slice(0, 60)),
      updatedAt: serverTime(),
    },
    { merge: true },
  );
}

/** Dirty boards, oldest first (bounded). */
async function listDirtyMedalBoards(limit) {
  const q = await db().collection(MEDAL_QUEUE_COLLECTION).orderBy('updatedAt').limit(limit).get();
  return q.docs.map((d) => ({ periodKey: d.id, _snap: d }));
}

/** Clears a dirty marker only if nothing re-marked it while it was refreshed. */
async function clearMedalBoard(item) {
  try {
    await medalQueueRef(item.periodKey).delete({ lastUpdateTime: item._snap.updateTime });
  } catch (err) {
    if (!(err && (err.code === 9 || err.code === 'failed-precondition'))) throw err;
  }
}

/** The entry-write handler on plain before/after data (null for a missing side). */
async function handleEntryWrite(periodKey, uid, before, after) {
  const withUid = (d) => (d ? Object.assign({ uid }, d) : null);
  try {
    return await refreshMedals(periodKey, { before: withUid(before), after: withUid(after) });
  } catch (err) {
    try {
      await markMedalBoardDirty(periodKey, 'entry-write');
    } catch (qErr) {
      logger.error('leaderboard medal dirty-mark failed', { periodKey, error: qErr });
    }
    throw err;
  }
}

/**
 * Every write of a leaderboard entry — workout, weigh-in, sex, profile,
 * rebuild job, account withdrawal — reaches the medals through this one
 * trigger. Identity-only writes (username / avatar) leave the medal order
 * unchanged and return without reading anything.
 */
const leaderboardMedalsOnEntryWrite = onDocumentWritten(
  { document: 'leaderboards/{periodKey}/entries/{uid}', retry: true },
  async (event) => {
    const { periodKey, uid } = event.params;
    const side = (s) => (s && s.exists ? s.data() : null);
    const before = side(event.data && event.data.before);
    const after = side(event.data && event.data.after);
    // Cheapest exit first: nothing that orders medals changed.
    if (!entryWriteAffectsMedals(before, after, null, LEADERBOARD_FORMULA_VERSION)) return;
    try {
      await handleEntryWrite(periodKey, uid, before, after);
    } catch (err) {
      logger.error('leaderboardMedalsOnEntryWrite failed', { periodKey, uid, error: err });
      throw err;
    }
  },
);

module.exports = {
  leaderboardMedalsOnEntryWrite,
  handleEntryWrite,
  refreshMedals,
  markMedalBoardDirty,
  listDirtyMedalBoards,
  clearMedalBoard,
  podiumQuery,
  medalsRef,
  medalQueueRef,
};
