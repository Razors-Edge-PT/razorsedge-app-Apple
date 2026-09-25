#!/usr/bin/env node
'use strict';

// ONE-TIME, SINGLE-ACCOUNT correction: historical loads for ONE exercise were
// typed in POUNDS but stored as if they were kilograms. This rewrites those
// source values to canonical kilograms (value × 0.45359237, unrounded) and
// sets exerciseSettings[exerciseId].weightUnit = 'lb' so the app keeps showing
// the numbers as they were entered. Derived data (profile showcase, rePointDays,
// leaderboards) is NEVER written here: the deployed workout / planned-block
// triggers recompute it from the corrected sources.
//
// The target is hard-coded and must also be passed explicitly:
//   node scripts/migrate_exercise_lb_once.js --uid <uid> --exercise <id>             (dry run)
//   node scripts/migrate_exercise_lb_once.js --uid <uid> --exercise <id> --apply     (writes)
//   node scripts/migrate_exercise_lb_once.js --uid <uid> --exercise <id> --verify    (after apply)
//
// Scope options (decided from the dry run):
//   --exclude-dates d1,d2         workout dates whose values were genuinely kg
//   --skip-increments b1,b2       planned blocks whose increments were genuinely kg
//
// SAFETY
//   * Dry run by default; refuses anything but the exact uid / exercise / username.
//   * Before any write: a complete JSON backup of every affected document is
//     saved OUTSIDE the repository (see BACKUP_ROOT), plus a manifest.
//   * Refuses to run twice: a private marker migrations/{MARKER_ID} is written
//     BEFORE the first source write and never removed.
//   * Each workout / block is written once, sequentially, in a transaction that
//     re-reads it and aborts if it changed since the backup.
//   * Only `sets[].weight` of the matching exercise entries, and increments +
//     weightUnit of that exercise's settings, are changed.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const TARGET = Object.freeze({
  uid: 'yoVAqScwLMQLAgNHh8v9IK49fBw2',
  username: 'NZBenchPress',
  exerciseId: '1XOIXxeLFhgmgjZS9Cyq',
  exerciseName: 'Lat Pull Down, Supinated',
});
const KG_PER_LB = 0.45359237;
const PROJECT_ID = 'goodlift-us-storage';
const MARKER_ID = `exerciseLbCorrection_${TARGET.uid}_${TARGET.exerciseId}`;
const BACKUP_ROOT = path.join(os.homedir(), 'GoodLift-migration-backups');
const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;
const INCREMENT_KEYS = ['primary', 'secondary'];

// ── Pure planning (unit-tested) ─────────────────────────────────────────────

