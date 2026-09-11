// Bodyweight-loaded Big Five lifts (the Chin-Up): the ONE place a stored set
// is turned into comparable numbers.
//
// Pure module: no Firebase. The Firestore adapter supplies weigh-in entries;
// everything here is deterministic over its inputs, so the triggers, the
// backfill and the tests all compute the same records from the same data.
// lib/bodyweight_load.dart is its pinned Dart mirror; both suites assert
// bodyweight_vectors.json.
//
// ── Why the showcase needs this ─────────────────────────────────────────────
// A Chin-Up is lifted as the athlete's bodyweight plus whatever hangs from the
// belt, and production history stores it in two shapes:
//
//   * The legacy workout screen stored the TOTAL (its bodyweight + the added
//     load) in `weight`, and on most sets the typed added load beside it in
//     `weightAdded` / `addedWeight`.
//   * WES2 stores exactly what was typed, which for a bodyweight exercise is
//     the ADDED load, and is the only writer that stamps `setIndex`.
//
// The raw numbers are not comparable: a legacy 138.5 kg total is +53.5 at an
// 85 kg bodyweight, and a WES2 "60" is +60. Records are therefore chosen on
// normalised values (see normalizeLoad), each set using the bodyweight
// recorded for ITS OWN date — never today's, never a weigh-in taken after the
// lift, never a default. The stored set and its fingerprint are untouched: the
// fingerprint still identifies the exact stored performance, so the proof video
// attached to it stays attached.

'use strict';

const { localDateKey } = require('../coach/coverage');
const { bigFiveBySlot } = require('./big_five');
const { showcaseE1rm } = require('./e1rm_spec');

/** How a stored set weight relates to the athlete's bodyweight. */
const LoadBasis = {
  /** Stored weight is bodyweight + added load (legacy workout screen). */
  ABSOLUTE: 'absolute',
  /** Stored weight is the added load alone (WES2). */
  ADDED: 'added',
};

/**
 * Calendar in which a weigh-in's day is read.
 *
 * Weigh-ins are stamped at device-local noon, and the server does not know the
 * device's zone. Reading them in Pacific/Auckland — the zone the coach module
 * already defaults to — is the SAFE direction to be wrong in: for every zone
 * west of New Zealand a noon stamp falls on the same or a LATER Auckland date,
 * never an earlier one. So a weigh-in can occasionally look a day newer than
 * it was (and be skipped for a lift on its own date), but a weigh-in from after
 * the lift can never be mistaken for one before it.
 */
const BODYWEIGHT_TZ = 'Pacific/Auckland';

/**
 * How many recent weigh-ins before the cutoff are examined. A day holds at most
 * an AM and a PM entry in practice; the margin absorbs duplicates and the
 * handful of entries between the UTC cutoff and the Auckland date boundary.
 */
const BODYWEIGHT_QUERY_LIMIT = 12;

/**
 * Record fields that exist only on bodyweight-loaded records: the load basis,
 * the normalised loads and the bodyweight they were computed with.
 */
const ANNOTATION_FIELDS = [
  'loadBasis',
  'bodyweightKg',
  'bodyweightDateKey',
  'addedKg',
  'totalKg',
  'totalE1rm',
  'addedE1rm',
];

/** True for a slot whose stored loads include the athlete's bodyweight. */
function isBodyweightSlot(slot) {
  const lift = bigFiveBySlot(slot);
  return !!(lift && lift.bodyweightLoaded);
}

/** The load basis of one stored set map (see the header). */
function setLoadBasis(setMap) {
  const idx = setMap && setMap.setIndex;
  return typeof idx === 'number' && Number.isFinite(idx)
    ? LoadBasis.ADDED
    : LoadBasis.ABSOLUTE;
}

/**
 * Exclusive upper bound for the weigh-in query, as epoch millis.
 *
 * Every instant whose Auckland date is on or before [dateKey] lies before
 * 12:00 UTC on that date, so midnight UTC after it is a sufficient bound; the
 * exact Auckland-date filter is applied in [pickBodyweightAsOf].
 */
function bodyweightCutoffMillis(dateKey) {
  const [y, m, d] = String(dateKey).split('-').map(Number);
  return Date.UTC(y, m - 1, d + 1);
}

