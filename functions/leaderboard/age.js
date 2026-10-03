// Pure age arithmetic for the optional age-adjusted leaderboard view and the
// raw-score silver achievement. No Firebase imports.
//
// ── Model ───────────────────────────────────────────────────────────────────
// One shared provisional strength curve for all five GoodLift categories: the
// current USA Powerlifting Masters Age Coefficients (usapowerlifting.com/pro),
// ages 40–95, stored as integer thousandths. GoodLift already normalises sex
// and bodyweight in RE Points, so nothing else (DOTS, Glossbrenner, Q-Points)
// is layered on. This is a GoodLift adaptation of an established curve, not a
// claim that USAPL validated the five-category score. A future calibration is
// a new AGE_MODEL_VERSION; documents written under another version are never
// shown.
//
// ── Meaning ─────────────────────────────────────────────────────────────────
// The adjusted board is an OVERLAY on the existing raw scoring performances:
//   * month     each stored daily category winner (rePointDays) is weighted by
//               the athlete's completed age on that day's dateKey, then summed;
//   * all time  each category's CURRENT raw-winning record is weighted by the
//               completed age on its categoryDateKeys date. No other historical
//               performance is ever re-selected.
// Completed age is the age on the PERFORMANCE date (a lift at 35 stays
// unweighted when its owner is now 75). A 29 February birthday advances on
// 1 March in non-leap years.
//
// ── Arithmetic ──────────────────────────────────────────────────────────────
// Integer RE units (10,000 = 1 point). Each contribution × factor / 1000 is
// rounded half-up ONCE (exact BigInt), then the contributions are summed.
// Missing/invalid birth dates, ages beyond 95 and missing/invalid performance
// dates never receive an invented factor: the athlete is left out of the
// adjusted ranking (their raw row is untouched).
//
// ── Silver ──────────────────────────────────────────────────────────────────
// Raw boards only: strictly older than 60 TODAY (the 60th birthday itself does
// not qualify, the next day does) and strictly more than 280 raw All Time or
// 2,000 raw monthly RE Points. Never uses adjusted points.

'use strict';

const AGE_MODEL_VERSION = 'goodlift-age-usapl-2026-10-v1';

/** USA Powerlifting Masters Age Coefficients, ages 40..95, in thousandths. */
const USAPL_THOUSANDTHS = Object.freeze([
  1000, 1003, 1008, 1014, 1020, 1026, 1033, 1040, 1048, 1057, 1066, 1075, 1086, 1096, 1108, 1120,
  1134, 1147, 1162, 1178, 1194, 1211, 1230, 1249, 1269, 1290, 1312, 1335, 1360, 1385, 1411, 1439,
  1468, 1498, 1529, 1562, 1596, 1631, 1668, 1706, 1745, 1786, 1829, 1873, 1918, 1965, 2013, 2064,
  2115, 2169, 2224, 2281, 2340, 2400, 2462, 2526,
]);
const FIRST_AGE = 40;
const LAST_AGE = 95;

const POINT_UNITS = 10000;
const SILVER_MIN_AGE = 60;
/** Strictly more than these raw units qualifies. */
const SILVER_ALL_TIME_UNITS = 280 * POINT_UNITS;
const SILVER_MONTH_UNITS = 2000 * POINT_UNITS;

const CATEGORY_KEYS = Object.freeze(['horizontalPress', 'verticalPull', 'overheadPress', 'hipHinge', 'squatPattern']);

/** GoodLift's display labels (M5 is GoodLift's own 80+ label, not an IPF division). */
const AGE_BANDS = Object.freeze([
  { label: 'M1', from: 40, to: 49 },
  { label: 'M2', from: 50, to: 59 },
  { label: 'M3', from: 60, to: 69 },
  { label: 'M4', from: 70, to: 79 },
  { label: 'M5', from: 80, to: null },
]);

const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DMY_RE = /^(\d{2})[-/.](\d{2})[-/.](\d{4})$/;

