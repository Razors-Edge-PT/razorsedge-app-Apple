#!/usr/bin/env node
'use strict';

// Backfill of the monthly medal detail's exercise breakdown for the CURRENT
// month only: every existing entry of leaderboards/{YYYY-MM}/entries gains
// categoryExerciseBreakdown, recomputed by the same reducer the triggers use
// (monthEntryFromDays) from that athlete's rePointDays of the month.
//
// SAFETY CONTRACT
//   * Dry run by default; --apply writes; --verify only reads.
//   * Project guard: goodlift-us-storage only (or the emulator).
//   * Current month only: any other --period (all time, a closed month) is
//     refused.
//   * Writes ONE field — categoryExerciseBreakdown — on existing entries of
//     that month (a field update; totals, medal keys, identity and stamps are
//     left exactly as they are). Never writes workouts, profiles, weigh-ins,
//     rePointDays, showcase data, medal snapshots or any other period.
//   * An entry whose other stored fields no longer match its sources is NOT
//     patched: it is reported as drift for the existing reconciliation.
//   * Excluded accounts are never patched (reported if an entry survived).
//   * Idempotent: an entry that already holds the recomputed breakdown is
//     left alone; each patch re-reads its sources in a transaction.
//
//   node scripts/backfill_month_exercise_breakdown.js              (dry run)
//   node scripts/backfill_month_exercise_breakdown.js --apply
//   node scripts/backfill_month_exercise_breakdown.js --verify

const PROJECT_ID = 'goodlift-us-storage';
const FIELD = 'categoryExerciseBreakdown';

const {
  CATEGORY_KEYS,
  LEADERBOARD_FORMULA_VERSION,
  isMonthPeriod,
  monthEntryFromDays,
} = require('../leaderboard/reducer');
const { isLeaderboardEligibleUid } = require('../leaderboard/eligibility');