/** The `YYYY-MM-DD` day a weigh-in stamped at [tsMillis] counts for. */
function weighInDateKey(tsMillis, timeZone) {
  if (typeof tsMillis !== 'number' || !Number.isFinite(tsMillis)) return null;
  return localDateKey(new Date(tsMillis), timeZone || BODYWEIGHT_TZ);
}

/** A users/{uid}/weights document snapshot → a [pickBodyweightAsOf] entry. */
function weightEntryOfDoc(doc) {
  const d = (doc && typeof doc.data === 'function' ? doc.data() : null) || {};
  const ts = d.timestamp;
  return {
    id: doc && doc.id,
    weight: typeof d.weight === 'number' ? d.weight : Number(d.weight),
    unit: d.unit,
    tod: d.tod,
    tsMillis: ts && typeof ts.toMillis === 'function' ? ts.toMillis() : Number.NaN,
  };
}

/**
 * The earliest day a weigh-in write (a Firestore onDocumentWritten event)
 * could change the recorded bodyweight for: the day of the entry before the
 * write or after it, whichever is earlier. Null — re-check every day — when
 * either side exists without a usable stamp.
 */
function weighInSinceDateKey(event) {
  const sides = [event && event.data && event.data.before, event && event.data && event.data.after]
    .filter((s) => s && s.exists);
  let since = null;
  for (const side of sides) {
    const ts = (side.data() || {}).timestamp;
    const day = weighInDateKey(ts && typeof ts.toMillis === 'function' ? ts.toMillis() : Number.NaN);
    if (!day) return null;
    if (since === null || day < since) since = day;
  }
  return since;
}

function isKg(unit) {
  if (unit === undefined || unit === null || unit === '') return true;
  return typeof unit === 'string' && unit.trim().toLowerCase() === 'kg';
}

/**
 * The bodyweight recorded for a lift on [dateKey].
 *
 * `entries` mirror users/{uid}/weights documents:
 *   { id, weight, unit, tod, tsMillis }   (optionally `dateKey`, see below)
 *
 * Rules, in order:
 *   * only kilogram entries with a finite, positive weight and a day count
 *     (pound entries are ignored exactly as the app's own bodyweight history
 *     ignores them);
 *   * the entry's day is its explicit `dateKey` when it carries one (the app
 *     knows the device calendar), otherwise its stamp read in [BODYWEIGHT_TZ];
 *     days AFTER [dateKey] are excluded, the lift's own day is included;
 *   * the latest qualifying day wins; on that day an AM entry is preferred
 *     (a missing `tod` is AM, as BodyWeightTracker treats it), then the latest
 *     timestamp, then the document id — so the choice is deterministic.
 *
 * Returns `{ weightKg, dateKey }` or null when nothing qualifies.
 */
function pickBodyweightAsOf(entries, dateKey, timeZone) {
  const tz = timeZone || BODYWEIGHT_TZ;
  let best = null;
  for (const e of entries || []) {
    if (!e || !isKg(e.unit)) continue;
    const w = typeof e.weight === 'number' ? e.weight : Number.NaN;
    if (!Number.isFinite(w) || w <= 0) continue;
    const hasTs = typeof e.tsMillis === 'number' && Number.isFinite(e.tsMillis);
    let day;
    if (typeof e.dateKey === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(e.dateKey)) {
      day = e.dateKey;
    } else if (hasTs) {
      day = localDateKey(new Date(e.tsMillis), tz);
    } else {
      continue;
    }
    if (day > dateKey) continue;
    const cand = {
      weightKg: w,
      dateKey: day,
      am: !(typeof e.tod === 'string' && e.tod.trim().toLowerCase() === 'pm'),
      ts: hasTs ? e.tsMillis : 0,
      id: typeof e.id === 'string' ? e.id : '',
    };
    if (!best || better(cand, best)) best = cand;
  }
  return best ? { weightKg: best.weightKg, dateKey: best.dateKey } : null;
}

function better(a, b) {
  if (a.dateKey !== b.dateKey) return a.dateKey > b.dateKey;
  if (a.am !== b.am) return a.am;
  if (a.ts !== b.ts) return a.ts > b.ts;
  return a.id < b.id;
}

