'use strict';

// Safety-gate tests for the Coach Mode migration.
//
// The migration can create entitlements and canonical links, so it must never
// run against the wrong project, and must never silently auto-entitle uids
// discovered in legacy data (coachAssignments was historically self-writable).

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';

const migration = require('../migrate_coach_mode');
const M = require('../coach/coach_mode_model');

test('migration: the required project is the production project', () => {
  assert.equal(migration.REQUIRED_PROJECT_ID, 'goodlift-us-storage');
});

test('migration: a DRY RUN is allowed against any project', () => {
  for (const projectId of ['goodlift-us-storage', 'some-staging', '', undefined]) {
    const g = migration.projectGuard({ apply: false, projectId });
    assert.equal(g.allowed, true, 'dry run must be allowed for ' + projectId);
  }
});

test('migration: --apply REFUSES a wrong project', () => {
  const g = migration.projectGuard({ apply: true, projectId: 'rules-test' });
  assert.equal(g.allowed, false);
  assert.match(g.reason, /REFUSING TO APPLY/);
  assert.match(g.reason, /rules-test/);
  assert.match(g.reason, /goodlift-us-storage/);
});

test('migration: --apply REFUSES an unresolved project', () => {
  for (const projectId of ['', null, undefined]) {
    const g = migration.projectGuard({ apply: true, projectId });
    assert.equal(g.allowed, false, 'must refuse projectId=' + projectId);
    assert.match(g.reason, /could not be resolved/);
  }
});

test('migration: --apply is allowed ONLY for the exact production project', () => {
  assert.equal(
    migration.projectGuard({ apply: true, projectId: 'goodlift-us-storage' }).allowed,
    true,
  );
  // Near-misses must not pass.
  for (const near of [
    'goodlift-us-storage ',
    ' goodlift-us-storage',
    'goodlift-us-storage-dev',
    'goodlift-us-stor',
    'GOODLIFT-US-STORAGE',
  ]) {
    assert.equal(
      migration.projectGuard({ apply: true, projectId: near }).allowed,
      false,
      'must refuse near-miss project: "' + near + '"',
    );
  }
});

test('migration: the reviewed coach set never contains the super admin', () => {
  assert.equal(migration.LEGACY_COACH_UIDS.includes(M.SUPER_ADMIN_UID), false,
    'the super admin is hard-coded and must never be migrated as a coach');
  // And every entry is a plausible uid, so a typo cannot silently entitle ''.
  for (const uid of migration.LEGACY_COACH_UIDS) {
    assert.equal(typeof uid, 'string');
    assert.ok(uid.length > 10, 'suspicious uid in the reviewed set: ' + uid);
  }
});

test('migration: the reviewed set is not conflated with comp memberships', () => {
  // freeMembershipUids is a historical comped-membership list and confers no
  // Coach Mode. It may overlap, but it is not the source of the coach set.
  assert.ok(
    migration.LEGACY_FREE_MEMBERSHIP_UIDS.includes(M.SUPER_ADMIN_UID),
    'sanity: the super admin is on the comp list',
  );
  assert.equal(
    migration.LEGACY_COACH_UIDS.includes(M.SUPER_ADMIN_UID),
    false,
    'but that must not put him in the coach migration set',
  );
});
