#!/usr/bin/env node
'use strict';

// Owner-scoped and dry-run by default. Uses existing ADC and a local ffmpeg;
// no new cloud service, dependency or public access policy is needed.
// node scripts/repair_post_thumbnails.js --username coded_nz [--apply]
const { repairPoster } = require('../profile/post_thumbnails');

function argumentsFor(argv) {
  const opts = { apply: false, limit: 10 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--apply') opts.apply = true;
    else if (arg === '--username' || arg === '--post-id' || arg === '--limit') {
      const value = argv[++i];
      if (!value || value.startsWith('--')) throw new Error(`Missing value for ${arg}`);
      opts[arg.slice(2)] = value;
    } else throw new Error(`Unknown argument ${arg}`);
  }
  opts.username = String(opts.username || '').replace(/^@/, '').trim();
  opts.limit = Number(opts.limit);
  if (!opts.username || !Number.isInteger(opts.limit) || opts.limit < 1 || opts.limit > 50) {
    throw new Error('Specify --username and a --limit from 1 to 50 (default 10).');
  }
  return opts;
}

async function main() {
  const opts = argumentsFor(process.argv.slice(2));
  const admin = require('firebase-admin');
  const { getDownloadURL } = require('firebase-admin/storage');
  const projectId = 'goodlift-us-storage';
  admin.initializeApp({ projectId, credential: admin.credential.applicationDefault(),
    storageBucket: 'goodlift-us-storage.firebasestorage.app' });
  const db = admin.firestore();
  const owners = await db.collection('users_public').where('username', '==', opts.username).limit(2).get();
  if (owners.size !== 1) throw new Error('Username did not resolve to exactly one account. No changes made.');
  const ownerUid = owners.docs[0].id;
  // Explicit post-id avoids any ordering/index assumptions for the reported
  // post; otherwise process a bounded page of this owner's video posts.
  let docs;
  if (opts['post-id']) {
    const doc = await db.collection('posts').doc(opts['post-id']).get();
    if (!doc.exists || doc.data().ownerUid !== ownerUid) throw new Error('Post does not belong to the selected account.');
    docs = [doc];
  } else {
    const posts = await db.collection('posts').where('ownerUid', '==', ownerUid).limit(200).get();
    docs = posts.docs.filter((doc) => doc.data().mediaType === 'video')
      .sort((a, b) => (b.data().createdAt?.toMillis?.() || 0) - (a.data().createdAt?.toMillis?.() || 0))
      .slice(0, opts.limit);
  }
  const bucket = admin.storage().bucket();
  console.log(`${opts.apply ? 'APPLY' : 'DRY RUN'}: ${docs.length} video posts for @${opts.username}`);
  for (const doc of docs) {
    const result = await repairPoster({ db, bucket, postId: doc.id, data: doc.data(),
      apply: opts.apply, downloadUrl: getDownloadURL });
    console.log(`${result.postId}: ${result.status}`);
  }
}

if (require.main === module) main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
module.exports = { argumentsFor };