// ── The normalisation boundary ──────────────────────────────────────────────
//
// Every bodyweight-loaded set is reduced to the same four numbers, whatever
// shape it was stored in:
//
//   stored as                     added load            total load
//   WES2 (setIndex)               stored                stored + BW
//   legacy, typed added present   typed (weightAdded)   typed + BW
//   legacy, no typed added        stored − BW           stored
//
//   total E1RM = the existing E1RM curve on the TOTAL load
//   added E1RM = total E1RM − BW
//
// e.g. legacy 138.5 × 3 (typed +53.5) at 85 kg: total 138.5, total E1RM 146.6,
// added E1RM +61.6.
//
// BW is the bodyweight RECORDED on or before that lift's own date. The legacy
// screen's stored total embeds whichever bodyweight it happened to have loaded
// — its 80 kg default on some production sets, a same-day PM reading or a
// stale one on others — while the typed added load is exactly what hung from
// the belt; so the typed load is authoritative for the external load, and the
// total is rebuilt from it and the recorded bodyweight.
//
// Anything that needs a bodyweight that was never recorded is null — with one
// exception that invents nothing: a legacy set with no recorded bodyweight
// keeps the total the legacy screen stored as its total.

/**
 * The added load the legacy screen stored beside its total (`weightAdded`, or
 * its older twin `addedWeight`), or null.
 */
function typedAddedKg(setMap) {
  if (!setMap || typeof setMap !== 'object') return null;
  const v = typeof setMap.weightAdded === 'number'
    ? setMap.weightAdded
    : typeof setMap.addedWeight === 'number'
      ? setMap.addedWeight
      : null;
  return v !== null && Number.isFinite(v) && v >= 0 ? v : null;
}

function validKg(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null;
}