function isLeapYear(y) {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

function daysInMonth(y, m) {
  return [31, isLeapYear(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
}

function validYmd(y, m, d) {
  return Number.isInteger(y) && Number.isInteger(m) && Number.isInteger(d) &&
    y >= 1000 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m);
}

/** 'YYYY-MM-DD' → { y, m, d } when it is a real calendar date, else null. */
function parseDateKey(value) {
  if (typeof value !== 'string') return null;
  const m = ISO_RE.exec(value);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  return validYmd(y, mo, d) ? { y, m: mo, d } : null;
}

/**
 * A persisted birth date → { y, m, d } or null. The repository stores
 * 'dd-mm-yyyy' (create_new_account_screen / user_settings); a real ISO
 * 'yyyy-mm-dd' is accepted too. Anything else — including impossible dates
 * and years before 1900 — is invalid.
 */
function parseBirthDate(value) {
  if (typeof value !== 'string') return null;
  const s = value.trim();
  let y;
  let m;
  let d;
  const dmy = DMY_RE.exec(s);
  const iso = ISO_RE.exec(s);
  if (dmy) {
    d = Number(dmy[1]);
    m = Number(dmy[2]);
    y = Number(dmy[3]);
  } else if (iso) {
    y = Number(iso[1]);
    m = Number(iso[2]);
    d = Number(iso[3]);
  } else {
    return null;
  }
  if (!validYmd(y, m, d) || y < 1900) return null;
  return { y, m, d };
}

function cmpYmd(a, b) {
  return a.y - b.y || a.m - b.m || a.d - b.d;
}

/** The birthday observed in [year]: 29 Feb becomes 1 Mar in a non-leap year. */
function birthdayIn(birth, year) {
  if (birth.m === 2 && birth.d === 29 && !isLeapYear(year)) return { y: year, m: 3, d: 1 };
  return { y: year, m: birth.m, d: birth.d };
}

/**
 * Completed age on [dateKey] ('YYYY-MM-DD') for a parsed [birth]; null when
 * either is invalid or the date precedes the birth.
 */
function completedAge(birth, dateKey) {
  const on = parseDateKey(dateKey);
  if (!birth || !on || cmpYmd(on, birth) < 0) return null;
  let age = on.y - birth.y;
  if (cmpYmd(on, birthdayIn(birth, on.y)) < 0) age -= 1;
  return age;
}

/** The factor in thousandths for a completed age; null when unsupported. */
function ageFactorThousandths(age) {
  if (!Number.isInteger(age) || age < 0) return null;
  if (age <= FIRST_AGE) return 1000;
  if (age > LAST_AGE) return null;
  return USAPL_THOUSANDTHS[age - FIRST_AGE];
}

/** GoodLift band label for an age (null below 40). */
function ageBandLabel(age) {
  if (!Number.isInteger(age) || age < FIRST_AGE) return null;
  for (const b of AGE_BANDS) if (age >= b.from && (b.to === null || age <= b.to)) return b.label;
  return null;
}

/** units × thousandths / 1000, rounded half-up once (exact). Null if unsafe. */
function weightUnits(units, thousandths) {
  if (!Number.isSafeInteger(units) || units < 0 || !Number.isInteger(thousandths) || thousandths <= 0) return null;
  const result = (BigInt(units) * BigInt(thousandths) * 2n + 1000n) / 2000n;
  return result <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(result) : null;
}

const REASONS = Object.freeze({
  MISSING_DOB: 'missing-dob',
  INVALID_DOB: 'invalid-dob',
  UNSUPPORTED_AGE: 'unsupported-age',
  INVALID_DATE: 'invalid-performance-date',
  SOURCE_MISMATCH: 'source-mismatch',
  NO_SOURCE: 'no-source',
});

function birthStatus(dobValue) {
  if (dobValue === undefined || dobValue === null || (typeof dobValue === 'string' && !dobValue.trim())) {
    return { birth: null, reason: REASONS.MISSING_DOB };
  }
  const birth = parseBirthDate(dobValue);
  return birth ? { birth, reason: null } : { birth: null, reason: REASONS.INVALID_DOB };
}

/**
 * Adjusts a list of { units, dateKey, category } contributions. Returns
 * { complete, reason, totalUnits, categoryUnits, rawUnits, ages }.
 */
function adjustContributions(contributions, birth, todayKey) {
  const categoryUnits = Object.fromEntries(CATEGORY_KEYS.map((k) => [k, 0]));
  let total = 0;
  let raw = 0;
  const ages = [];
  for (const c of contributions) {
    if (!Number.isSafeInteger(c.units) || c.units < 0) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
    raw += c.units;
    if (c.units === 0) continue;
    const date = parseDateKey(c.dateKey);
    if (!date || (todayKey && c.dateKey > todayKey)) return { complete: false, reason: REASONS.INVALID_DATE };
    const age = completedAge(birth, c.dateKey);
    if (age === null) return { complete: false, reason: REASONS.INVALID_DOB };
    const factor = ageFactorThousandths(age);
    if (factor === null) return { complete: false, reason: REASONS.UNSUPPORTED_AGE };
    const w = weightUnits(c.units, factor);
    if (w === null) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
    ages.push(age);
    total += w;
    if (c.category in categoryUnits) categoryUnits[c.category] += w;
    if (!Number.isSafeInteger(total)) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
  }
  return { complete: true, reason: null, totalUnits: total, categoryUnits, rawUnits: raw, ages };
}

/**
 * The adjusted monthly score of [entry] (a raw monthly entry) from the
 * athlete's [days] (rePointDays of that month).
 */
function adjustMonth(entry, days, dobValue, todayKey) {
  const { birth, reason } = birthStatus(dobValue);
  if (!entry || !Number.isSafeInteger(entry.totalPointsUnits)) return { complete: false, reason: REASONS.NO_SOURCE };
  if (!birth) return { complete: false, reason };
  const contributions = [];
  const seen = new Set();
  for (const d of days || []) {
    if (!d || d.periodKey !== entry.periodKey) continue;
    if (seen.has(d.dateKey)) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
    seen.add(d.dateKey);
    const total = Number.isInteger(d.totalPointsUnits) ? d.totalPointsUnits : 0;
    if (total <= 0) continue;
    for (const k of CATEGORY_KEYS) {
      const c = d.categories && d.categories[k];
      if (c && Number.isInteger(c.pointsUnits)) contributions.push({ units: c.pointsUnits, dateKey: d.dateKey, category: k });
    }
  }
  const r = adjustContributions(contributions, birth, todayKey);
  // The reconstructed raw sum must equal the stored raw total.
  if (r.complete && r.rawUnits !== entry.totalPointsUnits) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
  return r;
}

/** The adjusted all-time score of [entry] (a raw all-time entry). */
function adjustAllTime(entry, dobValue, todayKey) {
  const { birth, reason } = birthStatus(dobValue);
  if (!entry || !Number.isSafeInteger(entry.totalPointsUnits) || !entry.categoryBestUnits) {
    return { complete: false, reason: REASONS.NO_SOURCE };
  }
  if (!birth) return { complete: false, reason };
  const contributions = [];
  for (const k of CATEGORY_KEYS) {
    const units = entry.categoryBestUnits[k];
    if (units === undefined || units === null) continue;
    contributions.push({ units, dateKey: entry.categoryDateKeys && entry.categoryDateKeys[k], category: k });
  }
  const r = adjustContributions(contributions, birth, todayKey);
  if (r.complete && r.rawUnits !== entry.totalPointsUnits) return { complete: false, reason: REASONS.SOURCE_MISMATCH };
  return r;
}

/** The date ('YYYY-MM-DD') on which completed age reaches [years]. */
function dateAtAge(birth, years) {
  const b = birthdayIn(birth, birth.y + years);
  return `${String(b.y).padStart(4, '0')}-${String(b.m).padStart(2, '0')}-${String(b.d).padStart(2, '0')}`;
}

/** Strictly older than 60 on [todayKey]: the day AFTER the 60th birthday on. */
function isOlderThan60(dobValue, todayKey) {
  const birth = parseBirthDate(dobValue);
  if (!birth || !parseDateKey(todayKey)) return false;
  return todayKey > dateAtAge(birth, SILVER_MIN_AGE);
}

/** Raw-board silver: strictly older than 60 and strictly above the period threshold. */
function silverEligible(dobValue, todayKey, periodKey, rawTotalUnits) {
  if (!Number.isSafeInteger(rawTotalUnits)) return false;
  const threshold = periodKey === 'all_time' ? SILVER_ALL_TIME_UNITS : SILVER_MONTH_UNITS;
  return rawTotalUnits > threshold && isOlderThan60(dobValue, todayKey);
}

/** Adjusted ranking: adjusted total desc, tie date asc, uid asc. */
function compareAdjusted(a, b) {
  const s = (x, y) => (x < y ? -1 : x > y ? 1 : 0);
  return (b.adjustedTotalUnits - a.adjustedTotalUnits) ||
    s(a.tieBreakDateKey || '', b.tieBreakDateKey || '') ||
    s(a.uid, b.uid);
}

module.exports = {
  AGE_MODEL_VERSION,
  USAPL_THOUSANDTHS,
  FIRST_AGE,
  LAST_AGE,
  AGE_BANDS,
  SILVER_ALL_TIME_UNITS,
  SILVER_MONTH_UNITS,
  REASONS,
  isLeapYear,
  parseDateKey,
  parseBirthDate,
  completedAge,
  ageFactorThousandths,
  ageBandLabel,
  weightUnits,
  adjustMonth,
  adjustAllTime,
  isOlderThan60,
  silverEligible,
  compareAdjusted,
};
