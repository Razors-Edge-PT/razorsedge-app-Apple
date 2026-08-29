'use strict';

// CLI-level regression tests for the migration's PROCESS EXIT CODES.
//
// A pure projectGuard() test is not enough: the original defect was entirely in
// the wrapper. main() set `process.exitCode = 2`, then the wrapper ended with
// `.then(() => process.exit(0))`, which overrode it — so a refused run reported
// SUCCESS and no CI step or deploy script could detect the block.
//
// These tests therefore spawn the real script and assert the real status.
//
// Safety: every invocation here either aborts at the project guard before
// touching Firestore, or is redirected to the local emulator by
// FIRESTORE_EMULATOR_HOST. Nothing ever contacts the production project.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const migration = require('../migrate_coach_mode');

const SCRIPT = path.join(__dirname, '..', 'migrate_coach_mode.js');

/** Runs the migration CLI with a controlled environment. */
function runCli(args, env) {
  const base = Object.assign({}, process.env);
  // Start from a clean project-resolution slate so a stray ambient variable
  // cannot mask the behaviour under test.
  delete base.GCLOUD_PROJECT;
  delete base.GOOGLE_CLOUD_PROJECT;
  delete base.FIREBASE_PROJECT;
  delete base.FIREBASE_CONFIG;

  return spawnSync(process.execPath, [SCRIPT].concat(args || []), {
    env: Object.assign(base, env || {}),
    encoding: 'utf8',
    timeout: 60000,
  });
}

test('migration CLI: exit codes are the documented contract', () => {
  assert.equal(migration.EXIT_OK, 0);
  assert.equal(migration.EXIT_UNEXPECTED_ERROR, 1);
  assert.equal(migration.EXIT_PROJECT_BLOCKED, 2);
  assert.equal(migration.EXIT_UNRESOLVED_COACHES, 3);
});

test('migration CLI: --apply against a WRONG project exits 2', () => {
  const res = runCli(['--apply'], { GCLOUD_PROJECT: 'definitely-wrong-project' });

  assert.equal(res.status, migration.EXIT_PROJECT_BLOCKED,
    'a refused run must NOT report success\nstdout:\n' + res.stdout
    + '\nstderr:\n' + res.stderr);
  assert.match(res.stderr, /REFUSING TO APPLY/);
  assert.match(res.stderr, /definitely-wrong-project/);
  assert.match(res.stderr, /goodlift-us-storage/);
});

test('migration CLI: --apply --claims against a WRONG project exits 2', () => {
  // The claims path must be gated identically — it writes custom claims.
  const res = runCli(['--apply', '--claims'],
    { GCLOUD_PROJECT: 'definitely-wrong-project' });
  assert.equal(res.status, migration.EXIT_PROJECT_BLOCKED,
    'stderr:\n' + res.stderr);
});

test('migration CLI: --apply with an UNRESOLVED project exits 2', () => {
  // No project variable of any kind is set by runCli().
  const res = runCli(['--apply'], {});
  assert.equal(res.status, migration.EXIT_PROJECT_BLOCKED,
    'stdout:\n' + res.stdout + '\nstderr:\n' + res.stderr);
  assert.match(res.stderr, /could not be resolved/);
});

test('migration CLI: a near-miss project name still exits 2', () => {
  for (const projectId of ['goodlift-us-storage-dev', 'GOODLIFT-US-STORAGE',
    'goodlift-us-stor']) {
    const res = runCli(['--apply'], { GCLOUD_PROJECT: projectId });
    assert.equal(res.status, migration.EXIT_PROJECT_BLOCKED,
      'must refuse near-miss "' + projectId + '"\nstderr:\n' + res.stderr);
  }
});

test('migration CLI: the blocked report says NO WRITES PERFORMED', () => {
  const res = runCli(['--apply'], { GCLOUD_PROJECT: 'definitely-wrong-project' });
  assert.match(res.stdout, /BLOCKED — NO WRITES PERFORMED/);
});

test('migration CLI: --json emits a machine-readable blocked report', () => {
  const res = runCli(['--apply', '--json'],
    { GCLOUD_PROJECT: 'definitely-wrong-project' });
  assert.equal(res.status, migration.EXIT_PROJECT_BLOCKED);
  const report = JSON.parse(res.stdout);
  assert.equal(report.blocked, true);
  assert.equal(report.mode, 'APPLY');
  assert.equal(report.projectId, 'definitely-wrong-project');
  assert.equal(report.projectGuard.allowed, false);
  // A blocked run performs no work at all.
  assert.equal(report.counts.entitlementsCreated, 0);
  assert.equal(report.counts.linksCreated, 0);
});

test('migration CLI: the wrapper cannot override a blocking status', () => {
  // Regression guard for the exact defect. Scans only EXECUTABLE lines, so the
  // comment that documents the old bug does not trip it.
  const fs = require('node:fs');
  const code = fs.readFileSync(SCRIPT, 'utf8')
    .split('\n')
    .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
    .join('\n');

  assert.equal(code.includes('.then(() => process.exit(0))'), false,
    'an unconditional process.exit(0) would mask every blocker');
  assert.equal(code.includes('process.exitCode ='), false,
    'main() must RETURN its status, not set process.exitCode');
  assert.match(code, /return EXIT_PROJECT_BLOCKED;/);
  assert.match(code, /return EXIT_UNRESOLVED_COACHES;/);
  assert.match(code, /return EXIT_OK;/);
  // The single exit point honours whatever main() returned.
  assert.match(code, /process\.exit\(typeof code === 'number' \? code : EXIT_OK\)/);
});
