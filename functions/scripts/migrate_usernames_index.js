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
//   --reconcile          repair INDEX DRIFT: delete reservations whose stated
//                        owner no longer displays that name. Combine with
//                        --apply to actually delete; on its own it reports.
//
// DRIFT is what a client write that skipped the reservation service leaves
// behind. firestore.rules still permits exactly one of those -- a pre-1.7.13
// build stamping its FIRST username during signup -- and
// identityOnPublicProfileWritten reconciles each one as it lands. --reconcile
// is the catch-up pass for everything written before that trigger existed.
//
// Reconcile only ever DELETES a reservation whose stated owner has since moved
// to a different name. It still never renames an account: an account whose
// displayed name is reserved to somebody else is REPORTED, because deciding
// which of two real people keeps a name is not a script's call.
//
//   (default)  dry-run   — report what would change, write nothing
//   --apply              — write the reservations
//   --verify             — assert every account resolves to its own reservation
//   --reconcile          — repair INDEX DRIFT: delete reservations whose owner
//                          no longer displays that name. Combine with --apply
//                          to actually delete; on its own it reports.
//
// DRIFT is what a client write that skipped the reservation service leaves
// behind. firestore.rules still permits exactly one of those — a pre-1.7.13
// build stamping its FIRST username during signup — and
// identityOnPublicProfileWritten reconciles each one as it lands. This mode is
// the catch-up pass for everything written before that trigger existed.
//
// Reconcile only ever DELETES a reservation whose stated owner has since moved
// to a different name. It still never renames an account: an account whose
// displayed name is reserved to somebody else is REPORTED, because deciding
// which of two real people keeps a name is not a script's call.
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
    'Reconcile index drift (report only; add --apply to delete stale keys):',
    '  node scripts/migrate_usernames_index.js --project goodlift-us-storage --reconcile',
    '',
    'A collision is never resolved automatically: both accounts keep their',
    'names and the run reports the clash for a human to settle.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    apply: false,
    verify: false,
    reconcile: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--reconcile') out.reconcile = true;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  if (out.reconcile && out.verify) throw new Error('Choose either --reconcile or --verify, not both');
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

/**
 * Repairs index DRIFT: a reservation whose stated owner has since moved to a
 * different name, left behind by a client write that never went through the
 * reservation service.
 *
 * Deleting one of these is always safe. The reservation asserts "uid X holds
 * name N"; X's own documents say X displays something else, so the assertion
 * is already false, and the only thing the stale key still achieves is keeping
 * N unclaimable forever.
 *
 * The opposite drift — an account DISPLAYING a name the index assigns to
 * somebody else — is reported and never repaired here. Both parties are real
 * accounts and resolving it means renaming one of them, which is the
 * operator's decision rather than this script's.
 * identityOnPublicProfileWritten resolves that case for every claim made from
 * now on.
 */
