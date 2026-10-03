'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const age = require('../leaderboard/age');

const P = 10000; // units per point

function dayDoc(dateKey, cats) {
  const categories = {};
  let total = 0;
  for (const [k, units] of Object.entries(cats)) {
    categories[k] = { pointsUnits: units };
    total += units;
  }
  return { dateKey, periodKey: dateKey.slice(0, 7), categories, totalPointsUnits: total };
}

test('coefficient table: 56 ages 40..95, monotone, frozen version', () => {
  assert.equal(age.USAPL_THOUSANDTHS.length, 56);
  assert.equal(age.USAPL_THOUSANDTHS[0], 1000);
  assert.equal(age.USAPL_THOUSANDTHS[55], 2526);
  for (let i = 1; i < 56; i += 1) assert.ok(age.USAPL_THOUSANDTHS[i] > age.USAPL_THOUSANDTHS[i - 1]);
  assert.equal(age.AGE_MODEL_VERSION, 'goodlift-age-usapl-2026-10-v1');
  assert.equal(age.ageFactorThousandths(18), 1000);
  assert.equal(age.ageFactorThousandths(40), 1000);
  assert.equal(age.ageFactorThousandths(41), 1003);
  assert.equal(age.ageFactorThousandths(60), 1194);
  assert.equal(age.ageFactorThousandths(95), 2526);
  assert.equal(age.ageFactorThousandths(96), null, 'no extrapolation beyond 95');
  assert.equal(age.ageFactorThousandths(null), null);
});

test('worked examples: 300 raw points at 60 / 70 / 80', () => {
  assert.equal(age.weightUnits(300 * P, age.ageFactorThousandths(60)), 3582000); // 358.20
  assert.equal(age.weightUnits(300 * P, age.ageFactorThousandths(70)), 4233000); // 423.30
  assert.equal(age.weightUnits(300 * P, age.ageFactorThousandths(80)), 5235000); // 523.50
});

test('integer rounding is half-up, once per contribution', () => {
  // 1 unit × 1.003 = 1.003 → 1; 500 × 1.003 = 501.5 → 502 (half up)
  assert.equal(age.weightUnits(1, 1003), 1);
  assert.equal(age.weightUnits(500, 1003), 502);
  assert.equal(age.weightUnits(499, 1003), 500); // 500.497
  assert.equal(age.weightUnits(0, 2526), 0);
  assert.equal(age.weightUnits(-1, 1000), null);
});

test('birth dates: dd-mm-yyyy and ISO, real calendar dates only', () => {
  assert.deepEqual(age.parseBirthDate('05-10-1965'), { y: 1965, m: 10, d: 5 });
  assert.deepEqual(age.parseBirthDate('1965-10-05'), { y: 1965, m: 10, d: 5 });
  assert.deepEqual(age.parseBirthDate(' 29-02-1964 '), { y: 1964, m: 2, d: 29 });
  for (const bad of ['29-02-1965', '31-04-1970', '00-01-1970', '1970-13-01', '10/05', 'yesterday', '', null, undefined, 19650101, '01-01-1899']) {
    assert.equal(age.parseBirthDate(bad), null, String(bad));
  }
});

test('completed age on the performance date, birthdays, leap days', () => {
  const b = age.parseBirthDate('15-06-1966');
  assert.equal(age.completedAge(b, '2026-06-14'), 59);
  assert.equal(age.completedAge(b, '2026-06-15'), 60);
  assert.equal(age.completedAge(b, '2001-06-15'), 35, 'a lift at 35 is weighted at 35, whatever today is');
  assert.equal(age.completedAge(b, '1960-01-01'), null, 'before birth');
  assert.equal(age.completedAge(b, '2026-02-30'), null);
  const leap = age.parseBirthDate('29-02-1964');
  assert.equal(age.completedAge(leap, '2025-02-28'), 60);
  assert.equal(age.completedAge(leap, '2025-03-01'), 61, 'non-leap year: advances on 1 March');
  assert.equal(age.completedAge(leap, '2024-02-28'), 59);
  assert.equal(age.completedAge(leap, '2024-02-29'), 60, 'leap year: on 29 February');
});

test('bands are display labels M1..M5 (M5 = 80+)', () => {
  assert.equal(age.ageBandLabel(39), null);
  assert.equal(age.ageBandLabel(40), 'M1');
  assert.equal(age.ageBandLabel(59), 'M2');
  assert.equal(age.ageBandLabel(60), 'M3');
  assert.equal(age.ageBandLabel(79), 'M4');
  assert.equal(age.ageBandLabel(80), 'M5');
  assert.equal(age.ageBandLabel(97), 'M5');
});

test('month: each daily category winner weighted on its own date, ages may differ', () => {
  // Birthday 10 Oct: turns 60 mid-month.
  const entry = { periodKey: '2026-10', totalPointsUnits: 200 * P };
  const days = [
    dayDoc('2026-10-09', { hipHinge: 100 * P }), // age 59 → 1178
    dayDoc('2026-10-10', { hipHinge: 60 * P, squatPattern: 40 * P }), // age 60 → 1194
  ];
  const r = age.adjustMonth(entry, days, '10-10-1966', '2026-10-20');
  assert.equal(r.complete, true);
  assert.equal(r.totalUnits, 117.8 * P + 71.64 * P + 47.76 * P);
  assert.equal(r.categoryUnits.hipHinge, 117.8 * P + 71.64 * P);
  assert.equal(r.categoryUnits.squatPattern, 47.76 * P);
  assert.deepEqual([...new Set(r.ages)].sort(), [59, 60]);
});

