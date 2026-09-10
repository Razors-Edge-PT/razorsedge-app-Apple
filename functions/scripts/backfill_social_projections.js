#!/usr/bin/env node
'use strict';

// Builds socialGraph/{uid} and users/{uid}/feed for accounts that already
// exist.
//
// WHY THIS IS NEEDED
//   feedOnBuddyAssignmentWritten maintains the confirmed-friend projection and
//   feedOnPostWritten fans out posts — but both are TRIGGERS. They fire on a
//   write. An account whose buddyAssignments document has not been touched
//   since the functions were deployed has no socialGraph document at all, and
//   a post published before the deploy was never fanned out to anybody.
//
//   The client reads BuddyRepository.watchFriends() from socialGraph and the
//   feed from users/{uid}/feed, so without this every existing user opens the
//   Buddy Hub to an empty buddy list and an empty feed, however many friends
//   and posts they actually have. The authority is right; nothing has
//   projected it yet.
//
// SAFETY CONTRACT
//   * Writes ONLY the two projections: socialGraph/{uid} and
//     users/{uid}/feed/{ownerUid__postId}. It never touches buddyAssignments,
//     posts, users, users_public, invites or media.
//   * Uses recomputeFriends() and backfillInto() from ../social/feed.js — the
//     SAME functions the triggers use. There is no second copy of the
//     projection logic here to drift from them.
//   * Idempotent. recomputeFriends derives the friend list from both
//     assignment documents and writes only when it changed; backfillInto
//     writes feed rows under a DERIVED id ({ownerUid}__{postId}), so a second
//     run replaces the same rows with the same content.
//   * A projection is a cache, not an authority. No security rule reads
//     either collection, so a wrong value here cannot grant access — it can
//     only make a feed look stale until the next run or the next trigger.
//
// ORDER
//   Run AFTER the functions are deployed and after any one-sided cleanup, so
//   what gets projected is the final authority rather than a state that is
//   about to change.
//
// Modes:
//   (default)  dry-run — report what each account would get, write nothing
//   --apply            — write the projections
//   --verify           — use scripts/verify_social_projections.js instead
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account.

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';