async function reconcileDrift(db, accounts, counts, apply) {
  const displayedLowerByUid = new Map();
  for (const acct of accounts) {
    displayedLowerByUid.set(acct.uid, normalizeUsername(acct.username));
  }

  process.stdout.write('\nDRIFT RECONCILIATION\n');

  const snap = await db.collection(USERNAMES).get();

  const stale = [];
  const owners = new Map();
  for (const doc of snap.docs) {
    const d = doc.data() || {};
    if (!d.uid) continue; // contested marker — owned by nobody, left alone
    const reservedLower = normalizeUsername(d.usernameLower || d.username || '');
    if (!reservedLower) continue;
    owners.set(reservedLower, d.uid);

    const displayed = displayedLowerByUid.get(d.uid);
    if (displayed === undefined) {
      // The account carries no username at all any more (or was deleted). The
      // reservation is asserting something untrue either way.
      stale.push({ ref: doc.ref, uid: d.uid, reservedLower, displayed: '(none)' });
    } else if (displayed !== reservedLower) {
      stale.push({ ref: doc.ref, uid: d.uid, reservedLower, displayed });
    }
  }
  counts.driftStaleReservations = stale.length;

  for (const item of stale) {
    process.stdout.write(
      `  STALE "${item.reservedLower}" reserved to ${item.uid}, which now displays "${item.displayed}"\n`,
    );
  }

  if (apply && stale.length) {
    let batch = db.batch();
    let batched = 0;
    for (const item of stale) {
      batch.delete(item.ref);
      batched += 1;
      counts.driftStaleDeleted += 1;
      if (batched >= 400) {
        await batch.commit();
        batch = db.batch();
        batched = 0;
      }
    }
    if (batched) await batch.commit();
  }

  // The other direction: an account displaying a name it does not own.
  for (const acct of accounts) {
    const lower = normalizeUsername(acct.username);
    if (!lower) continue;
    const owner = owners.get(lower);
    if (owner && owner !== acct.uid) {
      counts.driftNameHeldByOther += 1;
      process.stdout.write(
        `  UNOWNED ${acct.uid} displays "${lower}", reserved to ${owner} — needs a human\n`,
      );
    }
  }

  if (!stale.length && !counts.driftNameHeldByOther) {
    process.stdout.write('  No drift found.\n');
  } else if (!apply) {
    process.stdout.write('  Report only. Add --apply to delete the stale reservations.\n');
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }

  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();

  const mode = options.verify
    ? 'verify'
    : options.reconcile
      ? (options.apply ? 'reconcile (writing)' : 'reconcile (report only)')
      : options.apply
        ? 'apply'
        : 'dry-run';
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
    contestedMarkers: 0,
    contestedWritten: 0,
    driftStaleReservations: 0,
    driftStaleDeleted: 0,
    driftNameHeldByOther: 0,
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
      // Contested name. NO account is declared the winner — that is the
      // operator's call, not this script's.
      //
      // But the key cannot simply be left empty either: the callable decides
      // uniqueness from this index alone, so an absent reservation would let a
      // BRAND-NEW signup claim a name four existing accounts already display.
      // So a BLOCKING marker is written instead: a document with no `uid`.
      // planUsernameChange() compares existingReservation.uid to the caller,
      // and `undefined !== callerUid` for everybody, so the name is refused to
      // every account — including the current holders, who keep the name they
      // already display and are only prevented from re-claiming it. The
      // contested uids are recorded on the document so the clash can be
      // settled by hand later.
      counts.skippedByCollision += list.length;
      counts.contestedMarkers += 1;
      if (existing && existing.uid) {
        // A real single owner is already indexed. Never replace that with a
        // block; report it and move on.
        process.stdout.write(
          `  CONTESTED "${lower}" already indexed to ${existing.uid} — left as is
`,
        );
        continue;
      }
      if (options.apply) {
        batch.set(
          ref,
          {
            usernameLower: lower,
            contested: true,
            contestedUids: list.map((a) => a.uid),
            backfilledAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        batched += 1;
        counts.contestedWritten += 1;
        if (batched >= 400) await commit();
      }
      continue;
    }

    const acct = list[0];
    if (existing && existing.contested === true && !existing.uid) {
      // Expected state for a contested name: blocked for everyone, owned by
      // nobody. Not a verification failure.
      continue;
    }
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

  if (options.reconcile) {
    await reconcileDrift(db, accounts, counts, options.apply);
  }

  process.stdout.write('\nCOUNTS\n');
  for (const [k, v] of Object.entries(counts)) {
    process.stdout.write(`  ${k}: ${v}\n`);
  }

  if (options.verify) {
    // A collision group is not a verification failure once it carries a
    // blocking marker: the index is CORRECT, it just records a clash nobody
    // has settled yet. Missing or wrongly-owned reservations still fail.
    const clean =
      counts.verifiedMissing === 0 && counts.verifiedWrongOwner === 0;
    process.stdout.write(`\nVerification: ${clean ? 'CLEAN' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }

  if (!options.apply) {
    process.stdout.write('\nDry run only. Re-run with --apply to write.\n');
  }
  // A collision, or a name an account displays but does not own, is a warning
  // the operator must see -- not a silent success.
  return counts.collisionGroups > 0 || counts.driftNameHeldByOther > 0 ? 2 : 0;
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    process.stderr.write(`\nMigration failed: ${err && err.message}\n`);
    process.exit(1);
  });
