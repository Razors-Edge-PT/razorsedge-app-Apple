#!/usr/bin/env node
'use strict';

// Populate the newly derived sex boards immediately after deployment instead
// of waiting for the hourly publisher. Writes only derived leaderboard board
// documents and public snapshots; no profiles, raw entries or scores change.
async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 3 || args[0] !== '--project' || args[1] !== 'goodlift-us-storage' || args[2] !== '--apply') {
    throw new Error('Usage: node scripts/publish_leaderboard_filters.js --project goodlift-us-storage --apply');
  }
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: args[1], credential: admin.credential.applicationDefault() });
  const { publishAll } = require('../leaderboard/age_firestore');
  console.log(JSON.stringify(await publishAll(Date.now()), null, 2));
}

if (require.main === module) main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
