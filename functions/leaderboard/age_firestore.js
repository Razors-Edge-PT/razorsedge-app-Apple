// Firestore adapter, triggers and schedules for the optional age-adjusted
// leaderboard, the raw-board silver set and the public website feed. The
// arithmetic lives in age.js and public_feed.js; this file only moves
// documents.
//
// ── Documents ───────────────────────────────────────────────────────────────
//   leaderboardsAge/{periodKey}                 board: { ageModelVersion,
//       silverUids, rankedCount, incompleteCount, countsUpdatedAt }  (signed-in read)
//   leaderboardsAge/{periodKey}/entries/{uid}   age-ranked projection          (signed-in read)
//   leaderboardPublic/{periodKey}               public website snapshot        (server only)
// periodKey is the current Auckland month 'YYYY-MM' or 'all_time'. Every one
// is DERIVED from the raw entries, the raw day scores and the private birth
// date, and can be deleted and rebuilt at any time. Raw entries, day scores,
// medals, birth dates and workouts are only ever READ here.
//
// ── Who calls what ──────────────────────────────────────────────────────────
//   leaderboardAgeOnEntryWrite   raw entry written (current month / all time)
//                                → that athlete's age entry + silver flag
//   showcaseOnSexChange          users/{uid}.dob changed → refreshAthleteAge
//   leaderboardAgeReconcileDaily (Auckland 03:45) model-version / missing /
//                                drifted entries, today's silver (birthdays),
//                                orphans — bounded, idempotent
//   leaderboardPublicPublisher   hourly: raw/age public snapshots and the
//                                age boards' counts (bounded reads)
//   publicLeaderboard            anonymous GET: ONE snapshot read, cached briefly
//
// ── Privacy ─────────────────────────────────────────────────────────────────
// The birth date is read with a field mask (users/{uid}.dob only) and never
// copied anywhere. Age entries carry only the minimal public identity already
// on the raw entry, the adjusted points, the model version and completeness.
// Public snapshots carry only the raw schema-1 or age schema-2 allowlist.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onRequest } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const age = require('./age');
const feed = require('./public_feed');
const { ALL_TIME_PERIOD, isMonthPeriod } = require('./reducer');
const { isLeaderboardEligibleUid } = require('./eligibility');
const { canonicalJson } = require('../showcase/store');
const { localDateKey } = require('../coach/coverage');

const AGE_COLLECTION = 'leaderboardsAge';
const PUBLIC_COLLECTION = 'leaderboardPublic';
const TZ = 'Pacific/Auckland';
const MEDALS_COLLECTION = 'leaderboardMedals';

function db() {
  return admin.firestore();
}
function rawEntryRef(periodKey, uid) {
  return db().collection('leaderboards').doc(periodKey).collection('entries').doc(uid);
}
function ageBoardRef(periodKey) {
  return db().collection(AGE_COLLECTION).doc(periodKey);
}
function ageEntryRef(periodKey, uid) {
  return ageBoardRef(periodKey).collection('entries').doc(uid);
}
function publicRef(periodKey) {
  return db().collection(PUBLIC_COLLECTION).doc(periodKey);
}
function serverTime() {
  return admin.firestore.FieldValue.serverTimestamp();
}

/** Today's Auckland date key and month key. */
function today(nowMs) {
  const d = localDateKey(new Date(nowMs || Date.now()), TZ);
  return { todayKey: d, monthKey: d.slice(0, 7) };
}

/** The boards the age view and silver cover: the current month and all time. */
function liveBoards(nowMs) {
  return [today(nowMs).monthKey, ALL_TIME_PERIOD];
}

/**
 * The age entry for [uid] on [periodKey] (pure). [raw] is the raw entry,
 * [result] the age.adjust* result. Only fields the app needs.
 */
function ageEntryDoc(uid, periodKey, raw, result, silver) {
  const complete = !!(result && result.complete);
  return {
    uid,
    periodKey,
    username: typeof raw.username === 'string' ? raw.username : null,
    photoURL: typeof raw.photoURL === 'string' ? raw.photoURL : null,
    ageModelVersion: age.AGE_MODEL_VERSION,
    leaderboardFormulaVersion: raw.formulaVersion || null,
    ageComplete: complete,
    adjustedTotalUnits: complete ? result.totalUnits : null,
    adjustedCategoryUnits: complete ? result.categoryUnits : null,
    rawTotalPointsUnits: raw.totalPointsUnits,
    tieBreakDateKey: raw.tieBreakDateKey || null,
    silverEligible: !!silver,
  };
}

