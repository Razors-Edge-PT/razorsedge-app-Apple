#!/usr/bin/env node
'use strict';

// One-time backfill of the leaderboard category medals.
//
// 1. Every existing leaderboard entry (every month, all time) gains the two
//    ADDITIVE medal fields the reducer now writes — categoryDateKeys and
//    medalRankKeys — recomputed from the same sources the triggers use:
//      month     users/{uid}/rePointDays of that month (monthEntryFromDays)
//      all time  users_public/{uid}.profileShowcaseV2 (allTimeEntryFromSnapshot)
//    Only those two fields are written (field update); username, photoURL,
//    totals and every other field are left exactly as they are. An entry whose
//    stored scores no longer match its sources is NOT patched: it is reported
//    as drift for the existing reconciliation to rebuild.
// 2. Every board's snapshot leaderboardMedals/{periodKey} is refreshed by the
//    SAME transactional refresh the trigger runs (medals_firestore.js).
//
// SAFETY CONTRACT
//   * Dry run by default; --apply writes; --verify only reads.
//   * Project guard: goodlift-us-storage only (or the emulator).
//   * Never reads or writes a workout except in --verify, which only reads.
//     Never touches users/{uid}, users_public, rePointDays or showcase data.
//   * Idempotent: fields are recomputed and set, never incremented; a
//     snapshot is rewritten only when its awards differ.
//   * Resumable: finished boards are recorded in
//     migrations/leaderboardMedalsBackfill/progress/{periodKey} (--force redoes).
//   * Paged: entries are listed 300 at a time.
//
// --verify recomputes every athlete who holds an entry FROM THEIR WORKOUTS
// (showcase/rebuild_dry_run: the worker's own job and reducers, in memory),
// allocates every board by a full sort of those recomputed scores — not the
// podium queries — and compares the result with each published snapshot.
//
//   node scripts/backfill_leaderboard_medals.js                 (dry run)
//   node scripts/backfill_leaderboard_medals.js --apply
//   node scripts/backfill_leaderboard_medals.js --verify

const PROJECT_ID = 'goodlift-us-storage';
const PROGRESS_DOC = 'migrations/leaderboardMedalsBackfill';
const PAGE = 300;

