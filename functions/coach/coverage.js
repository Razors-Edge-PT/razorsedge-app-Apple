// Checkpoint calendar + message-coverage state machine.
//
// Pure module: date math is done with Intl time-zone formatting (DST-safe),
// no Firebase, no external deps.
//
// Concepts
// --------
// Checkpoints are coach-local Mondays and Thursdays, identified by their
// coach-local date key "YYYY-MM-DD". Reports are always generated for every
// checkpoint. The CLIENT-MESSAGE coverage window of a checkpoint is dynamic
// until that checkpoint is finalised (copied or skipped):
//
//   coverageStart = previous checkpoint date         (if it was COPIED)
//                 = same-weekday checkpoint 7d back  (if it was not copied)
//   coverageEnd   = this checkpoint date (exclusive; the checkpoint day's own
//                   training belongs to the NEXT window)
//
// Additionally coverageStart is clamped forward to the coverage end of the
// most recent FINALISED-COPIED checkpoint, so a late copy of an old draft can
// never produce overlapping / double-praised windows.
//
// Report status values: 'draft' | 'copied' | 'skipped' | 'expired'.

'use strict';

const DAY_MS = 24 * 60 * 60 * 1000;

/** Formats a Date as the coach-local "YYYY-MM-DD" for an IANA time zone. */
function localDateKey(date, timeZone) {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return fmt.format(date); // en-CA yields YYYY-MM-DD
}

/** Coach-local weekday for a Date. Returns 'Mon'..'Sun'. */
function localWeekday(date, timeZone) {
  return new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'short' })
    .format(date);
}

/** Weekday of a plain YYYY-MM-DD key (calendar math, timezone-free). */
function weekdayOfKey(dateKey) {
  const d = parseKeyUTC(dateKey);
  return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getUTCDay()];
}

function parseKeyUTC(dateKey) {
  const [y, m, d] = dateKey.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
}

/** dateKey + n days (calendar). */
function addDaysKey(dateKey, n) {
  const d = new Date(parseKeyUTC(dateKey).getTime() + n * DAY_MS);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${dd}`;
}

/** Whole calendar days from a to b (b - a). */
function diffDaysKey(a, b) {
  return Math.round((parseKeyUTC(b).getTime() - parseKeyUTC(a).getTime()) / DAY_MS);
}

/**
 * If "now" falls on a coach-local Monday or Thursday, returns that
 * checkpoint's dateKey, else null.
 */
function currentCheckpointKey(now, timeZone) {
  const wd = localWeekday(now, timeZone);
  if (wd !== 'Mon' && wd !== 'Thu') return null;
  return localDateKey(now, timeZone);
}

/**
 * The checkpoint (Mon/Thu) on or before the given local date key.
 * Never returns a key after `dateKey`.
 */
function checkpointOnOrBefore(dateKey) {
  let k = dateKey;
  for (let i = 0; i < 7; i++) {
    const wd = weekdayOfKey(k);
    if (wd === 'Mon' || wd === 'Thu') return k;
    k = addDaysKey(k, -1);
  }
  throw new Error('unreachable');
}

/** The checkpoint immediately before the given checkpoint key (Mon↔Thu). */
function previousCheckpointKey(checkpointKey) {
  const wd = weekdayOfKey(checkpointKey);
  if (wd === 'Mon') return addDaysKey(checkpointKey, -4); // previous Thursday
  if (wd === 'Thu') return addDaysKey(checkpointKey, -3); // this week's Monday
  throw new Error(`not a checkpoint key: ${checkpointKey} (${wd})`);
}

/** Same-weekday checkpoint 7 days before. */
function previousSameWeekdayKey(checkpointKey) {
  return addDaysKey(checkpointKey, -7);
}

/**
 * Effective coverage window of a checkpoint draft.
 *
 * @param {string} checkpointKey        current checkpoint (Mon or Thu key)
 * @param {boolean} previousWasCopied   whether the immediately preceding
 *                                      checkpoint's message was copied
 * @param {string|null} lastFinalizedCoverageEnd
 *        coverageEnd of the most recent finalised-COPIED checkpoint (clamp).
 * @returns {{start: string, end: string}}  [start, end) in date keys.
 */
function effectiveCoverage(checkpointKey, previousWasCopied, lastFinalizedCoverageEnd) {
  let start = previousWasCopied
    ? previousCheckpointKey(checkpointKey)
    : previousSameWeekdayKey(checkpointKey);
  if (lastFinalizedCoverageEnd && diffDaysKey(start, lastFinalizedCoverageEnd) > 0) {
    start = lastFinalizedCoverageEnd;
  }
  // Never let the clamp push start past the checkpoint itself.
  if (diffDaysKey(start, checkpointKey) < 0) start = checkpointKey;
  return { start, end: checkpointKey };
}

/**
 * State-machine guards. `reports` is a plain map of
 *   { [checkpointKey]: { status, coverageEnd? } }
 * containing at least the checkpoints being considered.
 */

/** A draft may be copied iff no NEWER checkpoint has been finalised as copied/skipped. */
function canCopy(checkpointKey, reports) {
  return !hasNewerFinalized(checkpointKey, reports);
}

/** Undo is safe under the same condition: nothing newer has been finalised. */
function canUndo(checkpointKey, reports) {
  return !hasNewerFinalized(checkpointKey, reports);
}

function hasNewerFinalized(checkpointKey, reports) {
  for (const [key, rep] of Object.entries(reports || {})) {
    if (key <= checkpointKey) continue;
    if (rep && (rep.status === 'copied' || rep.status === 'skipped')) return true;
  }
  return false;
}

/**
 * Given the latest checkpoint key, returns which older draft keys should be
 * expired: anything strictly older than the immediately preceding checkpoint
 * that is still in 'draft'.
 */
function keysToExpire(latestCheckpointKey, reports) {
  const prev = previousCheckpointKey(latestCheckpointKey);
  const out = [];
  for (const [key, rep] of Object.entries(reports || {})) {
    if (key < prev && rep && rep.status === 'draft') out.push(key);
  }
  return out;
}

/**
 * Block-anchored training-week resolution (matches HomeV2CalendarService:
 * weekIndex = daysSinceBlockStart ~/ 7).
 *
 * @param {string} blockStartKey  block start as YYYY-MM-DD
 * @param {string} dateKey
 * @returns {{weekIndex:number, weekStart:string, weekEnd:string}|null}
 *          weekEnd is exclusive. null when dateKey is before block start.
 */
function trainingWeekOf(blockStartKey, dateKey) {
  const diff = diffDaysKey(blockStartKey, dateKey);
  if (diff < 0) return null;
  const weekIndex = Math.floor(diff / 7);
  const weekStart = addDaysKey(blockStartKey, weekIndex * 7);
  return { weekIndex, weekStart, weekEnd: addDaysKey(weekStart, 7) };
}

module.exports = {
  localDateKey,
  localWeekday,
  weekdayOfKey,
  addDaysKey,
  diffDaysKey,
  currentCheckpointKey,
  checkpointOnOrBefore,
  previousCheckpointKey,
  previousSameWeekdayKey,
  effectiveCoverage,
  canCopy,
  canUndo,
  keysToExpire,
  trainingWeekOf,
};
