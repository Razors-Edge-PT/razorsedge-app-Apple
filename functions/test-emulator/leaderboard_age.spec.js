'use strict';

// PRODUCTION-ADAPTER tests for the optional age-adjusted leaderboard, the
// raw-board silver set and the public website snapshot, against the Firestore
// emulator (project rules-test — never production).
//
// Boards use months far in the future (2041-xx) to stay isolated from the
// other emulator specs; "now" is passed explicitly.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

let ageFs;
let age;

const P = 10000;
const MONTH = '2041-05';
const NOW = Date.parse('2041-05-20T00:00:00.000Z'); // 20 May 2041, Auckland midday

test.before(() => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run through `npm run test:emulator`');
  if (!admin.apps.length) admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  ageFs = require('../leaderboard/age_firestore');
  age = require('../leaderboard/age');
});

const db = () => admin.firestore();
let seq = 0;
const created = new Set();
const freshUid = (tag) => {
  const uid = `age_${tag}_${Date.now()}_${(seq += 1)}`;
  created.add(uid);
  return uid;
};

test.after(async () => {
  if (!admin.apps.length) return;
  for (const p of ['2041-05', '2041-06', '2041-07', '2041-08']) {
    for (const col of ['leaderboards', 'leaderboardsAge', 'leaderboardPublic', 'leaderboardMedals']) {
      await db().recursiveDelete(db().collection(col).doc(p));
    }
  }
  for (const uid of [...created, 'LWXGJ5SlIzM4OxEkOdTuv6d1c5b2']) {
    await db().recursiveDelete(db().collection('users').doc(uid));
    await db().recursiveDelete(db().collection('users_public').doc(uid));
  }
});

async function seedMonth(periodKey, uid, { dob, days, username }) {
  if (dob !== undefined) await db().collection('users').doc(uid).set({ dob, email: 'secret@example.com' }, { merge: true });
  let total = 0;
  const categoryTotalsUnits = { horizontalPress: 0, verticalPull: 0, overheadPress: 0, hipHinge: 0, squatPattern: 0 };
  let tie = null;
  for (const [dateKey, cats] of days) {
    const categories = {};
    let dayTotal = 0;
    for (const [k, points] of Object.entries(cats)) {
      categories[k] = { pointsUnits: points * P };
      dayTotal += points * P;
      categoryTotalsUnits[k] += points * P;
    }
    total += dayTotal;
    if (!tie || dateKey > tie) tie = dateKey;
    await db().collection('users').doc(uid).collection('rePointDays').doc(dateKey)
      .set({ dateKey, periodKey, categories, totalPointsUnits: dayTotal });
  }
  await db().collection('leaderboards').doc(periodKey).collection('entries').doc(uid).set({
    uid, periodKey, username: username || uid, photoURL: null, totalPointsUnits: total,
    categoryTotalsUnits, tieBreakDateKey: tie, formulaVersion: 'lb-test',
  });
  return total;
}

async function ageEntry(p, uid) {
  const s = await ageFs.ageEntryRef(p, uid).get();
  return s.exists ? s.data() : null;
}

async function board(p) {
  const s = await ageFs.ageBoardRef(p).get();
  return s.exists ? s.data() : {};
}

test('month projection: weighted per day, raw untouched, silver set, idempotent', async () => {
  const uid = freshUid('m');
  // Born 10 May 1980: 61 on 10 May 2041; days on both sides of the birthday.
  await seedMonth(MONTH, uid, { dob: '10-05-1980', days: [['2041-05-09', { hipHinge: 100 }], ['2041-05-11', { hipHinge: 2000 }]] });
  const rawBefore = (await db().collection('leaderboards').doc(MONTH).collection('entries').doc(uid).get()).data();
  assert.equal(await ageFs.recomputeAthleteBoard(uid, MONTH, NOW), 'set');
  const e = await ageEntry(MONTH, uid);
  assert.equal(e.ageComplete, true);
  const f = (d) => age.ageFactorThousandths(age.completedAge(age.parseBirthDate('10-05-1980'), d));
  assert.deepEqual([f('2041-05-09'), f('2041-05-11')], [1194, 1211], 'ages 60 and 61 within one month');
  assert.equal(e.adjustedTotalUnits, age.weightUnits(100 * P, 1194) + age.weightUnits(2000 * P, 1211));
  assert.equal(e.rawTotalPointsUnits, 2100 * P);
  assert.equal(e.silverEligible, true, '> 2,000 raw monthly points and older than 60 on 20 May');
  assert.ok(!JSON.stringify(e).includes('1980'), 'no birth date copied');
  assert.ok(!JSON.stringify(e).includes('secret@'), 'nothing private copied');
  assert.ok((await board(MONTH)).silverUids.includes(uid));
  // Duplicate delivery: converges, no write.
  assert.equal(await ageFs.recomputeAthleteBoard(uid, MONTH, NOW), 'unchanged');
  const rawAfter = (await db().collection('leaderboards').doc(MONTH).collection('entries').doc(uid).get()).data();
  assert.deepEqual(rawAfter, rawBefore, 'raw entry never written');
});