function withoutStamps(doc) {
  if (!doc) return null;
  const copy = Object.assign({}, doc);
  delete copy.updatedAt;
  return copy;
}

/** The private birth date of [uid] (field mask: nothing else is read). */
async function readDob(reader, uid) {
  const [snap] = await reader.getAll(db().collection('users').doc(uid), { fieldMask: ['dob'] });
  return snap && snap.exists ? snap.get('dob') : undefined;
}

/**
 * Recomputes ONE athlete's age entry and silver flag on ONE live board, in a
 * transaction (it reads the CURRENT raw entry, so duplicate, retried or
 * out-of-order deliveries converge). No-op when nothing changed.
 * Returns 'set' | 'unchanged' | 'deleted' | 'skipped'.
 */
async function recomputeAthleteBoard(uid, periodKey, nowMs) {
  if (periodKey !== ALL_TIME_PERIOD && !isMonthPeriod(periodKey)) return 'skipped';
  const { todayKey } = today(nowMs);
  return db().runTransaction(async (tx) => {
    const reader = { getAll: (...a) => tx.getAll(...a) };
    const [rawSnap, ageSnap] = await tx.getAll(rawEntryRef(periodKey, uid), ageEntryRef(periodKey, uid));
    const raw = rawSnap.exists ? rawSnap.data() : null;
    const prev = ageSnap.exists ? ageSnap.data() : null;
    const board = ageBoardRef(periodKey);
    if (!raw || !isLeaderboardEligibleUid(uid) || !Number.isSafeInteger(raw.totalPointsUnits) || raw.totalPointsUnits <= 0) {
      if (prev) tx.delete(ageEntryRef(periodKey, uid));
      if (prev && prev.silverEligible) {
        tx.set(board, { silverUids: admin.firestore.FieldValue.arrayRemove(uid) }, { merge: true });
      }
      return prev ? 'deleted' : 'unchanged';
    }
    const dob = await readDob(reader, uid);
    let result;
    if (periodKey === ALL_TIME_PERIOD) {
      result = age.adjustAllTime(raw, dob, todayKey);
    } else {
      const days = await tx.get(db().collection('users').doc(uid).collection('rePointDays').where('periodKey', '==', periodKey));
      result = age.adjustMonth(Object.assign({ periodKey }, raw), days.docs.map((d) => d.data()), dob, todayKey);
    }
    const silver = age.silverEligible(dob, todayKey, periodKey, raw.totalPointsUnits);
    const next = ageEntryDoc(uid, periodKey, raw, result, silver);
    if (prev && canonicalJson(withoutStamps(prev)) === canonicalJson(next)) return 'unchanged';
    tx.set(ageEntryRef(periodKey, uid), Object.assign({}, next, { updatedAt: serverTime() }));
    if (!prev || !!prev.silverEligible !== silver) {
      tx.set(
        board,
        {
          periodKey,
          ageModelVersion: age.AGE_MODEL_VERSION,
          silverUids: silver ? admin.firestore.FieldValue.arrayUnion(uid) : admin.firestore.FieldValue.arrayRemove(uid),
        },
        { merge: true },
      );
    }
    return 'set';
  });
}

/** Both live boards of one athlete (birth-date correction, reconciliation). */
async function refreshAthleteAge(uid, reason, nowMs) {
  const out = {};
  for (const p of liveBoards(nowMs)) out[p] = await recomputeAthleteBoard(uid, p, nowMs);
  logger.info('leaderboard age refresh', { uid, reason, out });
  return out;
}

/** Raw-entry fields the age entry depends on. */
const RELEVANT = ['totalPointsUnits', 'categoryBestUnits', 'categoryDateKeys', 'categoryTotalsUnits', 'tieBreakDateKey', 'formulaVersion', 'username', 'photoURL'];

/** Whether a raw entry write can change the age entry (pure). */
function rawWriteMatters(before, after) {
  if (!before !== !after) return true;
  if (!before && !after) return false;
  return RELEVANT.some((k) => canonicalJson(before[k] === undefined ? null : before[k]) !== canonicalJson(after[k] === undefined ? null : after[k]));
}

/**
 * Every raw entry write of the CURRENT month or all time reaches the age
 * projection here. Writes that change none of its inputs return before any
 * read; closed months are never projected.
 */
const leaderboardAgeOnEntryWrite = onDocumentWritten(
  { document: 'leaderboards/{periodKey}/entries/{uid}', retry: true, maxInstances: 10 },
  async (event) => {
    const { periodKey, uid } = event.params;
    if (!liveBoards().includes(periodKey)) return;
    const side = (s) => (s && s.exists ? s.data() : null);
    if (!rawWriteMatters(side(event.data && event.data.before), side(event.data && event.data.after))) return;
    try {
      await recomputeAthleteBoard(uid, periodKey);
    } catch (err) {
      logger.error('leaderboardAgeOnEntryWrite failed', { periodKey, uid, error: err });
      throw err;
    }
  },
);

