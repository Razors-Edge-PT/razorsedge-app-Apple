#!/usr/bin/env node
'use strict';

// Moves the profile showcase snapshots (profileShowcaseV1 / profileShowcaseV2)
// off users_public/{uid} — readable by EVERY signed-in account — onto the
// friend-gated users_showcase/{uid} (firestore.rules).
//
// Safety contract:
//   * dry-run by default; nothing is written without --apply;
//   * --copy never overwrites: a field already on users_showcase was written
//     by the server after the new functions were deployed and is newer;
//   * --strip removes a users_public field ONLY when users_showcase holds a
//     snapshot for it (copying it first, in the same transaction, if needed),
//     so no athlete's showcase can be lost;
//   * --strip refuses while showcase/firestore_store.js still mirrors writes
//     onto users_public: the mirror would simply republish the fields;
//   * --verify is read-only; idempotent throughout; only the two showcase
//     fields are ever touched. No workout, day score or identity field is.
//
// ── Cutover sequence ────────────────────────────────────────────────────────
//   1. Deploy firestore.rules (users_showcase match) and the functions
//      (showcase writers publish to users_showcase AND mirror to
//      users_public; leaderboardOnShowcaseWrite).
//   2. Copy:   node scripts/migrate_profile_showcase_private.js --copy           (review)
//              node scripts/migrate_profile_showcase_private.js --copy --apply
//      Release the app build that reads users_showcase (1.7.58+).
//   3. Once installed builds before 1.7.58 are no longer supported: set
//      MIRROR_SHOWCASE_TO_USERS_PUBLIC = false in showcase/firestore_store.js
//      and deploy the showcase functions.
//   4. Strip:  node scripts/migrate_profile_showcase_private.js --strip          (review)
//              node scripts/migrate_profile_showcase_private.js --strip --apply
//   5. Verify: node scripts/migrate_profile_showcase_private.js --verify        (expect CLEAN)
// Until step 4 the snapshots remain readable on users_public; builds before
// 1.7.58 show an empty showcase after it.

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const FIELDS = ['profileShowcaseV1', 'profileShowcaseV2'];
const PAGE = 300;

function usage() {
  return [
    'Move profile showcase snapshots from users_public to users_showcase',
    '',
    '  node scripts/migrate_profile_showcase_private.js --copy  [--apply]',
    '  node scripts/migrate_profile_showcase_private.js --strip [--apply]',
    '  node scripts/migrate_profile_showcase_private.js --verify',
    '  (all accept --project <id>; default goodlift-us-storage)',
  ].join('\n');
}

function parseArgs(argv) {
  const out = { projectId: DEFAULT_PROJECT_ID, mode: null, apply: false, help: false };
  const setMode = (m) => {
    if (out.mode && out.mode !== m) throw new Error('Choose one of --copy, --strip or --verify');
    out.mode = m;
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--copy') setMode('copy');
    else if (arg === '--strip') setMode('strip');
    else if (arg === '--verify') setMode('verify');
    else if (arg === '--apply') out.apply = true;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.help) return out;
  if (!out.projectId) throw new Error('--project requires a value');
  if (!out.mode) throw new Error('Choose one of --copy, --strip or --verify');
  if (out.mode === 'verify' && out.apply) throw new Error('--verify is read-only');
  return out;
}

/**
 * The writes for one athlete (pure). [pub] is users_public data, [priv] the
 * users_showcase data (null when absent).
 *   copy   → fields to copy (absent on users_showcase, present on users_public)
 *   strip  → the copy as above, plus the users_public fields to delete
 */
function planAthlete(mode, pub, priv) {
  const copy = {};
  const strip = [];
  for (const f of FIELDS) {
    const legacy = pub && pub[f] ? pub[f] : null;
    const current = priv && priv[f] ? priv[f] : null;
    if (legacy && !current) copy[f] = legacy;
    if (mode === 'strip' && pub && f in pub) strip.push(f);
  }
  return { copy, strip };
}

async function migrateOne(db, admin, uid, mode) {
  return db.runTransaction(async (tx) => {
    const pubRef = db.collection('users_public').doc(uid);
    const privRef = db.collection('users_showcase').doc(uid);
    const [pubSnap, privSnap] = await tx.getAll(pubRef, privRef);
    const plan = planAthlete(mode, pubSnap.exists ? pubSnap.data() : null, privSnap.exists ? privSnap.data() : null);
    const copied = Object.keys(plan.copy);
    if (copied.length) tx.set(privRef, plan.copy, { mergeFields: copied });
    if (plan.strip.length) {
      const del = {};
      for (const f of plan.strip) del[f] = admin.firestore.FieldValue.delete();
      tx.update(pubRef, del);
    }
    return { copied, stripped: plan.strip };
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  if (options.mode === 'strip' && options.apply) {
    const { MIRROR_SHOWCASE_TO_USERS_PUBLIC } = require('../showcase/firestore_store');
    if (MIRROR_SHOWCASE_TO_USERS_PUBLIC) {
      process.stderr.write('Refusing to strip: MIRROR_SHOWCASE_TO_USERS_PUBLIC is still true (cutover step 3).\n');
      return 1;
    }
  }
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();
  process.stdout.write(`Profile showcase privacy migration — ${options.mode}${options.apply ? ' (apply)' : options.mode === 'verify' ? '' : ' (dry run)'}\n`);

  const counts = { athletes: 0, withLegacy: 0, toCopy: 0, toStrip: 0, copied: 0, stripped: 0, missingPrivate: 0 };
  let last = null;
  for (;;) {
    let q = db.collection('users_public').orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE);
    if (last) q = q.startAfter(last);
    const page = await q.get();
    if (page.empty) break;
    const privSnaps = await db.getAll(...page.docs.map((d) => db.collection('users_showcase').doc(d.id)));
    for (let i = 0; i < page.docs.length; i += 1) {
      const pub = page.docs[i].data();
      const priv = privSnaps[i].exists ? privSnaps[i].data() : null;
      counts.athletes += 1;
      if (FIELDS.some((f) => f in pub)) counts.withLegacy += 1;
      const plan = planAthlete(options.mode === 'verify' ? 'strip' : options.mode, pub, priv);
      if (Object.keys(plan.copy).length) counts.toCopy += 1;
      if (plan.strip.length) counts.toStrip += 1;
      if (FIELDS.some((f) => pub[f]) && !FIELDS.some((f) => priv && priv[f])) counts.missingPrivate += 1;
      if (options.apply && (Object.keys(plan.copy).length || plan.strip.length)) {
        const r = await migrateOne(db, admin, page.docs[i].id, options.mode);
        if (r.copied.length) counts.copied += 1;
        if (r.stripped.length) counts.stripped += 1;
      }
    }
    last = page.docs[page.docs.length - 1];
    if (page.size < PAGE) break;
  }
  process.stdout.write(`${JSON.stringify(counts, null, 2)}\n`);
  if (options.mode === 'verify') {
    const clean = counts.withLegacy === 0;
    process.stdout.write(`Verification: ${clean ? 'CLEAN (no showcase on users_public)' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }
  if (!options.apply) process.stdout.write('Dry run only. Re-run with --apply.\n');
  return 0;
}

module.exports = { FIELDS, parseArgs, planAthlete, migrateOne };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nProfile showcase migration failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
