#!/usr/bin/env node
'use strict';

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';

function usage() {
  return [
    'Planned-blocks hierarchy migration',
    '',
    'Dry-run all users (default):',
    '  npm run migrate:planned-blocks -- --project goodlift-us-storage',
    '',
    'Dry-run one user first:',
    '  npm run migrate:planned-blocks -- --project goodlift-us-storage --uid <uid>',
    '',
    'Copy without deleting the legacy data:',
    '  npm run migrate:planned-blocks -- --project goodlift-us-storage --uid <uid> --execute',
    '',
    'Verify source documents all exist identically at the canonical path:',
    '  npm run migrate:planned-blocks -- --project goodlift-us-storage --uid <uid> --verify',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uid: null,
    execute: false,
    verify: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--execute') out.execute = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  if (!out.projectId) throw new Error('--project requires a value');
  if (out.uid != null && out.uid.length === 0) {
    throw new Error('--uid requires a value');
  }
  if (out.execute && out.verify) {
    throw new Error('Choose either --execute or --verify, not both');
  }
  return out;
}

function stableFirestoreValue(value) {
  if (value == null || typeof value !== 'object') return value;

  if (Buffer.isBuffer(value)) {
    return { __type: 'bytes', value: value.toString('base64') };
  }
  if (typeof value.toMillis === 'function' &&
      typeof value.seconds === 'number' &&
      typeof value.nanoseconds === 'number') {
    return {
      __type: 'timestamp',
      seconds: value.seconds,
      nanoseconds: value.nanoseconds,
    };
  }
  if (typeof value.latitude === 'number' &&
      typeof value.longitude === 'number') {
    return {
      __type: 'geopoint',
      latitude: value.latitude,
      longitude: value.longitude,
    };
  }
  if (typeof value.path === 'string' && value.firestore) {
    return { __type: 'reference', path: value.path };
  }
  if (Array.isArray(value)) return value.map(stableFirestoreValue);

  const out = {};
  for (const key of Object.keys(value).sort()) {
    out[key] = stableFirestoreValue(value[key]);
  }
  return out;
}

function documentsEqual(left, right) {
  return JSON.stringify(stableFirestoreValue(left)) ===
    JSON.stringify(stableFirestoreValue(right));
}

function newStats() {
  return {
    sourceDocuments: 0,
    identical: 0,
    wouldCreate: 0,
    created: 0,
    missing: 0,
    conflicts: [],
    orphanUsers: [],
  };
}

async function compareOrCopyDocument(sourceRef, destinationRef, options, stats) {
  const [source, destination] = await Promise.all([
    sourceRef.get(),
    destinationRef.get(),
  ]);

  if (!source.exists) return;
  stats.sourceDocuments += 1;
  const sourceData = source.data();

  if (destination.exists) {
    if (documentsEqual(sourceData, destination.data())) {
      stats.identical += 1;
    } else {
      stats.conflicts.push({
        source: sourceRef.path,
        destination: destinationRef.path,
      });
    }
    return;
  }

  if (options.verify) {
    stats.missing += 1;
    return;
  }

  if (!options.execute) {
    stats.wouldCreate += 1;
    return;
  }

  await destinationRef.set(sourceData, { merge: false });
  stats.created += 1;
}

async function walkDocumentTree(sourceRef, destinationRef, options, stats) {
  await compareOrCopyDocument(sourceRef, destinationRef, options, stats);

  const subcollections = await sourceRef.listCollections();
  subcollections.sort((a, b) => a.id.localeCompare(b.id));
  for (const sourceCollection of subcollections) {
    const childRefs = await sourceCollection.listDocuments();
    childRefs.sort((a, b) => a.id.localeCompare(b.id));
    for (const childSource of childRefs) {
      const childDestination = destinationRef
        .collection(sourceCollection.id)
        .doc(childSource.id);
      await walkDocumentTree(
        childSource,
        childDestination,
        options,
        stats,
      );
    }
  }
}

async function migrateUser(db, uid, options, stats) {
  const userRef = db.collection('users').doc(uid);
  const user = await userRef.get();
  if (!user.exists) {
    stats.orphanUsers.push(uid);
    return;
  }

  const legacyBlocks = await db
    .collection('planned_blocks')
    .doc(uid)
    .collection('blocks')
    .listDocuments();
  legacyBlocks.sort((a, b) => a.id.localeCompare(b.id));

  for (const legacyBlock of legacyBlocks) {
    const canonicalBlock = userRef.collection('planned_blocks').doc(legacyBlock.id);
    await walkDocumentTree(legacyBlock, canonicalBlock, options, stats);
  }
}

async function discoverUids(db) {
  const [userRefs, legacyRefs] = await Promise.all([
    db.collection('users').listDocuments(),
    db.collection('planned_blocks').listDocuments(),
  ]);
  return [...new Set([...userRefs, ...legacyRefs].map((ref) => ref.id))].sort();
}

function printSummary(mode, projectId, uids, stats) {
  console.log(JSON.stringify({
    mode,
    projectId,
    usersExamined: uids.length,
    sourceDocuments: stats.sourceDocuments,
    identical: stats.identical,
    wouldCreate: stats.wouldCreate,
    created: stats.created,
    missing: stats.missing,
    conflicts: stats.conflicts,
    orphanUsers: stats.orphanUsers,
    legacyDataDeleted: false,
  }, null, 2));
}

async function run(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(usage());
    return 0;
  }

  const mode = options.execute ? 'EXECUTE_COPY' :
    options.verify ? 'VERIFY_ONLY' : 'DRY_RUN';
  console.log(`${mode}: ${options.projectId}`);
  console.log(
    'Legacy documents are never deleted. Deploy the compatibility mirror before copying.',
  );

  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();
  const uids = options.uid ? [options.uid] : await discoverUids(db);
  const stats = newStats();

  for (const uid of uids) {
    console.log(`${mode}: ${uid}`);
    await migrateUser(db, uid, options, stats);
  }
  printSummary(mode, options.projectId, uids, stats);

  if (stats.conflicts.length > 0 || stats.orphanUsers.length > 0) return 2;

  if (options.execute) {
    const verifyOptions = { ...options, execute: false, verify: true };
    const verifyStats = newStats();
    for (const uid of uids) {
      await migrateUser(db, uid, verifyOptions, verifyStats);
    }
    printSummary('POST_COPY_VERIFY', options.projectId, uids, verifyStats);
    if (verifyStats.missing > 0 ||
        verifyStats.conflicts.length > 0 ||
        verifyStats.orphanUsers.length > 0) {
      return 3;
    }
  }

  if (options.verify && stats.missing > 0) return 4;
  return 0;
}

if (require.main === module) {
  run()
    .then((code) => { process.exitCode = code; })
    .catch((error) => {
      console.error(error && error.stack ? error.stack : error);
      process.exitCode = 1;
    });
}

module.exports = {
  _internals: {
    DEFAULT_PROJECT_ID,
    parseArgs,
    stableFirestoreValue,
    documentsEqual,
    newStats,
    compareOrCopyDocument,
    walkDocumentTree,
    migrateUser,
    discoverUids,
  },
};
