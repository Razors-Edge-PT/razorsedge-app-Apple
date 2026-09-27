#!/usr/bin/env node
'use strict';

// ONE ACCOUNT, ONE FLAG: grants the support profile + DM override.
//
//   accessGrants/{uid} { profileAndDmOverride: true }
//
// Server-owned (firestore.rules forbids every client write), so the holder can
// neither self-assign it nor pass it on. It lets the holder read other
// profiles as a friend would, and hold a one-to-one conversation with anyone;
// it grants no write to anybody else's data and changes no friendship. See
// firestore.rules hasProfileDmOverride() and social/access_grants.js.
//
//   node scripts/grant_profile_dm_override.js                (dry run)
//   node scripts/grant_profile_dm_override.js --apply        (writes)
//   node scripts/grant_profile_dm_override.js --verify       (after apply)
//
// SAFETY
//   * Dry run by default. The only account it will ever write is ALLOWED_UID.
//   * Merges the flag into any existing grant document; never replaces or
//     removes another field, and never touches Auth custom claims (they are
//     read and reported, unchanged).
//   * Before a write, the previous document and claims are saved as a JSON
//     backup OUTSIDE the repository (BACKUP_ROOT).
//   * Idempotent: an account already holding the flag is left untouched.
//   * --verify fails unless the grant is present for ALLOWED_UID and NO other
//     account holds the flag (in particular not the cue-QA test account).

const fs = require('fs');
const os = require('os');
const path = require('path');

const G = require('../social/access_grants');

/** Richard's main account — the only account this script may grant. */
const ALLOWED_UID = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
/** The cue-QA test account; must never hold the override. */
const TEST_ACCOUNT_UID = 'jhIB7Yi1whYwPvBSmK27KltJGn23';
const PROJECT_ID = 'goodlift-us-storage';
const BACKUP_ROOT = path.join(os.homedir(), 'GoodLift-migration-backups');

function parseArgs(argv) {
  const out = { apply: false, verify: false };
  for (const a of argv) {
    if (a === '--apply') out.apply = true;
    else if (a === '--verify') out.verify = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify');
  return out;
}

/** What the grant document must contain after a merge write. */
function plannedGrant(existing) {
  const before = existing || {};
  const already = before[G.FIELD_PROFILE_DM_OVERRIDE] === true;
  return { already, patch: already ? null : { [G.FIELD_PROFILE_DM_OVERRIDE]: true } };
}

/** Every account whose grant document carries the flag. */
async function holders(db) {
  const snap = await db.collection(G.COL_ACCESS_GRANTS)
    .where(G.FIELD_PROFILE_DM_OVERRIDE, '==', true).get();
  return snap.docs.map((d) => d.id).sort();
}

async function run(opts, { admin, log = console.log } = {}) {
  const db = admin.firestore();
  const ref = db.collection(G.COL_ACCESS_GRANTS).doc(ALLOWED_UID);
  const [snap, user] = await Promise.all([
    ref.get(),
    admin.auth().getUser(ALLOWED_UID),
  ]);
  const existing = snap.exists ? snap.data() : null;
  const claims = user.customClaims || {};
  log(`account: ${ALLOWED_UID} (${user.email || 'no email'})`);
  log(`existing grant document: ${JSON.stringify(existing)}`);
  log(`custom claims (read only, never changed): ${JSON.stringify(claims)}`);

  if (opts.verify) {
    const who = await holders(db);
    const ok = who.length === 1 && who[0] === ALLOWED_UID
      && !who.includes(TEST_ACCOUNT_UID);
    const holds = await G.hasProfileDmOverride(db, ALLOWED_UID);
    const testHolds = await G.hasProfileDmOverride(db, TEST_ACCOUNT_UID);
    log(`holders of ${G.FIELD_PROFILE_DM_OVERRIDE}: ${JSON.stringify(who)}`);
    log(`ALLOWED_UID holds: ${holds}; test account holds: ${testHolds}`);
    if (!ok || !holds || testHolds) throw new Error('VERIFY FAILED');
    log('VERIFY OK');
    return { verified: true, holders: who };
  }

  const plan = plannedGrant(existing);
  if (plan.already) {
    log('already granted — nothing to do (idempotent)');
    return { changed: false };
  }
  log(`planned merge: ${JSON.stringify(plan.patch)}`);
  if (!opts.apply) {
    log('DRY RUN — re-run with --apply to write');
    return { changed: false, dryRun: true };
  }

  fs.mkdirSync(BACKUP_ROOT, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backup = path.join(BACKUP_ROOT, `accessGrant_${ALLOWED_UID}_${stamp}.json`);
  fs.writeFileSync(backup, JSON.stringify({
    uid: ALLOWED_UID, grantDocument: existing, customClaims: claims, at: stamp,
  }, null, 2));
  log(`backup: ${backup}`);

  await ref.set(Object.assign({}, plan.patch, {
    grantedAt: admin.firestore.FieldValue.serverTimestamp(),
    grantedBy: 'scripts/grant_profile_dm_override.js',
  }), { merge: true });
  log('applied');
  return { changed: true, backup };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  // eslint-disable-next-line global-require
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: PROJECT_ID });
  await run(opts, { admin });
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e && e.message ? e.message : e);
    process.exit(1);
  });
}

module.exports = {
  ALLOWED_UID, TEST_ACCOUNT_UID, parseArgs, plannedGrant, holders, run,
};