function parseArgs(argv) {
  const out = { projectId: PROJECT_ID, apply: false, verify: false, period: null, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--period') out.period = argv[++i] || null;
    else if (arg === '--project') out.projectId = argv[++i] || null;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  return out;
}

/** Refuses any project but production, except against the emulator. */
function assertProject(projectId, env) {
  const e = env || process.env;
  if (e.FIRESTORE_EMULATOR_HOST) return;
  if (projectId !== PROJECT_ID) throw new Error(`Refusing: project must be exactly ${PROJECT_ID}`);
}

/** The only period this tool may touch: the current month. */
function assertCurrentMonth(period, current) {
  if (!isMonthPeriod(current)) throw new Error(`Bad current period ${current}`);
  if (period !== null && period !== current) {
    throw new Error(`Refusing: only the current month (${current}) may be backfilled, not ${period}`);
  }
  return current;
}

function canon(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v === undefined ? null : v);
  if (Array.isArray(v)) return `[${v.map(canon).join(',')}]`;
  return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`;
}

/** Stored fields the recomputation must reproduce before a patch is allowed. */
const SCORE_FIELDS = [
  'uid', 'periodKey', 'totalPointsUnits', 'categoryTotalsUnits', 'categoryDateKeys',
  'medalRankKeys', 'scoredDayCount', 'tieBreakDateKey', 'formulaVersion',
];

/** Whether [breakdown] reconciles exactly with [totals] (integer units). */
function breakdownMatchesTotals(breakdown, totals) {
  if (!breakdown || typeof breakdown !== 'object') return false;
  for (const k of CATEGORY_KEYS) {
    const rows = breakdown[k];
    if (!Array.isArray(rows)) return false;
    const sum = rows.reduce((s, r) => s + r.pointsUnits, 0);
    if (sum !== ((totals && totals[k]) || 0)) return false;
  }
  return true;
}

/** Distinct dates per (category, exercise) that supplied the daily winner. */
function contributingDates(dayDocs, periodKey) {
  const out = {};
  for (const k of CATEGORY_KEYS) out[k] = new Map();
  for (const d of dayDocs || []) {
    if (!d || d.periodKey !== periodKey || !(Number.isInteger(d.totalPointsUnits) && d.totalPointsUnits > 0)) continue;
    for (const k of CATEGORY_KEYS) {
      const c = d.categories && d.categories[k];
      if (!c || !Number.isInteger(c.pointsUnits) || c.pointsUnits <= 0) continue;
      const m = out[k];
      if (!m.has(c.exerciseId)) m.set(c.exerciseId, new Set());
      m.get(c.exerciseId).add(d.dateKey);
    }
  }
  return out;
}

/**
 * Pure plan for one stored entry. Returns
 *   { status: 'excluded' | 'drift' | 'ok' | 'patch', patch?, reason? }.
 */
function planEntry(uid, periodKey, stored, dayDocs, identity) {
  if (!isLeaderboardEligibleUid(uid)) return { status: 'excluded' };
  const next = monthEntryFromDays(uid, periodKey, dayDocs || [], identity);
  if (!next) return { status: 'drift', reason: 'sources produce no entry' };
  for (const f of SCORE_FIELDS) {
    if (canon(stored && stored[f]) !== canon(next[f])) return { status: 'drift', reason: `${f} differs from sources` };
  }
  const breakdown = next[FIELD];
  if (!breakdownMatchesTotals(breakdown, next.categoryTotalsUnits)) {
    return { status: 'drift', reason: 'breakdown does not reconcile with totals' };
  }
  if (canon(stored[FIELD]) === canon(breakdown)) return { status: 'ok' };
  return { status: 'patch', patch: { [FIELD]: breakdown } };
}

// ── Firestore run ───────────────────────────────────────────────────────────

function fmtPts(units) {
  return (units / 10000).toFixed(2);
}

async function run(options, out) {
  const w = out || ((s) => process.stdout.write(`${s}\n`));
  const admin = require('firebase-admin');
  const db = admin.firestore();
  const lbFs = require('../leaderboard/firestore_store');
  const periodKey = assertCurrentMonth(options.period, lbFs.currentPeriodKey());
  const mode = options.apply ? 'apply' : options.verify ? 'verify' : 'dry-run';
  const counts = {
    entries: 0, excluded: 0, drift: 0, ok: 0, patch: 0, patched: 0, raced: 0,
    verifiedTotals: 0, verifiedSessions: 0, verifyMismatches: 0, reads: 0, writesEstimate: 0,
  };
  const problems = [];
  w(`Monthly exercise-breakdown backfill — mode: ${mode}`);
  w(`Project: ${options.projectId}   Period: ${periodKey} (current month only)   Formula: ${LEADERBOARD_FORMULA_VERSION}`);
  w(`Writes (apply only): leaderboards/${periodKey}/entries/{uid}.${FIELD} — nothing else\n`);

  const entriesCol = db.collection('leaderboards').doc(periodKey).collection('entries');
  const snap = await entriesCol.get();
  counts.reads += snap.size + 1;
  const sources = async (reader, uid) => {
    const userRef = db.collection('users').doc(uid);
    const daysQ = userRef.collection('rePointDays').where('periodKey', '==', periodKey);
    const pubRef = db.collection('users_public').doc(uid);
    const [days, pub] = reader
      ? [await reader.get(daysQ), await reader.get(pubRef)]
      : [await daysQ.get(), await pubRef.get()];
    counts.reads += days.size + 1;
    return { days: days.docs.map((d) => d.data()), identity: pub.exists ? pub.data() : null };
  };

  for (const doc of snap.docs.sort((a, b) => (a.id < b.id ? -1 : 1))) {
    counts.entries += 1;
    const uid = doc.id;
    const stored = doc.data();
    const { days, identity } = await sources(null, uid);
    const plan = planEntry(uid, periodKey, stored, days, identity);
    if (options.verify) {
      const bd = stored[FIELD];
      const totalsOk = breakdownMatchesTotals(bd, stored.categoryTotalsUnits);
      const dates = contributingDates(days, periodKey);
      const sessionsOk = !!bd && CATEGORY_KEYS.every((k) => Array.isArray(bd[k]) &&
        bd[k].length === dates[k].size &&
        bd[k].every((r) => dates[k].has(r.exerciseId) && dates[k].get(r.exerciseId).size === r.sessionCount));
      if (totalsOk) counts.verifiedTotals += 1;
      if (sessionsOk) counts.verifiedSessions += 1;
      if (!isLeaderboardEligibleUid(uid)) { counts.excluded += 1; problems.push(`${uid}: excluded account holds an entry`); continue; }
      if (!totalsOk || !sessionsOk || plan.status !== 'ok') {
        counts.verifyMismatches += 1;
        problems.push(`${uid}: totals ${totalsOk ? 'ok' : 'MISMATCH'}, sessions ${sessionsOk ? 'ok' : 'MISMATCH'}, plan ${plan.status}${plan.reason ? ` (${plan.reason})` : ''}`);
      }
      continue;
    }
    counts[plan.status] += 1;
    const summary = CATEGORY_KEYS
      .filter((k) => (stored.categoryTotalsUnits || {})[k] > 0)
      .map((k) => `${k} ${fmtPts(stored.categoryTotalsUnits[k])} ← ${(plan.patch ? plan.patch[FIELD][k] : stored[FIELD] ? stored[FIELD][k] : [])
        .map((r) => `${r.displayName} ${fmtPts(r.pointsUnits)}×${r.sessionCount}`).join(', ')}`);
    w(`  ${uid}  ${plan.status.padEnd(8)}${plan.reason ? ` (${plan.reason})` : ''}`);
    for (const s of summary) w(`      ${s}`);
    if (plan.status === 'excluded') problems.push(`${uid}: excluded account holds an entry (left for the exclusion cleanup)`);
    if (plan.status === 'drift') problems.push(`${uid}: drift — ${plan.reason}`);
    if (plan.status !== 'patch') continue;
    counts.writesEstimate += 1;
    if (!options.apply) continue;
    const res = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(doc.ref);
      if (!fresh.exists) return 'gone';
      const src = await sources(tx, uid);
      const p = planEntry(uid, periodKey, fresh.data(), src.days, src.identity);
      if (p.status !== 'patch') return p.status;
      tx.update(doc.ref, p.patch);
      return 'patched';
    });
    if (res === 'patched') counts.patched += 1;
    else { counts.raced += 1; if (res !== 'ok') problems.push(`${uid}: at apply ${res}`); }
  }

  w('\nCOUNTS');
  for (const [k, v] of Object.entries(counts)) w(`  ${k}: ${v}`);
  if (problems.length) {
    w('\nPROBLEMS');
    for (const p of problems) w(`  ${p}`);
  }
  if (options.verify) w(problems.length ? '\nVerification: PROBLEMS' : '\nVerification: CLEAN');
  else if (!options.apply) w('\nDry run only. Re-run with --apply to write.');
  return { counts, problems, periodKey };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write('node scripts/backfill_month_exercise_breakdown.js [--apply | --verify] [--period YYYY-MM (current only)]\n');
    return 0;
  }
  assertProject(options.projectId);
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId });
  const { problems } = await run(options);
  return problems.length ? 1 : 0;
}

module.exports = {
  parseArgs, assertProject, assertCurrentMonth, planEntry, breakdownMatchesTotals, contributingDates, run,
};

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nBreakdown backfill failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
