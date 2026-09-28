#!/usr/bin/env node
'use strict';

// Week-1 RIR backfill for planned blocks (users/{uid}/planned_blocks/{id}).
//
// DRY RUN BY DEFAULT: reads only and prints/writes a report of every user,
// block, exercise and individual field that WOULD change, plus the records
// that are ambiguous and are left alone. Nothing is written unless --apply is
// passed.
//
// Rule: scripts/week1_rir_fill.js (the app's canonical healWeek1RirPlan,
// pinned by shared vectors). Only genuinely absent week-1 set entries and
// absent `reps` leaves are added; nothing is ever deleted or overwritten.
//
// --apply writes, per block, ONE transaction that re-reads the block and
// re-plans against the server copy, then updates only the missing leaf paths
// (exerciseSettings.<id>.rirPlan.week1.<session>.<set>[.reps]). Re-running is
// safe: filled records plan no further changes.
//
// Usage (run from functions/):
//   node scripts/backfill_week1_rir.js --project goodlift-us-storage            # dry run, all users
//   node scripts/backfill_week1_rir.js --uid <uid>                               # dry run, one user
//   node scripts/backfill_week1_rir.js --report out/rir-dry-run.json             # save the report
//   node scripts/backfill_week1_rir.js --checkpoint out/rir.ckpt                 # resumable paging
//   node scripts/backfill_week1_rir.js --apply --uid <uid> --checkpoint ...      # WRITES (reviewed only)