/**
 * The daily age reconciliation for the live boards (pure control loop with
 * injected I/O, so its bounds are unit-tested). For each board it recomputes
 * every athlete whose age entry is missing, from another model version, out
 * of step with the raw entry, or whose silver may have changed today (raw
 * total above the threshold), and deletes age entries without a raw entry.
 */
async function runAgeReconciliation(deps, limits) {
  const L = Object.assign({ maxPerBoard: 5000 }, limits || {});
  const counts = { checked: 0, recomputed: 0, deleted: 0, failed: 0 };
  const failures = [];
  for (const p of deps.boards()) {
    const raw = await deps.listRawEntries(p, L.maxPerBoard);
    const ages = await deps.listAgeEntries(p, L.maxPerBoard);
    const ageByUid = new Map(ages.map((a) => [a.uid, a]));
    const rawUids = new Set();
    for (const r of raw) {
      rawUids.add(r.uid);
      counts.checked += 1;
      const a = ageByUid.get(r.uid);
      const threshold = p === ALL_TIME_PERIOD ? age.SILVER_ALL_TIME_UNITS : age.SILVER_MONTH_UNITS;
      const due = !a ||
        a.ageModelVersion !== age.AGE_MODEL_VERSION ||
        a.rawTotalPointsUnits !== r.totalPointsUnits ||
        (a.tieBreakDateKey || null) !== (r.tieBreakDateKey || null) ||
        (a.leaderboardFormulaVersion || null) !== (r.formulaVersion || null) ||
        r.totalPointsUnits > threshold;
      if (!due) continue;
      try {
        const res = await deps.recompute(r.uid, p);
        if (res === 'set') counts.recomputed += 1;
      } catch (err) {
        counts.failed += 1;
        if (failures.length < 20) failures.push({ periodKey: p, uid: r.uid, error: String(err && err.message) });
      }
    }
    for (const a of ages) {
      if (rawUids.has(a.uid)) continue;
      try {
        await deps.recompute(a.uid, p); // deletes: no raw entry
        counts.deleted += 1;
      } catch (err) {
        counts.failed += 1;
        if (failures.length < 20) failures.push({ periodKey: p, uid: a.uid, error: String(err && err.message) });
      }
    }
  }
  return { counts, failures };
}

async function listRawEntries(periodKey, limit) {
  const q = await db().collection('leaderboards').doc(periodKey).collection('entries')
    .where('totalPointsUnits', '>', 0).limit(limit).get();
  return q.docs.map((d) => Object.assign({}, d.data(), { uid: d.id })).filter((e) => isLeaderboardEligibleUid(e.uid));
}

async function listAgeEntries(periodKey, limit) {
  const q = await ageBoardRef(periodKey).collection('entries').limit(limit).get();
  return q.docs.map((d) => Object.assign({}, d.data(), { uid: d.id }));
}

const leaderboardAgeReconcileDaily = onSchedule(
  { schedule: 'every day 03:45', timeZone: TZ, retryCount: 1, timeoutSeconds: 540, maxInstances: 1 },
  async () => {
    const nowMs = Date.now();
    const { counts, failures } = await runAgeReconciliation({
      boards: () => liveBoards(nowMs),
      listRawEntries,
      listAgeEntries,
      recompute: (uid, p) => recomputeAthleteBoard(uid, p, nowMs),
    });
    logger.info('leaderboard age reconciliation', counts);
    if (failures.length) logger.warn('leaderboard age reconciliation failures', { failures });
  },
);

// ── Public website feed ───────────────────────────────────────────────────

/** The raw top 20 in the app's exact server order (same composite index). */
async function rawTop(periodKey) {
  const q = await db().collection('leaderboards').doc(periodKey).collection('entries')
    .where('totalPointsUnits', '>', 0)
    .orderBy('totalPointsUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid')
    .limit(feed.PUBLIC_MAX_ROWS + 5)
    .get();
  return q.docs.map((d) => Object.assign({}, d.data(), { uid: (d.data() || {}).uid || d.id }));
}

/** Same complete, current-model age query as the app, across ALL athletes. */
async function ageTop(periodKey) {
  const q = await ageBoardRef(periodKey).collection('entries')
    .where('ageModelVersion', '==', age.AGE_MODEL_VERSION).where('ageComplete', '==', true)
    .orderBy('adjustedTotalUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid')
    .limit(feed.PUBLIC_MAX_ROWS + 5).get();
  return q.docs.map((d) => Object.assign({}, d.data(), { uid: d.id }));
}