function finiteOrNull(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/**
 * Normalises one bodyweight-loaded set.
 *
 * @param {{ basis: string, storedKg: number, reps: number,
 *           typedAddedKg?: number|null, bodyweightKg?: number|null }} input
 * @returns {{ addedKg: number|null, totalKg: number|null,
 *             totalE1rm: number|null, addedE1rm: number|null }}
 */
function normalizeLoad({ basis, storedKg, reps, typedAddedKg: typed, bodyweightKg }) {
  const bw = validKg(bodyweightKg);
  const stored = finiteOrNull(storedKg);
  const typedKg = basis === LoadBasis.ADDED ? null : finiteOrNull(typed);
  let addedKg = null;
  let totalKg = null;
  if (basis === LoadBasis.ADDED) {
    addedKg = stored;
    totalKg = stored !== null && bw !== null ? stored + bw : null;
  } else if (typedKg !== null && typedKg >= 0) {
    addedKg = typedKg;
    totalKg = bw !== null ? typedKg + bw : stored;
  } else {
    totalKg = stored;
    addedKg = stored !== null && bw !== null ? stored - bw : null;
  }
  const totalE1rm = totalKg !== null && totalKg > 0 && reps > 0
    ? showcaseE1rm(totalKg, reps)
    : null;
  const addedE1rm = totalE1rm !== null && bw !== null ? totalE1rm - bw : null;
  return { addedKg, totalKg, totalE1rm, addedE1rm };
}

/**
 * How a normalised set ranks for BEST E1RM: `{ tier, value, tie }`, compared
 * tier desc, value desc, tie desc. A higher tier always wins, so a set whose
 * added E1RM is unknown can never outrank one whose added E1RM is known:
 *
 *   2  added E1RM known            value = added E1RM, tie = added load
 *   1  only the added load known   value = E1RM of the added load, tie = added
 *      (no bodyweight recorded)
 *   0  only the total known        value = total E1RM, tie = total load
 *      (untyped legacy, no bodyweight recorded)
 *
 * Tiers 1 and 0 are deterministic fallbacks, each comparing like with like;
 * a total is never compared with an added load.
 */
function e1rmRank(n, reps) {
  if (n.addedE1rm !== null) return { tier: 2, value: n.addedE1rm, tie: n.addedKg };
  if (n.addedKg !== null) {
    const v = n.addedKg > 0 && reps > 0 ? showcaseE1rm(n.addedKg, reps) : 0;
    return { tier: 1, value: v, tie: n.addedKg };
  }
  return {
    tier: 0,
    value: n.totalE1rm === null ? 0 : n.totalE1rm,
    tie: n.totalKg === null ? 0 : n.totalKg,
  };
}

/**
 * How a normalised set ranks for HEAVIEST: `{ tier, value }`. The added load
 * when it is known (tier 1); otherwise, below every known one, the total
 * (tier 0).
 */
function heaviestRank(n) {
  if (n.addedKg !== null) return { tier: 1, value: n.addedKg };
  return { tier: 0, value: n.totalKg === null ? 0 : n.totalKg };
}

/** A recorded bodyweight in the `{ weightKg, dateKey }` shape, or null. */
function recordedBodyweight(bw) {
  if (!bw || typeof bw !== 'object') return null;
  const kg = validKg(bw.weightKg);
  if (kg === null || typeof bw.dateKey !== 'string' || !bw.dateKey) return null;
  return { weightKg: kg, dateKey: bw.dateKey };
}

function sameRecordedBodyweight(a, b) {
  const x = recordedBodyweight(a);
  const y = recordedBodyweight(b);
  if (!x || !y) return !x && !y;
  return x.weightKg === y.weightKg && x.dateKey === y.dateKey;
}

/**
 * The normalised view of a stored candidate set (as kept in a day
 * contribution) at the recorded bodyweight [bw].
 */
function normalizeCandidate(set, bw) {
  const rec = recordedBodyweight(bw);
  return normalizeLoad({
    basis: set.basis === LoadBasis.ADDED ? LoadBasis.ADDED : LoadBasis.ABSOLUTE,
    storedKg: set.weight,
    reps: set.reps,
    typedAddedKg: set.typedAddedKg,
    bodyweightKg: rec ? rec.weightKg : null,
  });
}

/**
 * The normalised view of a published record: its own fields when it carries
 * them, otherwise re-derived from what a record published before them did.
 */
function normalizedOfRecord(r) {
  if (r && (finiteOrNull(r.addedKg) !== null || finiteOrNull(r.totalKg) !== null)) {
    return {
      addedKg: finiteOrNull(r.addedKg),
      totalKg: finiteOrNull(r.totalKg),
      totalE1rm: finiteOrNull(r.totalE1rm),
      addedE1rm: finiteOrNull(r.addedE1rm),
    };
  }
  return normalizeCandidate(
    { basis: r && r.loadBasis, weight: r ? r.weight : null, reps: r ? r.reps : 0 },
    r ? { weightKg: r.bodyweightKg, dateKey: r.bodyweightDateKey } : null,
  );
}

/**
 * The fields a bodyweight-loaded record publishes: the normalised view [n] of
 * its source set and the bodyweight [bw] recorded for its date. Unknown values
 * are omitted rather than published as null.
 */
function recordFields(n, bw) {
  const out = {};
  if (n.addedKg !== null) out.addedKg = n.addedKg;
  if (n.totalKg !== null) out.totalKg = n.totalKg;
  if (n.totalE1rm !== null) out.totalE1rm = n.totalE1rm;
  if (n.addedE1rm !== null) out.addedE1rm = n.addedE1rm;
  const rec = recordedBodyweight(bw);
  if (rec) {
    out.bodyweightKg = rec.weightKg;
    out.bodyweightDateKey = rec.dateKey;
  }
  return out;
}

/**
 * A copy of [snapshot] reduced to WHICH stored set holds each record: every
 * bodyweight-loaded record loses the fields above and its E1RM (which, for
 * those lifts, is computed from the recorded bodyweight).
 *
 * Used by the backfill's --selection-only verify.
 */
function stripBodyweightAnnotations(snapshot) {
  if (!snapshot || typeof snapshot !== 'object') return snapshot;
  const copy = JSON.parse(JSON.stringify(snapshot));
  const lifts = copy.lifts || {};
  for (const slot of Object.keys(lifts)) {
    for (const kind of ['e1rm', 'heaviest']) {
      const r = lifts[slot] && lifts[slot][kind];
      if (!r) continue;
      for (const f of ANNOTATION_FIELDS) delete r[f];
      if (isBodyweightSlot(slot)) delete r.e1rm;
    }
  }
  return copy;
}

module.exports = {
  LoadBasis,
  BODYWEIGHT_TZ,
  BODYWEIGHT_QUERY_LIMIT,
  ANNOTATION_FIELDS,
  isBodyweightSlot,
  setLoadBasis,
  typedAddedKg,
  normalizeLoad,
  normalizeCandidate,
  normalizedOfRecord,
  e1rmRank,
  heaviestRank,
  recordedBodyweight,
  sameRecordedBodyweight,
  recordFields,
  bodyweightCutoffMillis,
  weighInDateKey,
  weightEntryOfDoc,
  weighInSinceDateKey,
  pickBodyweightAsOf,
  stripBodyweightAnnotations,
};
