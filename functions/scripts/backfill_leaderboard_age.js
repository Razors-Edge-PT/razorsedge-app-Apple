#!/usr/bin/env node
'use strict';

// Backfill of the NEW derived age-leaderboard data for the two live boards
// (the current Auckland month and all time): leaderboardsAge/{period}/entries,
// the boards' silver sets and counts, and the two public website snapshots
// leaderboardPublic/{period}.
//
// SAFETY CONTRACT
//   * Dry run by default: computes every athlete's age entry exactly as the
//     trigger would and reports what WOULD change. Writes nothing.
//   * --apply writes only leaderboardsAge/** and leaderboardPublic/**, through
//     the same transactional recompute the trigger uses (no-op when a document
//     is already current). Raw entries, day scores, medals, birth dates,
//     bodyweights and workouts are only READ.
//   * Idempotent and resumable: every athlete is recomputed from sources; a
//     rerun after an interruption converges (unchanged athletes are skipped).
//   * Bounded: --concurrency athletes at a time (default 4, max 8), athletes
//     listed in pages of 300. Per-athlete failures are reported, not fatal.
//   * --verify re-reads every age entry afterwards and checks it against a
//     fresh computation.
//
//   node scripts/backfill_leaderboard_age.js --project goodlift-us-storage            # dry run
//   node scripts/backfill_leaderboard_age.js --project goodlift-us-storage --apply    # write + verify

function parseArgs(argv) {
  const out = { projectId: 'goodlift-us-storage', apply: false, concurrency: 4 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--project') out.projectId = argv[++i];
    else if (a === '--apply') out.apply = true;
    else if (a === '--concurrency') out.concurrency = Math.min(8, Math.max(1, Number(argv[++i]) || 4));
    else throw new Error(`Unknown argument ${a}`);
  }
  return out;
}

async function pool(items, n, fn) {
  let i = 0;
  const workers = Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) {
      const item = items[i];
      i += 1;
      await fn(item);
    }
  });
  await Promise.all(workers);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId, credential: admin.credential.applicationDefault() });
  const db = admin.firestore();
  const age = require('../leaderboard/age');
  const ageFs = require('../leaderboard/age_firestore');
  const { canonicalJson } = require('../showcase/store');
  const { isLeaderboardEligibleUid } = require('../leaderboard/eligibility');
  const { localDateKey } = require('../coach/coverage');

  const nowMs = Date.now();
  const todayKey = localDateKey(new Date(nowMs), 'Pacific/Auckland');
  const boards = ageFs.liveBoards(nowMs);
  const report = { mode: options.apply ? 'apply' : 'dry-run', todayKey, modelVersion: age.AGE_MODEL_VERSION, boards: {} };

  async function listAll(col) {
    const out = [];
    let last = null;
    for (;;) {
      let q = col.orderBy(admin.firestore.FieldPath.documentId()).limit(300);
      if (last) q = q.startAfter(last);
      const page = await q.get();
      out.push(...page.docs);
      if (page.size < 300) break;
      last = page.docs[page.docs.length - 1];
    }
    return out;
  }

  /** What the trigger would write, computed read-only. */
  async function plan(uid, p, raw) {
    const [userSnap] = await db.getAll(db.collection('users').doc(uid), { fieldMask: ['dob'] });
    const dob = userSnap.exists ? userSnap.get('dob') : undefined;
    let result;
    if (p === 'all_time') {
      result = age.adjustAllTime(raw, dob, todayKey);
    } else {
      const days = await db.collection('users').doc(uid).collection('rePointDays').where('periodKey', '==', p).get();
      result = age.adjustMonth(Object.assign({ periodKey: p }, raw), days.docs.map((d) => d.data()), dob, todayKey);
    }
    const silver = age.silverEligible(dob, todayKey, p, raw.totalPointsUnits);
    return { doc: ageFs.ageEntryDoc(uid, p, raw, result, silver), reason: result.complete ? null : result.reason };
  }

  for (const p of boards) {
    const raws = (await listAll(db.collection('leaderboards').doc(p).collection('entries')))
      .map((d) => Object.assign({}, d.data(), { uid: d.id }))
      .filter((e) => isLeaderboardEligibleUid(e.uid) && Number.isSafeInteger(e.totalPointsUnits) && e.totalPointsUnits > 0);
    const existing = new Map((await listAll(ageFs.ageBoardRef(p).collection('entries'))).map((d) => [d.id, d.data()]));
    const counts = { athletes: raws.length, wouldSet: 0, unchanged: 0, complete: 0, incomplete: 0, silver: 0, orphans: 0, written: 0, deleted: 0, failed: 0 };
    const reasons = {};
    const failures = [];
    await pool(raws, options.concurrency, async (raw) => {
      try {
        const { doc, reason } = await plan(raw.uid, p, raw);
        if (doc.ageComplete) counts.complete += 1;
        else {
          counts.incomplete += 1;
          reasons[reason] = (reasons[reason] || 0) + 1;
        }
        if (doc.silverEligible) counts.silver += 1;
        const prev = existing.get(raw.uid);
        const copy = prev ? Object.assign({}, prev) : null;
        if (copy) delete copy.updatedAt;
        if (copy && canonicalJson(copy) === canonicalJson(doc)) counts.unchanged += 1;
        else counts.wouldSet += 1;
        if (options.apply) {
          const res = await ageFs.recomputeAthleteBoard(raw.uid, p, nowMs);
          if (res === 'set') counts.written += 1;
        }
      } catch (err) {
        counts.failed += 1;
        if (failures.length < 20) failures.push({ uid: raw.uid.slice(0, 6), error: String(err && err.message) });
      }
    });
    const rawUids = new Set(raws.map((r) => r.uid));
    for (const uid of existing.keys()) {
      if (rawUids.has(uid)) continue;
      counts.orphans += 1;
      if (options.apply && (await ageFs.recomputeAthleteBoard(uid, p, nowMs)) === 'deleted') counts.deleted += 1;
    }
    if (options.apply) {
      // Verify: every age entry equals a fresh read-only computation.
      let mismatched = 0;
      const after = new Map((await listAll(ageFs.ageBoardRef(p).collection('entries'))).map((d) => [d.id, d.data()]));
      for (const raw of raws) {
        const { doc } = await plan(raw.uid, p, raw);
        const got = after.get(raw.uid) ? Object.assign({}, after.get(raw.uid)) : null;
        if (got) delete got.updatedAt;
        if (!got || canonicalJson(got) !== canonicalJson(doc)) mismatched += 1;
      }
      counts.verifiedMismatches = mismatched;
      counts.extraAfter = [...after.keys()].filter((u) => !rawUids.has(u)).length;
      const board = (await ageFs.ageBoardRef(p).get()).data() || {};
      counts.silverSetSize = Array.isArray(board.silverUids) ? board.silverUids.length : 0;
    }
    report.boards[p] = { counts, reasons, failures };
  }
  if (options.apply) report.public = await ageFs.publishAll(nowMs);
  console.log(JSON.stringify(report, null, 2));
  if (Object.values(report.boards).some((b) => b.counts.failed || b.counts.verifiedMismatches)) process.exitCode = 2;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs };
