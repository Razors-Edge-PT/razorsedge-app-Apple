'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

// A multi-segment wildcard covers block documents and every nested document
// below them (weeks, days, block_data, and any future subcollections).
const LEGACY_PATTERN =
  'planned_blocks/{userId}/blocks/{document=**}';
const CANONICAL_PATTERN =
  'users/{userId}/planned_blocks/{document=**}';

function validatePathParts(userId, document) {
  if (typeof userId !== 'string' || userId.length === 0 || userId.includes('/')) {
    throw new Error('Invalid planned-blocks mirror userId');
  }
  if (typeof document !== 'string' || document.length === 0) {
    throw new Error('Invalid planned-blocks mirror document path');
  }
  const segments = document.split('/');
  if (segments.some((part) => part.length === 0) || segments.length % 2 === 0) {
    throw new Error(`Invalid planned-blocks relative document path: ${document}`);
  }
}

function canonicalDocumentPath(userId, document) {
  validatePathParts(userId, document);
  return `users/${userId}/planned_blocks/${document}`;
}

function legacyDocumentPath(userId, document) {
  validatePathParts(userId, document);
  return `planned_blocks/${userId}/blocks/${document}`;
}

async function mirrorChange(event, destinationPathFor, firestore = db) {
  const userId = event.params?.userId;
  const document = event.params?.document;
  const destinationPath = destinationPathFor(userId, document);
  const after = event.data?.after;

  if (!after) {
    logger.warn('Planned-blocks mirror received an event without data', {
      userId,
      document,
      eventId: event.id,
    });
    return;
  }

  const destination = firestore.doc(destinationPath);
  if (after.exists) {
    // Full replacement keeps the two document shapes identical, including
    // field removals. Firestore does not emit another event for a no-op write,
    // which terminates the echo from the opposite-direction trigger.
    await destination.set(after.data(), { merge: false });
  } else {
    await destination.delete();
  }
}

const mirrorLegacyPlannedBlocksToUsers = onDocumentWritten(
  { document: LEGACY_PATTERN, retry: true },
  (event) => mirrorChange(event, canonicalDocumentPath),
);

const mirrorUserPlannedBlocksToLegacy = onDocumentWritten(
  { document: CANONICAL_PATTERN, retry: true },
  (event) => mirrorChange(event, legacyDocumentPath),
);

module.exports = {
  mirrorLegacyPlannedBlocksToUsers,
  mirrorUserPlannedBlocksToLegacy,
  _internals: {
    LEGACY_PATTERN,
    CANONICAL_PATTERN,
    canonicalDocumentPath,
    legacyDocumentPath,
    mirrorChange,
    validatePathParts,
  },
};