function parseArgs(argv) {
  const out = { projectId: PROJECT_ID, apply: false, verify: false, force: false, period: null, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--force') out.force = true;
    else if (arg === '--period') out.period = argv[++i] || null;
    else if (arg === '--project') out.projectId = argv[++i] || null;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  if (out.period !== null && !/^(\d{4}-\d{2}|all_time)$/.test(out.period)) throw new Error('--period must be YYYY-MM or all_time');
  return out;
}

/** Refuses any project but production, except against the emulator. */
function assertProject(projectId, env) {
  const e = env || process.env;
  if (e.FIRESTORE_EMULATOR_HOST) return;
  if (projectId !== PROJECT_ID) throw new Error(`Refusing: project must be exactly ${PROJECT_ID}`);
}

// ── Pure planning (unit-tested) ─────────────────────────────────────────────

const { CATEGORY_KEYS, allocateMedals, categoryUnitsOf, awardsFingerprint, PLACES } = require('../leaderboard/medals');
const {
  ALL_TIME_PERIOD,
  LEADERBOARD_FORMULA_VERSION,
  monthEntryFromDays,
  allTimeEntryFromSnapshot,
} = require('../leaderboard/reducer');

const canon = (v) => JSON.stringify(v, Object.keys(v || {}).sort());

/**
 * What to do with one stored entry given the entry its sources produce now.
 * Returns { action: 'patch' | 'ok' | 'drift' | 'missingTotals' | 'stale', patch?, reason? }.
 */
function planEntry(stored, source) {
  if (!stored) return { action: 'ok' };
  const allTime = stored.periodKey === ALL_TIME_PERIOD;
  const unitsField = allTime ? 'categoryBestUnits' : 'categoryTotalsUnits';
  if (!stored[unitsField] || typeof stored[unitsField] !== 'object') return { action: 'missingTotals', reason: `no ${unitsField}` };
  if (stored.formulaVersion !== LEADERBOARD_FORMULA_VERSION) return { action: 'stale', reason: `formula ${stored.formulaVersion}` };
  if (!source) return { action: 'drift', reason: 'sources produce no entry' };
  const scoresMatch =
    stored.totalPointsUnits === source.totalPointsUnits &&
    CATEGORY_KEYS.every((k) => (stored[unitsField][k] || 0) === (source[unitsField][k] || 0));
  if (!scoresMatch) return { action: 'drift', reason: 'stored scores differ from sources' };
  const patch = { categoryDateKeys: source.categoryDateKeys, medalRankKeys: source.medalRankKeys };
  if (canon(stored.categoryDateKeys) === canon(patch.categoryDateKeys) && canon(stored.medalRankKeys) === canon(patch.medalRankKeys)) {
    return { action: 'ok' };
  }
  return { action: 'patch', patch };
}

/** The source entry for a stored one: from month day docs or the public profile. */
function sourceEntry(uid, periodKey, { dayDocs, publicData, identity }) {
  if (periodKey === ALL_TIME_PERIOD) {
    const res = allTimeEntryFromSnapshot(uid, publicData && publicData.profileShowcaseV2, publicData);
    return res.stale ? null : res.entry;
  }
  return monthEntryFromDays(uid, periodKey, dayDocs || [], identity);
}

/**
 * The board allocation from a FULL list of entries (independent of the
 * podium queries): every current-formula entry with a positive score.
 */
function allocateFromEntries(periodKey, entries) {
  const current = (entries || []).filter((e) => e && e.formulaVersion === LEADERBOARD_FORMULA_VERSION);
  const byCat = {};
  for (const k of CATEGORY_KEYS) byCat[k] = current;
  return allocateMedals(byCat, { allTime: periodKey === ALL_TIME_PERIOD });
}

/** Per category, how many entries are eligible (positive score). */
function eligibleCounts(entries) {
  const out = {};
  for (const k of CATEGORY_KEYS) {
    out[k] = (entries || []).filter((e) => e && e.formulaVersion === LEADERBOARD_FORMULA_VERSION && Number.isSafeInteger(categoryUnitsOf(e)[k]) && categoryUnitsOf(e)[k] > 0).length;
  }
  return out;
}

// ── Firestore run ───────────────────────────────────────────────────────────

async function listAll(query) {
  const admin = require('firebase-admin');
  const out = [];
  let last = null;
  for (;;) {
    let q = query.orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE);
    if (last) q = q.startAfter(last);
    const page = await q.get();
    out.push(...page.docs);
    if (page.size < PAGE) break;
    last = page.docs[page.docs.length - 1];
  }
  return out;
}

function fmtPts(units) {
  return (units / 10000).toFixed(2);
}