/**
 * Publishes raw and age snapshots and refreshes the age board's counts.
 * Bounded: two ≤25-entry queries, 1 medal snapshot, 1 age board, ≤40 usernames,
 * 2 count aggregations, 3 writes. Row no-op: an unchanged board only has
 * its freshness (generatedAt) refreshed.
 */
async function publishBoard(periodKey, nowMs) {
  const [raws, adjusted] = await Promise.all([rawTop(periodKey), ageTop(periodKey)]);
  const top = raws.filter((e) => isLeaderboardEligibleUid(e.uid)).slice(0, feed.PUBLIC_MAX_ROWS);
  const ageEntries = adjusted.filter((e) => isLeaderboardEligibleUid(e.uid)).slice(0, feed.PUBLIC_MAX_ROWS);
  const ageKey = feed.snapshotKeyFor(periodKey === ALL_TIME_PERIOD ? 'all_time' : 'current', periodKey, 'age');
  const [medalSnap, boardSnap, prevSnap, prevAgeSnap] = await db().getAll(
    db().collection(MEDALS_COLLECTION).doc(periodKey), ageBoardRef(periodKey), publicRef(periodKey), publicRef(ageKey));
  const profiles = new Map();
  const uids = [...new Set([...top, ...ageEntries].map((e) => e.uid))];
  if (uids.length) {
    const snaps = await db().getAll(...uids.map((uid) => db().collection('users_public').doc(uid)), { fieldMask: ['username'] });
    for (const s of snaps) profiles.set(s.id, s.exists ? { username: s.get('username') } : null);
  }
  const board = boardSnap.exists ? boardSnap.data() : {};
  const silverUids = board.ageModelVersion === age.AGE_MODEL_VERSION && Array.isArray(board.silverUids) ? board.silverUids : [];
  const generatedAt = new Date(nowMs || Date.now()).toISOString();
  const next = feed.buildPublicSnapshot({
    periodKey,
    rawEntries: top,
    publicProfiles: profiles,
    medalSnapshot: medalSnap.exists ? medalSnap.data() : null,
    silverUids: new Set(silverUids),
    generatedAt,
    isEligible: isLeaderboardEligibleUid,
  });
  const prev = prevSnap.exists ? prevSnap.data() : null;
  const unchanged = prev && feed.rowsFingerprint(prev) === feed.rowsFingerprint(next) && prev.periodKey === periodKey;

  // The age board's counts (the app's "N athletes aren't ranked in this view").
  const col = ageBoardRef(periodKey).collection('entries').where('ageModelVersion', '==', age.AGE_MODEL_VERSION);
  const [ranked, incomplete] = await Promise.all([
    col.where('ageComplete', '==', true).count().get(),
    col.where('ageComplete', '==', false).count().get(),
  ]);
  const nextAge = feed.buildPublicAgeSnapshot({
    periodKey, ageEntries, publicProfiles: profiles,
    medalSnapshot: medalSnap.exists ? medalSnap.data() : null, generatedAt,
    ageModelVersion: age.AGE_MODEL_VERSION, rankedCount: ranked.data().count,
    incompleteCount: incomplete.data().count, isEligible: isLeaderboardEligibleUid,
  });
  const prevAge = prevAgeSnap.exists ? prevAgeSnap.data() : null;
  const ageUnchanged = prevAge && prevAge.schemaVersion === feed.PUBLIC_AGE_SCHEMA_VERSION && prevAge.view === 'age' &&
    prevAge.periodKey === periodKey && prevAge.ageModelVersion === age.AGE_MODEL_VERSION &&
    prevAge.rankedCount === nextAge.rankedCount && prevAge.incompleteCount === nextAge.incompleteCount &&
    feed.rowsFingerprint(prevAge) === feed.rowsFingerprint(nextAge);
  const batch = db().batch();
  if (unchanged) batch.update(publicRef(periodKey), { generatedAt });
  else batch.set(publicRef(periodKey), next);
  if (ageUnchanged) batch.update(publicRef(ageKey), { generatedAt });
  else batch.set(publicRef(ageKey), nextAge);
  batch.set(ageBoardRef(periodKey), {
    periodKey,
    ageModelVersion: age.AGE_MODEL_VERSION,
    rankedCount: ranked.data().count,
    incompleteCount: incomplete.data().count,
    countsUpdatedAt: serverTime(),
  }, { merge: true });
  await batch.commit();
  return { periodKey, rows: next.entries.length, changed: !unchanged,
    ageRows: nextAge.entries.length, ageChanged: !ageUnchanged };
}