const fs = require('node:fs');
const admin = require('firebase-admin');
const { planWeek1RirFill } = require('./week1_rir_fill');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uid: null,
    apply: false,
    pageSize: 200,
    checkpoint: null,
    report: null,
    limitBlocks: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${a} requires a value`);
      return v;
    };
    if (a === '--apply') out.apply = true;
    else if (a === '--project') out.projectId = next();
    else if (a === '--uid') out.uid = next();
    else if (a === '--page-size') out.pageSize = Number(next());
    else if (a === '--checkpoint') out.checkpoint = next();
    else if (a === '--report') out.report = next();
    else if (a === '--limit-blocks') out.limitBlocks = Number(next());
    else if (a === '--help' || a === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (!Number.isInteger(out.pageSize) || out.pageSize < 1 || out.pageSize > 500) {
    throw new Error('--page-size must be an integer 1..500');
  }
  if (out.limitBlocks !== null && (!Number.isInteger(out.limitBlocks) || out.limitBlocks < 1)) {
    throw new Error('--limit-blocks must be a positive integer');
  }
  return out;
}

/** users/{uid}/planned_blocks/{id} only (never the retired top-level tree). */
function isUserBlockPath(p) {
  const s = p.split('/');
  return s.length === 4 && s[0] === 'users' && s[2] === 'planned_blocks';
}

/** Plans every exercise in one block's data. Pure. */
function planBlock(data) {
  const settings = data && typeof data.exerciseSettings === 'object' && data.exerciseSettings
    && !Array.isArray(data.exerciseSettings) ? data.exerciseSettings : {};
  const exercises = [];
  for (const [exerciseId, s] of Object.entries(settings)) {
    const plan = planWeek1RirFill(s);
    if (plan.status === 'fill' || plan.status === 'ambiguous') {
      exercises.push({ exerciseId, ...plan });
    }
  }
  return exercises;
}

function toUpdate(exercises) {
  const { FieldPath } = admin.firestore;
  const args = [];
  for (const ex of exercises) {
    if (ex.status !== 'fill') continue;
    for (const f of ex.fills) {
      args.push(new FieldPath('exerciseSettings', ex.exerciseId, ...f.path), f.value);
    }
  }
  return args;
}

function readCheckpoint(file) {
  if (!file || !fs.existsSync(file)) return null;
  const v = fs.readFileSync(file, 'utf8').trim();
  return v || null;
}

/**
 * Runs the audit / backfill. Returns the report (also usable from tests).
 * @param {{db: FirebaseFirestore.Firestore, apply?: boolean, uid?: string|null,
 *          pageSize?: number, checkpoint?: string|null, limitBlocks?: number|null,
 *          log?: (s: string) => void}} o
 */
async function run(o) {
  const db = o.db;
  const apply = o.apply === true;
  const log = o.log || (() => {});
  const pageSize = o.pageSize || 200;
  const report = {
    mode: apply ? 'apply' : 'dry-run',
    scannedBlocks: 0,
    users: {},
    totals: {
      usersAffected: 0, blocksAffected: 0, exercisesToFill: 0,
      fieldsToFill: 0, setsToCreate: 0, repsToAdd: 0,
      exercisesAmbiguous: 0, blocksWritten: 0, fieldsWritten: 0,
    },
    lastPath: null,
  };

  const base = o.uid
    ? db.collection('users').doc(o.uid).collection('planned_blocks')
    : db.collectionGroup('planned_blocks');
  let cursor = readCheckpoint(o.checkpoint);
  let processed = 0;

  for (;;) {
    let q = base.orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (cursor) {
      q = o.uid ? q.startAfter(cursor.split('/').pop()) : q.startAfter(db.doc(cursor));
    }
    const page = await q.get();
    if (page.empty) break;

    for (const doc of page.docs) {
      cursor = doc.ref.path;
      if (!isUserBlockPath(doc.ref.path)) continue;
      report.scannedBlocks += 1;
      const exercises = planBlock(doc.data());
      if (exercises.length) {
        const uid = doc.ref.path.split('/')[1];
        const u = (report.users[uid] ||= { blocks: {} });
        u.blocks[doc.id] = exercises.map((e) => ({
          exerciseId: e.exerciseId,
          status: e.status,
          fields: e.fills.map((f) => ({ path: f.path.join('.'), kind: f.kind, value: f.value })),
          reasons: e.reasons,
        }));
        for (const e of exercises) {
          if (e.status === 'ambiguous') report.totals.exercisesAmbiguous += 1;
          else {
            report.totals.exercisesToFill += 1;
            report.totals.fieldsToFill += e.fills.length;
            report.totals.setsToCreate += e.fills.filter((f) => f.kind === 'set').length;
            report.totals.repsToAdd += e.fills.filter((f) => f.kind === 'reps').length;
          }
        }
        if (apply && exercises.some((e) => e.status === 'fill')) {
          const written = await db.runTransaction(async (txn) => {
            const fresh = await txn.get(doc.ref);
            if (!fresh.exists) return 0;
            const updateArgs = toUpdate(planBlock(fresh.data()));
            if (updateArgs.length === 0) return 0;
            txn.update(doc.ref, ...updateArgs);
            return updateArgs.length / 2;
          });
          if (written > 0) {
            report.totals.blocksWritten += 1;
            report.totals.fieldsWritten += written;
          }
        }
      }
      processed += 1;
      if (o.limitBlocks && processed >= o.limitBlocks) break;
    }
    report.lastPath = cursor;
    if (o.checkpoint) fs.writeFileSync(o.checkpoint, cursor || '');
    log(`[rir-backfill] ${report.mode}: scanned ${report.scannedBlocks} blocks (last ${cursor})`);
    if (page.size < pageSize || (o.limitBlocks && processed >= o.limitBlocks)) break;
  }

  const users = Object.values(report.users);
  report.totals.usersAffected = users.length;
  report.totals.blocksAffected = users.reduce((n, u) => n + Object.keys(u.blocks).length, 0);
  return report;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(2, 26).join('\n'));
    return;
  }
  if (!admin.apps.length) admin.initializeApp({ projectId: args.projectId });
  const report = await run({
    db: admin.firestore(),
    apply: args.apply,
    uid: args.uid,
    pageSize: args.pageSize,
    checkpoint: args.checkpoint,
    limitBlocks: args.limitBlocks,
    log: (s) => console.log(s),
  });
  const json = JSON.stringify(report, null, 2);
  if (args.report) fs.writeFileSync(args.report, json);
  console.log(JSON.stringify({ mode: report.mode, scannedBlocks: report.scannedBlocks, ...report.totals }, null, 2));
  if (!args.apply) console.log('DRY RUN — nothing was written. Re-run with --apply only after review.');
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exitCode = 1;
  });
}

module.exports = { run, _internals: { parseArgs, isUserBlockPath, planBlock } };