test('DOB correction, missing DOB, deletion', async () => {
  const uid = freshUid('dob');
  await seedMonth(MONTH, uid, { dob: '01-01-2005', days: [['2041-05-03', { squatPattern: 300 }]] });
  await ageFs.recomputeAthleteBoard(uid, MONTH, NOW);
  assert.equal((await ageEntry(MONTH, uid)).adjustedTotalUnits, 300 * P, 'age 36: unweighted');
  await db().collection('users').doc(uid).set({ dob: '01-01-1971' }, { merge: true }); // raw unchanged
  assert.deepEqual(await ageFs.refreshAthleteAge(uid, 'dob-change', NOW), { [MONTH]: 'set', all_time: 'unchanged' });
  assert.equal((await ageEntry(MONTH, uid)).adjustedTotalUnits, age.weightUnits(300 * P, 1411), 'age 70 → 1.411');
  await db().collection('users').doc(uid).update({ dob: admin.firestore.FieldValue.delete() });
  await ageFs.recomputeAthleteBoard(uid, MONTH, NOW);
  const incomplete = await ageEntry(MONTH, uid);
  assert.equal(incomplete.ageComplete, false);
  assert.equal(incomplete.adjustedTotalUnits, null);
  await db().collection('leaderboards').doc(MONTH).collection('entries').doc(uid).delete();
  assert.equal(await ageFs.recomputeAthleteBoard(uid, MONTH, NOW), 'deleted');
  assert.equal(await ageEntry(MONTH, uid), null);
});

test('an excluded account never gets an age entry', async () => {
  const uid = 'LWXGJ5SlIzM4OxEkOdTuv6d1c5b2';
  const p = '2041-07';
  await seedMonth(p, uid, { dob: '01-01-1950', days: [['2041-07-03', { hipHinge: 3000 }]] });
  await ageFs.recomputeAthleteBoard(uid, p, Date.parse('2041-07-20T00:00:00Z'));
  assert.equal(await ageEntry(p, uid), null);
  assert.ok(!((await board(p)).silverUids || []).includes(uid));
});

test('the age board ranks EVERY athlete: a raw rank-21 athlete enters the adjusted top 20', async () => {
  const p = '2041-06';
  const nowMs = Date.parse('2041-06-25T00:00:00Z');
  const young = [];
  for (let i = 0; i < 20; i += 1) {
    const uid = freshUid(`y${i}`);
    young.push(uid);
    await seedMonth(p, uid, { dob: '01-01-2010', days: [['2041-06-05', { hipHinge: 100 - i }]] });
  }
  const older = freshUid('old');
  await seedMonth(p, older, { dob: '01-01-1966', days: [['2041-06-05', { hipHinge: 80 }]] }); // 75 → 1.562
  const noDob = freshUid('nodob');
  await seedMonth(p, noDob, { dob: undefined, days: [['2041-06-05', { hipHinge: 99.5 }]] });
  for (const uid of [...young, older, noDob]) await ageFs.recomputeAthleteBoard(uid, p, nowMs);

  const raw = await db().collection('leaderboards').doc(p).collection('entries')
    .where('totalPointsUnits', '>', 0).orderBy('totalPointsUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid').limit(20).get();
  assert.ok(!raw.docs.some((d) => d.id === older), 'outside the raw top 20');
  // The app's adjusted query.
  const adj = await ageFs.ageBoardRef(p).collection('entries')
    .where('ageModelVersion', '==', age.AGE_MODEL_VERSION).where('ageComplete', '==', true)
    .orderBy('adjustedTotalUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid').limit(20).get();
  assert.equal(adj.docs[0].id, older, 'rank 1 after adjustment');
  assert.ok(!adj.docs.some((d) => d.id === noDob), 'no invented factor for a missing DOB');
  // Counts come from the publisher.
  await ageFs.publishBoard(p, nowMs);
  const b = await board(p);
  assert.equal(b.rankedCount, 21);
  assert.equal(b.incompleteCount, 1);
});

test('public snapshot: raw order, public usernames only, medals, silver; unchanged → freshness only', async () => {
  const p = '2041-08';
  const nowMs = Date.parse('2041-08-20T00:00:00Z');
  const a = freshUid('pa');
  const b = freshUid('pb');
  await seedMonth(p, a, { dob: '01-01-1970', days: [['2041-08-02', { hipHinge: 2500 }]], username: 'Legal Fallback' });
  await seedMonth(p, b, { dob: '01-01-2000', days: [['2041-08-03', { hipHinge: 100 }]] });
  await db().collection('users_public').doc(a).set({ fullName: 'Legal Fallback', displayName: 'Shown Name' });
  await db().collection('users_public').doc(b).set({ username: 'public_b', fullName: 'B Legal' });
  await db().collection('leaderboardMedals').doc(p).set({ categories: { hipHinge: [{ uid: a, place: 1, pointsUnits: 1 }, { uid: b, place: 2 }] } });
  await ageFs.recomputeAthleteBoard(a, p, nowMs);
  await ageFs.recomputeAthleteBoard(b, p, nowMs);
  const first = await ageFs.publishBoard(p, nowMs);
  assert.equal(first.changed, true);
  const snap = (await ageFs.publicRef(p).get()).data();
  assert.deepEqual(snap, {
    schemaVersion: 1,
    periodKey: p,
    generatedAt: new Date(nowMs).toISOString(),
    entries: [
      { rank: 1, username: 'GoodLift athlete', totalPointsUnits: 2500 * P, silverEligible: true, medals: [{ categoryKey: 'hipHinge', place: 1 }] },
      { rank: 2, username: 'public_b', totalPointsUnits: 100 * P, silverEligible: false, medals: [{ categoryKey: 'hipHinge', place: 2 }] },
    ],
  });
  const second = await ageFs.publishBoard(p, nowMs + 180000);
  assert.equal(second.changed, false);
  const fresh = (await ageFs.publicRef(p).get()).data();
  assert.equal(fresh.generatedAt, new Date(nowMs + 180000).toISOString());
  assert.deepEqual(fresh.entries, snap.entries);
});