/** Both live boards (current Auckland month — rollover included — and all time). */
async function publishAll(nowMs) {
  const out = [];
  for (const p of liveBoards(nowMs)) out.push(await publishBoard(p, nowMs));
  return out;
}

const leaderboardPublicPublisher = onSchedule(
  { schedule: '0 * * * *', timeZone: TZ, retryCount: 0, timeoutSeconds: 15,
    minInstances: 0, maxInstances: 1, memory: '256MiB', cpu: 'gcf_gen1', concurrency: 1 },
  async () => {
    const res = await publishAll(Date.now());
    logger.debug('leaderboard public snapshots', { res });
  },
);

/** A snapshot older than this is not served (the publisher has stopped). */
// An hourly snapshot has grace for a delayed cycle; never serve it indefinitely.
const MAX_SNAPSHOT_AGE_MS = 150 * 60 * 1000;
const CACHE_MS = 60 * 60 * 1000;
const cache = new Map(); // key -> { atMs, body }

function sendJson(res, status, body, cacheControl, head) {
  res.status(status);
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('Cache-Control', cacheControl);
  res.set('Referrer-Policy', 'no-referrer');
  if (head) res.end();
  else res.send(JSON.stringify(body));
}

/** The public request handler (exported for tests). */
async function handlePublicRequest(req, res, deps) {
  const d = deps || {};
  const nowMs = d.nowMs ? d.nowMs() : Date.now();
  const url = String(req.originalUrl || req.url || '');
  const qi = url.indexOf('?');
  const parsed = feed.parsePublicRequest(req.method, qi >= 0 ? url.slice(qi + 1) : '');
  const head = req.method === 'HEAD';
  if (parsed.error) {
    if (parsed.status === 405) res.set('Allow', 'GET, HEAD');
    return sendJson(res, parsed.status, { error: parsed.error }, 'no-store', head);
  }
  const periodKey = feed.snapshotKeyFor(parsed.period, today(nowMs).monthKey);
  const key = feed.snapshotKeyFor(parsed.period, today(nowMs).monthKey, parsed.view || 'raw');
  const unavailable = () => sendJson(res, 503, { error: 'leaderboard-unavailable' }, 'no-store', head);
  if (!key) return unavailable();
  let body = null;
  const hit = cache.get(key);
  if (hit && nowMs - hit.atMs < CACHE_MS && nowMs - Date.parse(hit.body.generatedAt) <= MAX_SNAPSHOT_AGE_MS) {
    body = hit.body;
  } else {
    try {
      const stored = d.readSnapshot ? await d.readSnapshot(key) : (await publicRef(key).get()).data();
      body = parsed.view === 'age' ? feed.sanitizeAgeSnapshot(stored, periodKey, age.AGE_MODEL_VERSION)
        : feed.sanitizeSnapshot(stored, periodKey);
      if (body && nowMs - Date.parse(body.generatedAt) > MAX_SNAPSHOT_AGE_MS) body = null;
    } catch (err) {
      logger.warn('publicLeaderboard read failed', { key, error: String(err && err.message) });
      body = null;
    }
    if (body) cache.set(key, { atMs: nowMs, body });
  }
  // Check freshness on cache hits too: a long cache cannot extend validity.
  if (!body || nowMs - Date.parse(body.generatedAt) > MAX_SNAPSHOT_AGE_MS) return unavailable();
  return sendJson(res, 200, body, 'public, max-age=3600, s-maxage=3600', head);
}

const publicLeaderboard = onRequest(
  { region: 'us-central1', invoker: 'public', minInstances: 0, maxInstances: 1,
    concurrency: 1, cpu: 'gcf_gen1', memory: '256MiB', timeoutSeconds: 5 },
  (req, res) => handlePublicRequest(req, res).catch(() => {
    if (!res.headersSent) sendJson(res, 503, { error: 'leaderboard-unavailable' }, 'no-store', req.method === 'HEAD');
  }),
);

module.exports = {
  AGE_COLLECTION,
  PUBLIC_COLLECTION,
  ageEntryDoc,
  rawWriteMatters,
  recomputeAthleteBoard,
  refreshAthleteAge,
  runAgeReconciliation,
  publishBoard,
  publishAll,
  handlePublicRequest,
  leaderboardAgeOnEntryWrite,
  leaderboardAgeReconcileDaily,
  leaderboardPublicPublisher,
  publicLeaderboard,
  liveBoards,
  ageBoardRef,
  ageEntryRef,
  publicRef,
};
