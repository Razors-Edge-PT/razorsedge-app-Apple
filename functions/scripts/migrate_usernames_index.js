#!/usr/bin/env node
'use strict';

// Backfills the case-insensitive username uniqueness index.
//
//   usernames/{sha256(normalisedName)} → { uid, username, usernameLower }
//
// Existing accounts were written before the index existed, so until every one
// of them holds a reservation the index cannot be trusted to prove uniqueness.
//
// SAFETY CONTRACT
//   * Never renames a user. A collision is REPORTED and both accounts are left
//     exactly as they are — the operator decides.
//   * Never deletes a reservation that belongs to a different uid.
//   * Idempotent and resumable: re-running skips reservations that already
//     hold the correct uid, so an interrupted run is finished by re-running.
//   * Reads users_public and users; writes ONLY the usernames collection.
//
// Modes:
//   (default)  dry-run   — report what would change, write nothing
//   --apply              — write the reservations
//   --verify             — assert every account resolves to its own reservation
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account. Nothing is ever printed that could reveal a credential.

const admin = require('firebase-admin');
const {
  normalizeUsername,
  displayUsername,
  validateUsername,
  usernameIndexKey,
} = require('../identity/username_rules');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const USERNAMES = 'usernames';

function usage() {
  return [
    'Username uniqueness index backfill',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/migrate_usernames_index.js --project goodlift-us-storage',
    '',
    'Apply:',
    '  node scripts/migrate_usernames_index.js --project goodlift-us-storage --apply',
    '',
    'Verify:',
    '  node scripts/migrate_usernames_index.js --project goodlift-us-storage --verify',
    '',
    'A collision is never resolved automatically: both accounts keep their',
    'names and the run reports the clash for a human to settle.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = { projectId: DEFAULT_PROJECT_ID, apply: false, verify: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  return out;
}

/**
 * Reads every account's claimed identity.
 * users_public is the authoritative search index; users is the private mirror.
 * Either may carry the name, so both are read and users_public wins.
 */
async function loadAccounts(db) {
  const accounts = new Map(); // uid -> { uid, username, source }
  for (const col of ['users_public', 'users']) {
    const snap = await db.collection(col).get();
    for (const doc of snap.docs) {
      const d = doc.data() || {};
      const raw = d.username || d.usernameLower || '';
      if (!raw) continue;
      const existing = accounts.get(doc.id);
      // users_public is read first and wins; users only fills the gaps.
      if (existing && existing.source === 'users_public') continue;
      accounts.set(doc.id, { uid: doc.id, username: raw, source: col });
    }
  }
  return [...accounts.values()];
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }

  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();

  const mode = options.verify ? 'verify' : options.apply ? 'apply' : 'dry-run';
  process.stdout.write(`Username index migration — mode: ${mode}\n`);
  process.stdout.write(`Project: ${options.projectId}\n\n`);

  const accounts = await loadAccounts(db);
  process.stdout.write(`Accounts with a username: ${accounts.length}\n`);

  // Group by normalised name to find collisions BEFORE touching anything.
  const byNormalized = new Map();
  const invalid = [];
  for (const acct of accounts) {
    const lower = normalizeUsername(acct.username);
    const validation = validateUsername(acct.username);
    if (!validation.ok) {
      invalid.push({ uid: acct.uid, username: acct.username, reason: validation.code });
      // An invalid legacy name is still indexed so it stays unique; it is only
      // NEW names that must pass validation. Reported, not skipped.
    }
    if (!lower) continue;
    if (!byNormalized.has(lower)) byNormalized.set(lower, []);
    byNormalized.get(lower).push(acct);
  }

  const collisions = [...byNormalized.entries()].filter(([, list]) => list.length > 1);

  const counts = {
    accounts: accounts.length,
    distinctNames: byNormalized.size,
    collisionGroups: collisions.length,
    collidingAccounts: collisions.reduce((n, [, list]) => n + list.length, 0),
    invalidLegacyNames: invalid.length,
    alreadyIndexed: 0,
    toWrite: 0,
    written: 0,
    conflicts: 0,
    verifiedOk: 0,
    verifiedMissing: 0,
    verifiedWrongOwner: 0,
    skippedByCollision: 0,
  };

  if (collisions.length) {
    process.stdout.write('\nCOLLISIONS (no account is renamed — resolve by hand):\n');
    for (const [lower, list] of collisions) {
      process.stdout.write(
        `  "${lower}" held by ${list.length}: ${list.map((a) => a.uid).join(', ')}\n`,
      );
    }
  }
  if (invalid.length) {
    process.stdout.write('\nLEGACY NAMES THAT WOULD FAIL TODAY\'S VALIDATION (indexed anyway):\n');
    for (const item of invalid.slice(0, 50)) {
      process.stdout.write(`  ${item.uid}: ${item.reason}\n`);
    }
    if (invalid.length > 50) process.stdout.write(`  ...and ${invalid.length - 50} more\n`);
  }

  let batch = db.batch();
  let batched = 0;
  const commit = async () => {
    if (!batched) return;
    await batch.commit();
    batch = db.batch();
    batched = 0;
  };

  for (const [lower, list] of byNormalized) {
    const key = usernameIndexKey(lower);
    const ref = db.collection(USERNAMES).doc(key);
    const snap = await ref.get();
    const existing = snap.exists ? snap.data() : null;

    if (list.length > 1) {
      // Contested name. Leave the index alone entirely: writing either uid
      // would silently declare a winner.
      counts.skippedByCollision += list.length;
      continue;
    }

    const acct = list[0];
    if (existing && existing.uid === acct.uid) {
      counts.alreadyIndexed += 1;
      if (options.verify) counts.verifiedOk += 1;
      continue;
    }
    if (existing && existing.uid !== acct.uid) {
      counts.conflicts += 1;
      process.stdout.write(
        `  CONFLICT "${lower}": index holds ${existing.uid}, account is ${acct.uid} — left untouched\n`,
      );
      if (options.verify) counts.verifiedWrongOwner += 1;
      continue;
    }

    if (options.verify) {
      counts.verifiedMissing += 1;
      continue;
    }

    counts.toWrite += 1;
    if (options.apply) {
      batch.set(
        ref,
        {
          uid: acct.uid,
          username: displayUsername(acct.username),
          usernameLower: lower,
          backfilledAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      batched += 1;
      counts.written += 1;
      if (batched >= 400) await commit();
    }
  }
  await commit();

  process.stdout.write('\nCOUNTS\n');
  for (const [k, v] of Object.entries(counts)) {
    process.stdout.write(`  ${k}: ${v}\n`);
  }

  if (options.verify) {
    const clean =
      counts.verifiedMissing === 0 &&
      counts.verifiedWrongOwner === 0 &&
      counts.collisionGroups === 0;
    process.stdout.write(`\nVerification: ${clean ? 'CLEAN' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }

  if (!options.apply) {
    process.stdout.write('\nDry run only. Re-run with --apply to write.\n');
  }
  // A collision is a warning the operator must see, not a silent success.
  return counts.collisionGroups > 0 ? 2 : 0;
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    process.stderr.write(`\nMigration failed: ${err && err.message}\n`);
    process.exit(1);
  });