function usage() {
  return [
    'Backfill socialGraph and feed projections for existing accounts',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/backfill_social_projections.js --project goodlift-us-storage',
    '',
    'Apply:',
    '  node scripts/backfill_social_projections.js --project goodlift-us-storage --apply',
    '',
    'Then verify:',
    '  node scripts/verify_social_projections.js --project goodlift-us-storage',
    '',
    'Writes only socialGraph/{uid} and users/{uid}/feed. Nothing else.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    apply: false,
    uid: null,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return out;
}

/**
 * Every account that could need a projection.
 *
 * The union of users_public (everybody who can post) and buddyAssignments
 * (everybody who can have a friend). users_public alone would miss an account
 * with friendships but no published profile; buddyAssignments alone would miss
 * a user with no friends, who still needs their OWN posts in their own feed.
 */
async function accountUniverse(db) {
  const [pub, assign] = await Promise.all([
    db.collection('users_public').select().get(),
    db.collection('buddyAssignments').select().get(),
  ]);
  const uids = new Set();
  for (const d of pub.docs) uids.add(d.id);
  for (const d of assign.docs) uids.add(d.id);
  return [...uids].sort();
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n\n${usage()}\n`);
    process.exitCode = 2;
    return;
  }
  if (args.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }

  admin.initializeApp({ projectId: args.projectId });
  const db = admin.firestore();

  // Required AFTER initializeApp: the module reaches for admin.firestore() at
  // call time, and the trigger definitions it builds at import are inert here.
  // eslint-disable-next-line global-require
  const feed = require('../social/feed');

  const mode = args.apply ? 'APPLY' : 'DRY RUN';
  process.stdout.write(
    `backfill_social_projections — ${mode} on ${args.projectId}\n\n`,
  );

  const uids = args.uid ? [args.uid] : await accountUniverse(db);
  process.stdout.write(`accounts to process : ${uids.length}\n\n`);

  const counts = {
    scanned: 0,
    graphsWritten: 0,
    graphsUnchanged: 0,
    withFriends: 0,
    feedRowsWritten: 0,
    ownPostRows: 0,
  };
  const errors = [];

  for (const uid of uids) {
    counts.scanned += 1;
    try {
      if (!args.apply) {
        // Dry run: compute what the friend list WOULD be, without writing.
        // recomputeFriends writes, so the read-only path is done here from the
        // same two documents it reads.
        // eslint-disable-next-line no-await-in-loop
        const own = await db.collection('buddyAssignments').doc(uid).get();
        const athletes =
          own.exists && own.data().athletes && typeof own.data().athletes === 'object'
            ? own.data().athletes
            : {};
        const candidates = Object.keys(athletes).filter(
          (o) => o !== uid && athletes[o] && athletes[o].status === 'accepted',
        );
        // eslint-disable-next-line no-await-in-loop
        const others = await Promise.all(
          candidates.map((o) => db.collection('buddyAssignments').doc(o).get()),
        );
        const confirmed = candidates.filter((o, i) => {
          const d = others[i].exists ? others[i].data() : null;
          const a = d && d.athletes ? d.athletes[uid] : null;
          return a && a.status === 'accepted';
        });
        if (confirmed.length > 0) counts.withFriends += 1;
        // eslint-disable-next-line no-await-in-loop
        const ownPosts = await feed.recentEligiblePosts(db, uid, 30);
        counts.ownPostRows += ownPosts.length;
        process.stdout.write(
          `  ${uid}  friends=${confirmed.length}  ownPosts=${ownPosts.length}\n`,
        );
        continue;
      }

      // Apply: the trigger's own function, so a backfilled projection and a
      // trigger-written one are identical by construction.
      // eslint-disable-next-line no-await-in-loop
      const { previous, next } = await feed.recomputeFriends(db, uid);
      const friends = [...next];
      if (friends.length > 0) counts.withFriends += 1;
      const changed =
        previous.size !== next.size || friends.some((f) => !previous.has(f));
      if (changed) counts.graphsWritten += 1;
      else counts.graphsUnchanged += 1;

      // The viewer's OWN posts. audienceFor() includes the owner on every post
      // write, but a post published before the trigger existed never went
      // through it.
      // eslint-disable-next-line no-await-in-loop
      const ownRows = await feed.backfillInto(db, uid, uid);
      counts.ownPostRows += ownRows;
      counts.feedRowsWritten += ownRows;

      for (const friendUid of friends) {
        // eslint-disable-next-line no-await-in-loop
        const rows = await feed.backfillInto(db, uid, friendUid);
        counts.feedRowsWritten += rows;
      }

      if (friends.length > 0 || ownRows > 0) {
        process.stdout.write(
          `  ${uid}  friends=${friends.length}  ownRows=${ownRows}\n`,
        );
      }
    } catch (err) {
      errors.push({ uid, message: err.message });
    }
    if (counts.scanned % 25 === 0) {
      process.stdout.write(`  ... ${counts.scanned} processed\n`);
    }
  }

  process.stdout.write(`\naccounts processed      : ${counts.scanned}\n`);
  process.stdout.write(`accounts with friends   : ${counts.withFriends}\n`);
  if (args.apply) {
    process.stdout.write(`socialGraph written     : ${counts.graphsWritten}\n`);
    process.stdout.write(`socialGraph unchanged   : ${counts.graphsUnchanged}\n`);
    process.stdout.write(`feed rows written       : ${counts.feedRowsWritten}\n`);
  }
  process.stdout.write(`own-post rows           : ${counts.ownPostRows}\n`);
  process.stdout.write(`errors                  : ${errors.length}\n`);
  for (const e of errors.slice(0, 20)) {
    process.stderr.write(`  ${e.uid}: ${e.message}\n`);
  }

  if (errors.length > 0) {
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    args.apply
      ? '\nDone. Run scripts/verify_social_projections.js to confirm.\n'
      : '\nDRY RUN — nothing was written. Re-run with --apply.\n',
  );
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.stack ? err.stack : err}\n`);
    process.exitCode = 1;
  });
}

module.exports = { accountUniverse };