function parseArgs(argv) {
  const out = { apply: false, verify: false, uid: null, exerciseId: null, excludeDates: [], skipIncrements: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--apply') out.apply = true;
    else if (a === '--verify') out.verify = true;
    else if (a === '--uid') out.uid = argv[++i] || null;
    else if (a === '--exercise') out.exerciseId = argv[++i] || null;
    else if (a === '--exclude-dates') out.excludeDates = String(argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    else if (a === '--skip-increments') out.skipIncrements = String(argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify');
  for (const d of out.excludeDates) if (!DATE_KEY_RE.test(d)) throw new Error(`Bad --exclude-dates value: ${d}`);
  return out;
}

/** Throws unless uid / exercise id are EXACTLY the hard-coded target. */
function assertExactTarget({ uid, exerciseId }) {
  if (uid !== TARGET.uid) throw new Error(`Refusing: --uid must be exactly ${TARGET.uid}`);
  if (exerciseId !== TARGET.exerciseId) throw new Error(`Refusing: --exercise must be exactly ${TARGET.exerciseId}`);
}

/** The single conversion. Unrounded: the canonical value is the exact product. */
function lbToKg(value) {
  return value * KG_PER_LB;
}

/**
 * A stored load converted, preserving its type. Numbers stay numbers; numeric
 * strings stay strings. Anything else (missing, null, blank, non-numeric) is
 * NOT a load and is left alone ({ changed: false }).
 */
function convertLoad(raw) {
  if (typeof raw === 'number') {
    if (!Number.isFinite(raw) || raw <= 0) return { changed: false };
    return { changed: true, value: lbToKg(raw) };
  }
  if (typeof raw === 'string') {
    const t = raw.trim();
    if (!t || !/^\d+(\.\d+)?$/.test(t)) return { changed: false };
    const n = Number(t);
    if (!(n > 0)) return { changed: false };
    return { changed: true, value: String(lbToKg(n)) };
  }
  return { changed: false };
}

/** Case-folded exercise-id match (the server's rule: re_catalog.js). */
function isTargetEntry(entry, exerciseId) {
  if (!entry || typeof entry !== 'object') return false;
  const id = entry.exerciseId !== undefined ? entry.exerciseId : entry.id;
  return typeof id === 'string' && id.toLowerCase() === exerciseId.toLowerCase();
}

/**
 * Plans the workout changes. [workouts] is [[docId, data]]. Returns
 * { changes: [{ docId, exercises, sets: [{entryIndex, setIndex, before, after}] }],
 *   legacyDocs, skipped }.
 */
function planWorkouts(workouts, { exerciseId, exerciseName, excludeDates = [] }) {
  const changes = [];
  const legacyDocs = [];
  const skipped = [];
  const excluded = new Set(excludeDates);
  for (const [docId, data] of workouts) {
    const exercises = Array.isArray(data && data.exercises) ? data.exercises : [];
    const byId = exercises.some((e) => isTargetEntry(e, exerciseId));
    const byName = exercises.some((e) => e && e.name === exerciseName && e.exerciseId === undefined && e.id === undefined);
    if (!DATE_KEY_RE.test(docId)) {
      if (byId || byName) legacyDocs.push(docId);
      continue;
    }
    if (!byId) continue;
    if (excluded.has(docId)) {
      skipped.push({ docId, reason: 'excluded by --exclude-dates (values judged genuine kg)' });
      continue;
    }
    const sets = [];
    const next = exercises.map((e, entryIndex) => {
      if (!isTargetEntry(e, exerciseId) || !Array.isArray(e.sets)) return e;
      return Object.assign({}, e, {
        sets: e.sets.map((s, setIndex) => {
          if (!s || typeof s !== 'object') return s;
          const c = convertLoad(s.weight);
          if (!c.changed) return s;
          sets.push({ entryIndex, setIndex, before: s.weight, after: c.value, reps: s.reps, rir: s.rir });
          return Object.assign({}, s, { weight: c.value });
        }),
      });
    });
    if (sets.length === 0) {
      skipped.push({ docId, reason: 'matching entry has no numeric loads' });
      continue;
    }
    changes.push({ docId, exercises: next, sets });
  }
  return { changes, legacyDocs, skipped };
}

/**
 * Plans the settings changes. [blocks] is [[blockId, data]]. Every block with
 * exerciseSettings[exerciseId] gets weightUnit 'lb'; its numeric increments are
 * converted unless the block is listed in [skipIncrements].
 */
function planBlocks(blocks, { exerciseId, skipIncrements = [] }) {
  const changes = [];
  const skip = new Set(skipIncrements);
  for (const [blockId, data] of blocks) {
    const settings = data && data.exerciseSettings && data.exerciseSettings[exerciseId];
    if (!settings || typeof settings !== 'object') continue;
    const increments = [];
    if (!skip.has(blockId) && settings.increments && typeof settings.increments === 'object') {
      for (const k of INCREMENT_KEYS) {
        const c = convertLoad(settings.increments[k]);
        if (c.changed) increments.push({ key: k, before: settings.increments[k], after: c.value });
      }
    }
    const unitBefore = settings.weightUnit === undefined ? null : settings.weightUnit;
    if (unitBefore === 'lb' && increments.length === 0) continue;
    changes.push({ blockId, isActive: data.isActive === true, unitBefore, increments, incrementsSkipped: skip.has(blockId) });
  }
  return changes;
}

/** Stable content hash used to detect a document changing after the backup. */
function contentHash(data) {
  return crypto.createHash('sha256').update(canonical(data)).digest('hex');
}

function canonical(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (typeof v.toMillis === 'function') return JSON.stringify({ __ts: v.toMillis() });
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
}

/** JSON-safe copy for the backup (Timestamps as ISO + millis). */
function toBackupJson(v) {
  if (v === null || typeof v !== 'object') return v;
  if (typeof v.toMillis === 'function') return { __timestamp: new Date(v.toMillis()).toISOString(), millis: v.toMillis() };
  if (Array.isArray(v)) return v.map(toBackupJson);
  const o = {};
  for (const k of Object.keys(v)) o[k] = toBackupJson(v[k]);
  return o;
}

// ── Firestore I/O ───────────────────────────────────────────────────────────

async function loadState(db) {
  const userRef = db.collection('users').doc(TARGET.uid);
  const [pub, ex, marker, workouts, blocks] = await Promise.all([
    db.collection('users_public').doc(TARGET.uid).get(),
    db.collection('exercises').doc(TARGET.exerciseId).get(),
    db.collection('migrations').doc(MARKER_ID).get(),
    userRef.collection('workouts').get(),
    userRef.collection('planned_blocks').get(),
  ]);
  return {
    username: pub.exists ? pub.get('username') : null,
    publishedUnits: pub.exists ? pub.get('exerciseWeightUnits') || null : null,
    exerciseName: ex.exists ? ex.get('name') : null,
    marker: marker.exists ? marker.data() : null,
    workouts: workouts.docs.map((d) => [d.id, d.data()]),
    blocks: blocks.docs.map((d) => [d.id, d.data()]),
    reads: 3 + Math.max(1, workouts.size) + Math.max(1, blocks.size),
  };
}

function assertLiveIdentity(state) {
  if (state.username !== TARGET.username) {
    throw new Error(`Refusing: users_public/${TARGET.uid}.username is ${JSON.stringify(state.username)}, expected ${TARGET.username}`);
  }
  if (state.exerciseName !== TARGET.exerciseName) {
    throw new Error(`Refusing: exercises/${TARGET.exerciseId}.name is ${JSON.stringify(state.exerciseName)}, expected ${TARGET.exerciseName}`);
  }
}

function fmt(n) {
  return typeof n === 'number' ? Number(n.toFixed(6)).toString() : JSON.stringify(n);
}

function report(state, plan, blockPlan, opts) {
  const w = (s) => process.stdout.write(`${s}\n`);
  const sets = plan.changes.reduce((n, c) => n + c.sets.length, 0);
  w(`Account:   ${TARGET.uid}  username=${state.username}  ✔ exact match`);
  w(`Exercise:  ${TARGET.exerciseId}  "${state.exerciseName}"  ✔ exact match`);
  w(`Factor:    canonicalKg = value × ${KG_PER_LB}`);
  w(`Marker:    migrations/${MARKER_ID} ${state.marker ? `EXISTS (${state.marker.status})` : 'absent'}`);
  w('');
  w(`Workout documents inspected: ${state.workouts.length} (${state.workouts.filter(([id]) => DATE_KEY_RE.test(id)).length} date-keyed)`);
  w(`Affected workout documents:  ${plan.changes.length}`);
  w(`Affected sets:               ${sets}`);
  w('');
  for (const c of plan.changes) {
    w(`  users/<uid>/workouts/${c.docId}`);
    for (const s of c.sets) w(`     entry ${s.entryIndex} set ${s.setIndex}: ${fmt(s.before)} → ${fmt(s.after)} kg   (reps ${s.reps ?? '—'}, rir ${s.rir ?? '—'})`);
  }
  w('');
  w(`Legacy non-date workout documents naming this exercise: ${plan.legacyDocs.length ? plan.legacyDocs.join(', ') : 'none'} — EXCLUDED`);
  w(`Skipped: ${plan.skipped.length ? plan.skipped.map((s) => `${s.docId} (${s.reason})`).join('; ') : 'none'}`);
  w('');
  w('Settings (users/<uid>/planned_blocks/{id}.exerciseSettings.<exercise>):');
  if (!blockPlan.length) w('  none');
  for (const b of blockPlan) {
    const inc = b.increments.map((i) => `${i.key} ${fmt(i.before)} → ${fmt(i.after)} kg`).join(', ');
    w(`  ${b.blockId}${b.isActive ? ' (ACTIVE)' : ''}: weightUnit ${JSON.stringify(b.unitBefore)} → "lb"; increments: ${inc || (b.incrementsSkipped ? 'kept (--skip-increments)' : 'none numeric')}`);
  }
  w('');
  w(`Excluded dates: ${opts.excludeDates.join(', ') || 'none'}   Increment-skipped blocks: ${opts.skipIncrements.join(', ') || 'none'}`);
  w(`Firestore operations — reads so far: ${state.reads}; apply would add: ${plan.changes.length + blockPlan.length + 2} reads (transaction re-reads + marker) and ${plan.changes.length + blockPlan.length + 2} writes (1 per document + marker start/finish).`);
  w('Derived documents (profileShowcaseV2, showcase/v2 days, rePointDays, leaderboards, re_* caches): NOT written by this script.');
}

async function writeBackup(state, plan, blockPlan, opts) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dir = path.join(BACKUP_ROOT, `${stamp}_${TARGET.exerciseId}`);
  fs.mkdirSync(dir, { recursive: true });
  const workouts = new Map(state.workouts);
  const blocks = new Map(state.blocks);
  const docs = [];
  for (const c of plan.changes) {
    const data = workouts.get(c.docId);
    docs.push({ path: `users/${TARGET.uid}/workouts/${c.docId}`, sha256: contentHash(data), data: toBackupJson(data) });
  }
  for (const b of blockPlan) {
    const data = blocks.get(b.blockId);
    docs.push({ path: `users/${TARGET.uid}/planned_blocks/${b.blockId}`, sha256: contentHash(data), data: toBackupJson(data) });
  }
  const manifest = {
    createdAt: new Date().toISOString(),
    project: PROJECT_ID,
    target: TARGET,
    factor: KG_PER_LB,
    formula: 'canonicalKg = existingValue × 0.45359237 (unrounded)',
    options: opts,
    marker: `migrations/${MARKER_ID}`,
    documents: docs.map((d) => ({ path: d.path, sha256: d.sha256 })),
    workoutChanges: plan.changes.map((c) => ({ docId: c.docId, sets: c.sets })),
    settingsChanges: blockPlan,
    legacyDocsExcluded: plan.legacyDocs,
    skipped: plan.skipped,
  };
  fs.writeFileSync(path.join(dir, 'documents.json'), JSON.stringify(docs, null, 2));
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  // Read back so a failed disk write can never be followed by a source write.
  const check = JSON.parse(fs.readFileSync(path.join(dir, 'documents.json'), 'utf8'));
  if (check.length !== docs.length) throw new Error('Backup verification failed');
  return { dir, hashes: new Map(docs.map((d) => [d.path, d.sha256])) };
}

async function apply(admin, db, state, plan, blockPlan, opts) {
  if (state.marker) throw new Error(`Refusing: migrations/${MARKER_ID} already exists (status ${state.marker.status}). This migration runs once.`);
  const backup = await writeBackup(state, plan, blockPlan, opts);
  process.stdout.write(`\nBackup written: ${backup.dir}\n`);
  const markerRef = db.collection('migrations').doc(MARKER_ID);
  // create() fails if the marker exists — the second-run guard is atomic.
  await markerRef.create({
    status: 'in_progress', uid: TARGET.uid, exerciseId: TARGET.exerciseId, factor: KG_PER_LB,
    startedAt: admin.firestore.FieldValue.serverTimestamp(), backupManifest: path.join(backup.dir, 'manifest.json'),
    options: opts,
  });
  const userRef = db.collection('users').doc(TARGET.uid);
  let workoutsWritten = 0;
  let setsWritten = 0;
  for (const c of plan.changes) {
    const ref = userRef.collection('workouts').doc(c.docId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists || contentHash(snap.data()) !== backup.hashes.get(ref.path)) {
        throw new Error(`${ref.path} changed since the backup — aborting (marker left in_progress).`);
      }
      tx.update(ref, { exercises: c.exercises });
    });
    workoutsWritten += 1;
    setsWritten += c.sets.length;
    process.stdout.write(`  wrote ${ref.path.replace(TARGET.uid, '<uid>')} (${c.sets.length} sets)\n`);
  }
  let blocksWritten = 0;
  for (const b of blockPlan) {
    const ref = userRef.collection('planned_blocks').doc(b.blockId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists || contentHash(snap.data()) !== backup.hashes.get(ref.path)) {
        throw new Error(`${ref.path} changed since the backup — aborting (marker left in_progress).`);
      }
      const FP = admin.firestore.FieldPath;
      const args = [new FP('exerciseSettings', TARGET.exerciseId, 'weightUnit'), 'lb'];
      for (const i of b.increments) args.push(new FP('exerciseSettings', TARGET.exerciseId, 'increments', i.key), i.after);
      tx.update(ref, ...args);
    });
    blocksWritten += 1;
    process.stdout.write(`  wrote ${ref.path.replace(TARGET.uid, '<uid>')} (weightUnit lb, ${b.increments.length} increments)\n`);
  }
  await markerRef.update({
    status: 'done', finishedAt: admin.firestore.FieldValue.serverTimestamp(),
    workoutDocsChanged: workoutsWritten, setsChanged: setsWritten, settingsDocsChanged: blocksWritten,
  });
  process.stdout.write(`\nApplied: ${workoutsWritten} workout documents, ${setsWritten} sets, ${blocksWritten} settings documents. Marker: done.\n`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  assertExactTarget(opts);
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: PROJECT_ID });
  const db = admin.firestore();
  const state = await loadState(db);
  assertLiveIdentity(state);
  const plan = planWorkouts(state.workouts, { exerciseId: TARGET.exerciseId, exerciseName: TARGET.exerciseName, excludeDates: opts.excludeDates });
  const blockPlan = planBlocks(state.blocks, { exerciseId: TARGET.exerciseId, skipIncrements: opts.skipIncrements });
  process.stdout.write(`Exercise lb→kg correction — mode: ${opts.apply ? 'APPLY' : opts.verify ? 'verify' : 'dry-run'}\n\n`);
  if (opts.verify) {
    if (!state.marker || state.marker.status !== 'done') throw new Error('Nothing to verify: the migration has not completed.');
    process.stdout.write(`Marker: ${JSON.stringify(state.marker)}\n`);
    process.stdout.write(`Remaining convertible sets (should be 0 once applied): ${plan.changes.reduce((n, c) => n + c.sets.length, 0)}\n`);
    return;
  }
  report(state, plan, blockPlan, opts);
  if (!opts.apply) {
    process.stdout.write('\nDry run only — nothing written.\n');
    return;
  }
  await apply(admin, db, state, plan, blockPlan, opts);
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.message ? err.message : err}\n`);
    process.exit(1);
  });
}

module.exports = {
  TARGET, KG_PER_LB, MARKER_ID, parseArgs, assertExactTarget, lbToKg, convertLoad, isTargetEntry,
  planWorkouts, planBlocks, contentHash, toBackupJson, apply,
};
