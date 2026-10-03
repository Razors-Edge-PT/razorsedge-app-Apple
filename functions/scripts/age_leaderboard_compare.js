#!/usr/bin/env node
'use strict';

// READ-ONLY comparison of the raw RE Points leaderboard with the optional
// age-adjusted view (leaderboard/age.js — the SAME arithmetic the server
// projection uses), over EVERY eligible positive-scoring athlete of the
// current Auckland month and of all time — not just the raw top 20.
//
// SAFETY CONTRACT
//   * Writes nothing to Firestore. There is no apply mode.
//   * Reads only: leaderboards/{period}/entries (raw entries), the private
//     users/{uid}.dob field of those athletes, and their users/{uid}/rePointDays
//     of the current month. Never workouts or weigh-ins; RE Points are not
//     recomputed.
//   * Uses Application Default Credentials explicitly against the project.
//   * Output (owner-only analysis, NOT the public website feed) goes to an
//     ignored directory: no birth dates, no credentials; usernames are
//     neutralised against CSV formula execution.
//
//   node scripts/age_leaderboard_compare.js --project goodlift-us-storage [--out DIR]

const fs = require('fs');
const path = require('path');

const age = require('../leaderboard/age');
const { isLeaderboardEligibleUid } = require('../leaderboard/eligibility');

function parseArgs(argv) {
  const out = { projectId: 'goodlift-us-storage', out: null, maxRetries: 2 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--project') out.projectId = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    else if (a === '--help') out.help = true;
    else throw new Error(`Unknown argument ${a}`);
  }
  return out;
}