async function run(options, out) {
  const w = out || ((s) => process.stdout.write(`${s}\n`));
  const admin = require('firebase-admin');
  const db = admin.firestore();
  const medalsFs = require('../leaderboard/medals_firestore');
  const mode = options.apply ? 'apply' : options.verify ? 'verify' : 'dry-run';
  const counts = {
    boards: 0, entries: 0, patch: 0, ok: 0, drift: 0, missingTotals: 0, stale: 0,
    patched: 0, snapshotsCreate: 0, snapshotsUpdate: 0, snapshotsUnchanged: 0, snapshotsWritten: 0,
    boardsSkippedDone: 0, reads: 0, writesEstimate: 0, verifyMismatches: 0,
  };
  const problems = [];
  w(`Leaderboard medal backfill — mode: ${mode}`);
  w(`Project: ${options.projectId}   Formula: ${LEADERBOARD_FORMULA_VERSION}\n`);

  const periodDocs = options.period
    ? [await db.collection('leaderboards').doc(options.period).get()].filter((d) => d.exists)
    : (await db.collection('leaderboards').get()).docs;
  counts.reads += Math.max(1, periodDocs.length);
  const periods = periodDocs.map((d) => d.id).sort();
  counts.boards = periods.length;
  w(`Boards discovered: ${periods.length} (${periods.join(', ')})`);

  const progressCol = db.doc(PROGRESS_DOC).collection('progress');
  const pubCache = new Map();
  async function publicOf(uid) {
    if (!pubCache.has(uid)) {
      const s = await db.collection('users_public').doc(uid).get();
      counts.reads += 1;
      pubCache.set(uid, s.exists ? s.data() : null);
    }
    return pubCache.get(uid);
  }

  const liveByPeriod = new Map();
  for (const p of periods) {
    const docs = await listAll(db.collection('leaderboards').doc(p).collection('entries'));
    counts.reads += Math.max(1, docs.length);
    const live = docs.map((d) => Object.assign({ uid: d.id }, d.data()));
    liveByPeriod.set(p, live);
    counts.entries += live.length;
  }

  if (options.verify) return verify({ db, periods, liveByPeriod, counts, problems, w, medalsFs });

  for (const p of periods) {
    if (options.apply && !options.force) {
      const done = await progressCol.doc(p).get();
      counts.reads += 1;
      if (done.exists && (done.data() || {}).status === 'done') {
        counts.boardsSkippedDone += 1;
        continue;
      }
    }
    const planned = [];
    for (const e of liveByPeriod.get(p)) {
      let src;
      if (p === ALL_TIME_PERIOD) {
        src = sourceEntry(e.uid, p, { publicData: await publicOf(e.uid) });
      } else {
        const days = await db.collection('users').doc(e.uid).collection('rePointDays').where('periodKey', '==', p).get();
        counts.reads += Math.max(1, days.size);
        src = sourceEntry(e.uid, p, { dayDocs: days.docs.map((d) => d.data()), identity: e });
      }
      const plan = planEntry(e, src);
      counts[plan.action] += 1;
      if (plan.action !== 'ok' && plan.action !== 'patch') problems.push(`${p}/${e.uid}: ${plan.action} (${plan.reason})`);
      planned.push({ e, plan, next: plan.action === 'patch' ? Object.assign({}, e, plan.patch) : e });
    }
    const board = allocateFromEntries(p, planned.map((x) => x.next));
    const snap = await medalsFs.medalsRef(p).get();
    counts.reads += 1;
    const prev = snap.exists ? snap.data() : null;
    const changed = !prev || prev.formulaVersion !== LEADERBOARD_FORMULA_VERSION || awardsFingerprint(prev.categories) !== awardsFingerprint(board);
    if (!prev) counts.snapshotsCreate += 1;
    else if (changed) counts.snapshotsUpdate += 1;
    else counts.snapshotsUnchanged += 1;
    counts.writesEstimate += planned.filter((x) => x.plan.action === 'patch').length + (changed ? 1 : 0);

    const eligible = eligibleCounts(planned.map((x) => x.next));
    w(`\n── ${p} ── entries ${planned.length}; to patch ${planned.filter((x) => x.plan.action === 'patch').length}; snapshot ${!prev ? 'CREATE' : changed ? 'UPDATE' : 'unchanged'}`);
    for (const k of CATEGORY_KEYS) {
      const ws = board[k].map((x) => `${['G', 'S', 'B'][x.place - 1]} ${x.uid} ${fmtPts(x.pointsUnits)} (${x.achievedDateKey})`).join(' | ');
      w(`  ${k.padEnd(15)} eligible ${String(eligible[k]).padStart(3)}${eligible[k] < PLACES ? ' (<3)' : '     '}  ${ws || '—'}`);
    }

    if (!options.apply) continue;
    for (const x of planned) {
      if (x.plan.action !== 'patch') continue;
      const ref = db.collection('leaderboards').doc(p).collection('entries').doc(x.e.uid);
      const res = await db.runTransaction(async (tx) => {
        const cur = await tx.get(ref);
        if (!cur.exists) return 'gone';
        const stored = Object.assign({ uid: x.e.uid }, cur.data());
        let src;
        if (p === ALL_TIME_PERIOD) {
          const pub = await tx.get(db.collection('users_public').doc(x.e.uid));
          src = sourceEntry(x.e.uid, p, { publicData: pub.exists ? pub.data() : null });
        } else {
          const days = await tx.get(db.collection('users').doc(x.e.uid).collection('rePointDays').where('periodKey', '==', p));
          src = sourceEntry(x.e.uid, p, { dayDocs: days.docs.map((d) => d.data()), identity: stored });
        }
        const plan = planEntry(stored, src);
        if (plan.action !== 'patch') return plan.action;
        tx.update(ref, plan.patch);
        return 'patched';
      });
      if (res === 'patched') counts.patched += 1;
      else if (res !== 'ok') problems.push(`${p}/${x.e.uid}: at apply ${res}`);
    }
    const r = await medalsFs.refreshMedals(p);
    if (r.path === 'written') counts.snapshotsWritten += 1;
    await progressCol.doc(p).set({ status: 'done', at: admin.firestore.FieldValue.serverTimestamp(), revision: r.revision || null });
  }
  report(counts, problems, w, options);
  return { counts, problems };
}