test('month: source mismatch, duplicate dates, invalid dates are incomplete, not invented', () => {
  const entry = { periodKey: '2026-10', totalPointsUnits: 150 * P };
  const days = [dayDoc('2026-10-09', { hipHinge: 100 * P })];
  assert.deepEqual(age.adjustMonth(entry, days, '10-10-1950', '2026-10-20'), { complete: false, reason: 'source-mismatch' });
  const dup = [dayDoc('2026-10-09', { hipHinge: 100 * P }), dayDoc('2026-10-09', { hipHinge: 50 * P })];
  assert.equal(age.adjustMonth(entry, dup, '10-10-1950', '2026-10-20').reason, 'source-mismatch');
  const future = { periodKey: '2026-10', totalPointsUnits: 100 * P };
  assert.equal(age.adjustMonth(future, [dayDoc('2026-10-25', { hipHinge: 100 * P })], '10-10-1950', '2026-10-20').reason, 'invalid-performance-date');
  assert.equal(age.adjustMonth(future, [dayDoc('2026-10-09', { hipHinge: 100 * P })], null, '2026-10-20').reason, 'missing-dob');
  assert.equal(age.adjustMonth(future, [dayDoc('2026-10-09', { hipHinge: 100 * P })], '31-02-1950', '2026-10-20').reason, 'invalid-dob');
  assert.equal(age.adjustMonth(future, [dayDoc('2026-10-09', { hipHinge: 100 * P })], '01-01-1925', '2026-10-20').reason, 'unsupported-age');
});

test('all time: overlay on the raw-winning record of each category, by its own date', () => {
  const entry = {
    periodKey: 'all_time',
    totalPointsUnits: 300 * P,
    categoryBestUnits: { horizontalPress: 100 * P, verticalPull: 0, overheadPress: 0, hipHinge: 200 * P, squatPattern: 0 },
    categoryDateKeys: { horizontalPress: '2001-03-01', verticalPull: null, overheadPress: null, hipHinge: '2026-09-01', squatPattern: null },
  };
  // Born 1966: the bench record was set at 34 (unweighted), the deadlift at 60.
  const r = age.adjustAllTime(entry, '01-01-1966', '2026-10-03');
  assert.equal(r.complete, true);
  assert.equal(r.categoryUnits.horizontalPress, 100 * P);
  assert.equal(r.categoryUnits.hipHinge, 238.8 * P);
  assert.equal(r.totalUnits, 338.8 * P);
  const noDate = Object.assign({}, entry, { categoryDateKeys: { hipHinge: '2026-09-01' } });
  assert.equal(age.adjustAllTime(noDate, '01-01-1966', '2026-10-03').reason, 'invalid-performance-date');
});

test('silver: strictly older than 60 today, strictly above 280 / 2,000 raw points', () => {
  const dob = '03-10-1966';
  assert.equal(age.isOlderThan60(dob, '2026-10-03'), false, '60th birthday itself: no');
  assert.equal(age.isOlderThan60(dob, '2026-10-04'), true, 'the following day: yes');
  assert.equal(age.silverEligible(dob, '2026-10-04', 'all_time', 280 * P), false, 'exactly 280: no');
  assert.equal(age.silverEligible(dob, '2026-10-04', 'all_time', 280 * P + 1), true);
  assert.equal(age.silverEligible(dob, '2026-10-04', '2026-10', 2000 * P), false, 'exactly 2,000: no');
  assert.equal(age.silverEligible(dob, '2026-10-04', '2026-10', 2000 * P + 1), true);
  assert.equal(age.silverEligible(dob, '2026-10-03', '2026-10', 5000 * P), false);
  assert.equal(age.silverEligible(null, '2026-10-04', 'all_time', 999 * P), false, 'missing DOB: no silver');
  assert.equal(age.silverEligible('not a date', '2026-10-04', 'all_time', 999 * P), false);
  // Leap-day birth: the observed 60th birthday in a non-leap year is 1 March.
  // (born 29 Feb 1964: the 60th birthday is 29 Feb 2024, a leap day)
  assert.equal(age.isOlderThan60('29-02-1964', '2024-02-29'), false);
  assert.equal(age.isOlderThan60('29-02-1964', '2024-03-01'), true);
  assert.equal(age.isOlderThan60('29-02-1965', '2026-03-01'), false, 'an impossible birth date never qualifies');
});

test('adjusted ranking order: total desc, earlier tie date, uid', () => {
  const rows = [
    { uid: 'b', adjustedTotalUnits: 5, tieBreakDateKey: '2026-10-02' },
    { uid: 'a', adjustedTotalUnits: 5, tieBreakDateKey: '2026-10-02' },
    { uid: 'c', adjustedTotalUnits: 5, tieBreakDateKey: '2026-10-01' },
    { uid: 'd', adjustedTotalUnits: 9, tieBreakDateKey: '2026-10-09' },
  ].sort(age.compareAdjusted);
  assert.deepEqual(rows.map((r) => r.uid), ['d', 'c', 'a', 'b']);
});