/** Neutralises spreadsheet formulas in a user-controlled cell. */
function csvCell(v) {
  if (v === null || v === undefined) return '';
  let s = String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function compareRaw(a, b) {
  const s = (x, y) => (x < y ? -1 : x > y ? 1 : 0);
  return b.totalPointsUnits - a.totalPointsUnits || s(a.tieBreakDateKey || '', b.tieBreakDateKey || '') || s(a.uid, b.uid);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log('node scripts/age_leaderboard_compare.js --project goodlift-us-storage [--out DIR]');
    return;
  }
  // eslint-disable-next-line global-require
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId, credential: admin.credential.applicationDefault() });
  const db = admin.firestore();
  // eslint-disable-next-line global-require
  const { localDateKey } = require('../coach/coverage');
  const startedAt = new Date();
  const todayKey = localDateKey(startedAt, 'Pacific/Auckland');
  const monthKey = todayKey.slice(0, 7);
  let reads = 0;

  async function rawEntries(periodKey) {
    const out = [];
    let last = null;
    for (;;) {
      let q = db.collection('leaderboards').doc(periodKey).collection('entries')
        .where('totalPointsUnits', '>', 0)
        .orderBy('totalPointsUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid')
        .limit(300);
      if (last) q = q.startAfter(last);
      const page = await q.get();
      reads += Math.max(1, page.size);
      for (const d of page.docs) out.push({ _ref: d.ref, _updateTime: d.updateTime, ...d.data(), uid: d.data().uid || d.id });
      if (page.size < 300) break;
      last = page.docs[page.docs.length - 1];
    }
    return out.filter((e) => isLeaderboardEligibleUid(e.uid)).sort(compareRaw);
  }

  async function dobs(uids) {
    const out = new Map();
    for (let i = 0; i < uids.length; i += 100) {
      const refs = uids.slice(i, i + 100).map((u) => db.collection('users').doc(u));
      const snaps = await db.getAll(...refs, { fieldMask: ['dob'] });
      reads += snaps.length;
      for (const s of snaps) out.set(s.id, s.exists ? s.get('dob') : undefined);
    }
    return out;
  }

  async function monthDays(uid, periodKey) {
    const q = await db.collection('users').doc(uid).collection('rePointDays').where('periodKey', '==', periodKey).get();
    reads += Math.max(1, q.size);
    return q.docs.map((d) => d.data());
  }

  const report = {
    schema: 'goodlift-age-comparison',
    modelVersion: age.AGE_MODEL_VERSION,
    project: options.projectId,
    capturedAtUtc: startedAt.toISOString(),
    aucklandDate: todayKey,
    boards: {},
  };
  const csvRows = [];

  for (const periodKey of [monthKey, 'all_time']) {
    const entries = await rawEntries(periodKey);
    const dob = await dobs(entries.map((e) => e.uid));
    const rows = [];
    for (let i = 0; i < entries.length; i += 1) {
      let e = entries[i];
      let result = null;
      let inconsistent = false;
      for (let attempt = 0; attempt <= options.maxRetries; attempt += 1) {
        if (periodKey === 'all_time') {
          result = age.adjustAllTime(e, dob.get(e.uid), todayKey);
          break;
        }
        const days = await monthDays(e.uid, periodKey);
        // Stable capture: the entry must not have changed while its days were read.
        const again = await e._ref.get();
        reads += 1;
        if (again.exists && again.updateTime.isEqual(e._updateTime)) {
          result = age.adjustMonth(e, days, dob.get(e.uid), todayKey);
          inconsistent = false;
          break;
        }
        inconsistent = true;
        if (!again.exists) break;
        e = { _ref: again.ref, _updateTime: again.updateTime, ...again.data(), uid: e.uid };
      }
      const birth = age.parseBirthDate(dob.get(e.uid));
      const ages = result && result.complete ? result.ages : [];
      rows.push({
        uid: e.uid,
        username: e.username || 'GoodLift athlete',
        rawRank: i + 1,
        rawUnits: e.totalPointsUnits,
        tieBreakDateKey: e.tieBreakDateKey || '',
        adjustedUnits: !inconsistent && result && result.complete ? result.totalUnits : null,
        categoryAdjustedUnits: !inconsistent && result && result.complete ? result.categoryUnits : null,
        categoryRawUnits: periodKey === 'all_time' ? e.categoryBestUnits : e.categoryTotalsUnits,
        performanceAgeRange: ages.length ? [Math.min(...ages), Math.max(...ages)] : null,
        currentBand: birth ? age.ageBandLabel(age.completedAge(birth, todayKey)) || 'under 40' : null,
        silverEligible: age.silverEligible(dob.get(e.uid), todayKey, periodKey, e.totalPointsUnits),
        incompleteReason: inconsistent ? 'inconsistent-capture' : result && !result.complete ? result.reason : null,
      });
    }
    const adjusted = rows.filter((r) => r.adjustedUnits !== null)
      .map((r) => Object.assign(r, { adjustedTotalUnits: r.adjustedUnits }))
      .sort(age.compareAdjusted);
    adjusted.forEach((r, i) => {
      r.adjustedRank = i + 1;
      r.rankChange = r.rawRank - r.adjustedRank;
    });
    const rawTop20 = rows.slice(0, 20).map((r) => r.uid);
    const adjTop20 = adjusted.slice(0, 20).map((r) => r.uid);
    const reasons = {};
    for (const r of rows) if (r.incompleteReason) reasons[r.incompleteReason] = (reasons[r.incompleteReason] || 0) + 1;
    report.boards[periodKey] = {
      athletes: rows.length,
      adjustedAthletes: adjusted.length,
      incompleteAthletes: rows.length - adjusted.length,
      incompleteReasons: reasons,
      silverEligible: rows.filter((r) => r.silverEligible).length,
      rawTop20,
      adjustedTop20: adjTop20,
      newTop20Entrants: adjusted.slice(0, 20).filter((r) => r.rawRank > 20).map((r) => ({ username: r.username, rawRank: r.rawRank, adjustedRank: r.adjustedRank })),
      droppedFromTop20: rows.slice(0, 20).filter((r) => !adjTop20.includes(r.uid)).map((r) => ({ username: r.username, rawRank: r.rawRank, adjustedRank: r.adjustedRank || null })),
      largestRankChanges: [...adjusted].sort((a, b) => Math.abs(b.rankChange) - Math.abs(a.rankChange)).slice(0, 15)
        .map((r) => ({ username: r.username, rawRank: r.rawRank, adjustedRank: r.adjustedRank, change: r.rankChange })),
      rows: rows.map(({ uid, ...rest }) => rest),
    };
    for (const r of rows) {
      csvRows.push([periodKey, r.rawRank, r.adjustedRank || '', r.rankChange === undefined ? '' : r.rankChange, r.username,
        (r.rawUnits / 10000).toFixed(4), r.adjustedUnits === null ? '' : (r.adjustedUnits / 10000).toFixed(4),
        ...['horizontalPress', 'verticalPull', 'overheadPress', 'hipHinge', 'squatPattern'].map((k) => (r.categoryAdjustedUnits ? (r.categoryAdjustedUnits[k] / 10000).toFixed(4) : '')),
        r.performanceAgeRange ? r.performanceAgeRange.join('-') : '', r.currentBand || '',
        r.silverEligible ? 'yes' : 'no', rawTop20.includes(r.uid) ? 'yes' : 'no', adjTop20.includes(r.uid) ? 'yes' : 'no',
        r.incompleteReason || '']);
    }
  }
  report.reads = reads;
  report.finishedAtUtc = new Date().toISOString();

  const outDir = options.out || path.join(__dirname, '..', '..', 'build', 'release-verification', 'age-comparison', todayKey);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'comparison.json'), JSON.stringify(report, null, 2));
  const header = ['period', 'rawRank', 'adjustedRank', 'rankChange', 'username', 'rawPoints', 'adjustedPoints',
    'adjHorizontalPress', 'adjVerticalPull', 'adjOverheadPress', 'adjHipHinge', 'adjSquatPattern',
    'performanceAges', 'currentBand', 'silverEligible', 'rawTop20', 'adjustedTop20', 'incompleteReason'];
  fs.writeFileSync(path.join(outDir, 'comparison.csv'), [header, ...csvRows].map((r) => r.map(csvCell).join(',')).join('\n') + '\n');
  const summary = Object.fromEntries(Object.entries(report.boards).map(([k, b]) => [k, {
    athletes: b.athletes, adjusted: b.adjustedAthletes, incomplete: b.incompleteAthletes, reasons: b.incompleteReasons,
    silver: b.silverEligible, newTop20: b.newTop20Entrants, dropped: b.droppedFromTop20, largest: b.largestRankChanges.slice(0, 8),
  }]));
  console.log(JSON.stringify({ outDir, aucklandDate: todayKey, reads, summary }, null, 2));
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

module.exports = { csvCell, compareRaw };