async function verify({ db, periods, liveByPeriod, counts, problems, w, medalsFs }) {
  const { dryRunUser } = require('../showcase/rebuild_dry_run');
  const showcaseFs = require('../showcase/firestore_store');
  const uids = new Set();
  for (const list of liveByPeriod.values()) for (const e of list) uids.add(e.uid);
  w(`\nRecomputing ${uids.size} athletes from their workouts…`);
  const recomputed = new Map(); // `${p}/${uid}` → entry
  for (const uid of [...uids].sort()) {
    const res = await dryRunUser(db, uid, showcaseFs.bodyweightResolver);
    counts.reads += res.workoutDays + 3;
    for (const [k, v] of res.entries) recomputed.set(k, v);
  }
  for (const p of periods) {
    const live = liveByPeriod.get(p);
    const members = live.map((e) => recomputed.get(`${p}/${e.uid}`)).filter(Boolean);
    for (const e of live) {
      const r = recomputed.get(`${p}/${e.uid}`);
      const fields = ['categoryDateKeys', 'medalRankKeys'];
      if (!r) {
        problems.push(`${p}/${e.uid}: live entry but workouts recompute none`);
        continue;
      }
      for (const f of fields) {
        if (canon(e[f]) !== canon(r[f])) problems.push(`${p}/${e.uid}: ${f} differs from recomputation`);
      }
    }
    const expected = allocateFromEntries(p, members);
    const snap = await medalsFs.medalsRef(p).get();
    counts.reads += 1;
    const pub = snap.exists ? snap.data() : null;
    const ok = pub && pub.formulaVersion === LEADERBOARD_FORMULA_VERSION && awardsFingerprint(pub.categories) === awardsFingerprint(expected);
    if (!ok) {
      counts.verifyMismatches += 1;
      problems.push(`${p}: snapshot ${pub ? 'differs from' : 'missing vs'} independent recomputation`);
    }
    const n = CATEGORY_KEYS.reduce((s, k) => s + expected[k].length, 0);
    w(`  ${p.padEnd(9)} ${ok ? 'OK      ' : 'MISMATCH'} medals ${String(n).padStart(2)}  revision ${pub ? pub.revision : '—'}`);
  }
  const dirty = await db.collection('leaderboardMedalQueue').limit(20).get();
  const recalc = await db.collection('leaderboardRecalcQueue').limit(20).get();
  const jobs = await db.collection('profileRebuildJobs').where('status', 'in', ['queued', 'running', 'error']).limit(20).get();
  counts.reads += 3 + dirty.size + recalc.size + jobs.size;
  if (!dirty.empty) problems.push(`dirty medal boards: ${dirty.docs.map((d) => d.id).join(', ')}`);
  w(`\nDirty medal boards: ${dirty.size}   Recalc queue items: ${recalc.size}   Active/failed rebuild jobs: ${jobs.size}`);
  if (!recalc.empty) w(`  recalc queue: ${recalc.docs.map((d) => d.id).join(', ')}`);
  if (!jobs.empty) w(`  jobs: ${jobs.docs.map((d) => `${d.id}(${d.get('status')})`).join(', ')}`);
  report(counts, problems, w, { verify: true });
  w(problems.length ? '\nVerification: PROBLEMS' : '\nVerification: CLEAN');
  return { counts, problems };
}

function report(counts, problems, w, options) {
  w('\nCOUNTS');
  for (const [k, v] of Object.entries(counts)) w(`  ${k}: ${v}`);
  if (problems.length) {
    w('\nPROBLEMS');
    for (const p of problems.slice(0, 200)) w(`  ${p}`);
  }
  if (!options.apply && !options.verify) w('\nDry run only. Re-run with --apply to write.');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write('node scripts/backfill_leaderboard_medals.js [--apply | --verify] [--period P] [--force]\n');
    return 0;
  }
  assertProject(options.projectId);
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId });
  const { problems } = await run(options);
  return problems.length ? 1 : 0;
}

module.exports = { parseArgs, assertProject, planEntry, sourceEntry, allocateFromEntries, eligibleCounts, run };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nMedal backfill failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
