'use strict';

// Current-week adherence: fixed Monday→Sunday boundaries, the weekly target
// taken from the active block's TEMPLATES (not planned_blocks weeks/days),
// unique training DAYS, and per-day distinct-exercise counts.

const test = require('node:test');
const assert = require('node:assert/strict');

const adh = require('../coach/adherence');
const { summarizeWorkoutDay } = require('../coach/pb_engine');
const { buildDraftText } = require('../coach/draft');
const cov = require('../coach/coverage');

// 2026-09-07 is a Monday; the week runs to 2026-09-13 (Sun), exclusive end
// 2026-09-14 (Mon).
const MON = '2026-09-07';
const TUE = '2026-09-08';
const WED = '2026-09-09';
const THU = '2026-09-10';
const SUN = '2026-09-13';
const NEXT_MON = '2026-09-14';

const block = { blockId: 'blk1', name: 'Mike Prep' };

function tmpl(id, extra = {}) {
  return { id, name: id, ...extra };
}

function trained(exerciseCount) {
  return { trained: true, exerciseCount };
}

function adherence(dayStats, planned = adh.plannedTarget(4, adh.PLANNED_SOURCE.templates)) {
  return adh.buildWeekAdherence({
    weekStart: MON, planned, dayStats, blockId: block.blockId, blockName: block.name,
  });
}

// ── Planned target: active-block templates ──────────────────────────────────

test('adherence: four templates on the active block → plannedCount 4', () => {
  const templates = [
    tmpl('t1', { blockId: 'blk1' }),
    tmpl('t2', { blockId: 'blk1' }),
    tmpl('t3', { blockId: 'blk1' }),
    tmpl('t4', { blockId: 'blk1' }),
    tmpl('other', { blockId: 'blk2' }),
    tmpl('unassigned'),
  ];
  const planned = adh.plannedFromTemplates(templates, block);
  assert.equal(planned.count, 4);
  assert.equal(planned.known, true);
  assert.equal(planned.source, adh.PLANNED_SOURCE.templates);
});

test('adherence: the target ignores planned_blocks weeks/days entirely', () => {
  // The empty week/day structure that used to produce "week 4/0 planned" is
  // simply not an input here — the same templates yield the same target.
  const templates = [
    tmpl('t1', { blockId: 'blk1' }), tmpl('t2', { blockId: 'blk1' }),
    tmpl('t3', { blockId: 'blk1' }), tmpl('t4', { blockId: 'blk1' }),
  ];
  assert.equal(adh.plannedFromTemplates(templates, block).count, 4);

  const week = adherence(
    { [MON]: trained(5), [TUE]: trained(4), [WED]: trained(6), [THU]: trained(3) },
    adh.plannedFromTemplates(templates, block));
  assert.equal(week.plannedCount, 4);
  assert.equal(week.completedCount, 4);
});

test('adherence: legacy blockAssignment-by-name association still counts', () => {
  const templates = [
    tmpl('t1', { blockId: 'blk1' }),
    tmpl('t2', { blockAssignment: 'Mike Prep' }),       // legacy, no blockId
    tmpl('t3', { blockAssignment: '  Mike Prep  ' }),   // whitespace tolerated
    tmpl('t4', { blockAssignment: 'Other Block' }),     // different block
    tmpl('t5', { blockAssignment: '' }),                // empty never matches
  ];
  assert.equal(adh.plannedFromTemplates(templates, block).count, 3);
});

test('adherence: a template matching on both rules is counted once', () => {
  const templates = [
    tmpl('t1', { blockId: 'blk1', blockAssignment: 'Mike Prep' }),
    tmpl('t1', { blockId: 'blk1' }), // duplicate document id
    tmpl('t2', { blockId: 'blk1' }),
  ];
  assert.equal(adh.plannedFromTemplates(templates, block).count, 2);
});

test('adherence: unnamed block never matches templates by empty name', () => {
  const unnamed = { blockId: 'blk1', name: null };
  const templates = [tmpl('t1', { blockAssignment: '' }), tmpl('t2', {})];
  assert.equal(adh.plannedFromTemplates(templates, unnamed).count, 0);
});

// ── Week boundaries ─────────────────────────────────────────────────────────

test('adherence: Monday→Monday boundaries, Sunday inside, next Monday out', () => {
  for (const key of [MON, TUE, WED, THU, SUN]) {
    const w = adh.calendarWeekOf(key);
    assert.equal(w.weekStart, MON, `${key} should sit in the ${MON} week`);
    assert.equal(w.weekEnd, NEXT_MON);
  }
  const next = adh.calendarWeekOf(NEXT_MON);
  assert.equal(next.weekStart, NEXT_MON);
  assert.equal(next.weekEnd, '2026-09-21');
});

test('adherence: the week is never anchored to the block start date', () => {
  // A block starting on a Wednesday used to make Wed→Tue the "week".
  const w = adh.calendarWeekOf('2026-09-11'); // Friday
  assert.equal(w.weekStart, MON);
  assert.deepEqual(adh.weekDateKeys(w.weekStart), [
    MON, TUE, WED, THU, '2026-09-11', '2026-09-12', SUN,
  ]);
});

test('adherence: days[] is always seven entries, Monday first', () => {
  const week = adherence({});
  assert.equal(week.days.length, 7);
  assert.deepEqual(week.days.map((d) => d.weekday), adh.WEEKDAYS);
  assert.deepEqual(week.days.map((d) => d.dateKey), adh.weekDateKeys(MON));
  assert.equal(week.completedCount, 0);
  assert.ok(week.days.every((d) => d.trained === false && d.exerciseCount === 0));
});

test('adherence: Sunday training counts, the following Monday does not', () => {
  const week = adherence({ [SUN]: trained(2), [NEXT_MON]: trained(9) });
  assert.equal(week.completedCount, 1);
  assert.equal(week.days[6].weekday, 'Sun');
  assert.equal(week.days[6].trained, true);
  assert.equal(week.days[6].exerciseCount, 2);
});

// ── Completed days ──────────────────────────────────────────────────────────

test('adherence: one valid workout on Monday → completedCount 1', () => {
  const week = adherence({ [MON]: trained(3) });
  assert.equal(week.completedCount, 1);
  assert.equal(week.plannedCount, 4);
  assert.equal(week.days[0].trained, true);
});

test('adherence: two sessions merged on one Wednesday count that day once', () => {
  // Both sessions land in the SAME users/{uid}/workouts/{date} document, so
  // the day stats already aggregate; the day still counts once.
  const week = adherence({ [MON]: trained(4), [WED]: trained(7) });
  assert.equal(week.completedCount, 2, 'Mon + Wed = 2 training days, not 3');
  assert.equal(week.days[2].exerciseCount, 7,
    'exerciseCount aggregates both sessions on the date');
});

// ── Daily exercise counts (via the shared pb_engine summariser) ─────────────

function set(weight, reps) { return { weight, reps }; }

test('adherence: exerciseCount is distinct exercises with a valid set', () => {
  const day = {
    exercises: [
      { exerciseId: 'sq', name: 'Squat', sets: [set(100, 5), set(105, 5), set(110, 3), set(110, 2)] },
      { exerciseId: 'bp', name: 'Bench', sets: [set(80, 5)] },
      { exerciseId: 'op', name: 'Opened but not done', sets: [set(0, 0), {}] },
      { exerciseId: 'np', name: 'No sets array' },
    ],
  };
  const summary = summarizeWorkoutDay(day);
  assert.deepEqual(Object.keys(summary).sort(), ['bp', 'sq']);
  assert.equal(Object.keys(summary).length, 2,
    '4 squat sets = 1 exercise, bench = 1, unfinished = 0');
});

test('adherence: same-day sessions dedupe by exercise id, not name', () => {
  // Two sessions merged into one date document; the same lift appears twice
  // under two casings of the stable id and under a different display name.
  const day = {
    exercises: [
      { exerciseId: 'aBc123', name: 'Back Squat', sets: [set(100, 5)] },
      { exerciseId: 'abc123', name: 'Squat (evening)', sets: [set(90, 8)] },
      { exerciseId: 'zzz999', name: 'Row', sets: [set(60, 10)] },
    ],
  };
  assert.equal(Object.keys(summarizeWorkoutDay(day)).length, 2);
});

test('adherence: an exercise row without a stable id is not counted', () => {
  const day = { exercises: [{ name: 'Mystery lift', sets: [set(50, 5)] }] };
  assert.equal(Object.keys(summarizeWorkoutDay(day)).length, 0);
});

// ── Coverage count vs current-week count ────────────────────────────────────

test('adherence: a Thursday can read "3 done - week 1/4 planned"', () => {
  // Rolling check-in coverage: previous Thu → this Thu, exclusive. Three
  // training dates, two of them in LAST calendar week.
  const coverageDates = ['2026-09-04', '2026-09-05', MON]; // Fri, Sat, Mon
  const week = adherence({ [MON]: trained(5) });

  assert.equal(coverageDates.length, 3, '3 done comes from the coverage window');
  assert.equal(week.completedCount, 1, 'only Monday sits in the current week');
  assert.equal(week.plannedCount, 4);

  // …and attendance never becomes draft text (it stays on the coach card).
  const completion = adh.completionFromWeek(week);
  assert.equal(completion.completedAll, false);
  assert.equal(buildDraftText({
    events: [], completion, settings: {}, bodyweight: null,
    coverageStart: '2026-09-03', coverageEnd: '2026-09-10', variantSeed: 1,
  }), '', 'attendance is not a draft message');
});

// ── Missing data fails safe ─────────────────────────────────────────────────

test('adherence: no active block leaves the target unknown, never 0', () => {
  const planned = adh.plannedTarget(null, adh.PLANNED_SOURCE.noActiveBlock);
  assert.equal(planned.count, null);
  assert.equal(planned.known, false);

  const week = adherence({ [MON]: trained(3), [WED]: trained(3) }, planned);
  assert.equal(week.plannedCount, null);
  assert.equal(week.plannedKnown, false);
  assert.equal(week.plannedSource, adh.PLANNED_SOURCE.noActiveBlock);
  assert.equal(adh.completionFromWeek(week).completedAll, false);
});

test('adherence: a failed template read is unknown, not perfect adherence', () => {
  const planned = adh.plannedTarget(null, adh.PLANNED_SOURCE.unavailable);
  const week = adherence({}, planned);
  assert.equal(week.plannedCount, null);
  assert.equal(week.plannedKnown, false);
  assert.equal(adh.completionFromWeek(week).completedAll, false);
});

test('adherence: an active block with zero templates is 0 planned, not "all done"', () => {
  const planned = adh.plannedFromTemplates([], block);
  assert.equal(planned.count, 0);
  assert.equal(planned.known, true);

  const week = adherence({ [MON]: trained(3) }, planned);
  const completion = adh.completionFromWeek(week);
  assert.equal(completion.completedAll, false, '0 planned is never "completed all"');
});

test('adherence: meeting the template target is completedAll', () => {
  const week = adherence({
    [MON]: trained(5), [TUE]: trained(4), [THU]: trained(6), [SUN]: trained(3),
  });
  const completion = adh.completionFromWeek(week);
  assert.equal(completion.completedCount, 4);
  assert.equal(completion.completedAll, true);
  assert.equal(completion.weekKey, MON, 'praise is keyed on the Monday');
});

// ── Attendance period anchored to the checkpoint ────────────────────────────
//
// The reported defect: a Monday 14 Sep 2026 recap used calendarWeekOf(14 Sep)
// = 14–20 Sep, so the completed Tue 8 / Thu 10 / Sun 13 sessions showed as an
// all-dash row and "week 0/4 planned".

test('attendance: Monday 14 Sep 2026 reports the preceding 7–13 Sep week', () => {
  const p = adh.attendancePeriod('2026-09-14');
  assert.equal(p.period, 'previousWeek');
  assert.equal(p.weekStart, '2026-09-07');
  assert.equal(p.weekEnd, '2026-09-14');
  assert.equal(p.cutoffKey, '2026-09-14');
  assert.deepEqual(adh.countedDateKeys(p.weekStart, p.cutoffKey), adh.weekDateKeys('2026-09-07'));
});

test('attendance: Thursday 17 Sep 2026 reports 14–20 Sep counted through the cutoff', () => {
  const p = adh.attendancePeriod('2026-09-17');
  assert.equal(p.period, 'currentWeek');
  assert.equal(p.weekStart, '2026-09-14');
  assert.equal(p.weekEnd, '2026-09-21');
  assert.equal(p.cutoffKey, '2026-09-17');
  assert.deepEqual(adh.countedDateKeys(p.weekStart, p.cutoffKey),
    ['2026-09-14', '2026-09-15', '2026-09-16']);
});

test('attendance: a non-checkpoint key is rejected', () => {
  assert.throws(() => adh.attendancePeriod('2026-09-15'), /not a checkpoint/);
});

test('attendance: the screenshot week — Tue 8, Thu 10, Sun 13 are trained on the 14 Sep recap', () => {
  const p = adh.attendancePeriod('2026-09-14');
  const week = adh.buildWeekAdherence({
    weekStart: p.weekStart,
    planned: adh.plannedTarget(4, adh.PLANNED_SOURCE.templates),
    dayStats: { [TUE]: trained(5), [THU]: trained(4), [SUN]: trained(3) },
    cutoffKey: p.cutoffKey,
    period: p.period,
  });
  assert.deepEqual(week.days.map((d) => d.trained),
    [false, true, false, true, false, false, true]);
  assert.ok(week.days.every((d) => d.counted));
  assert.equal(week.completedCount, 3);
  assert.equal(week.plannedCount, 4);
  assert.equal(week.period, 'previousWeek');
});

test('attendance: four genuinely completed days → 4/4', () => {
  const week = adh.buildWeekAdherence({
    weekStart: MON,
    planned: adh.plannedTarget(4, adh.PLANNED_SOURCE.templates),
    dayStats: { [MON]: trained(5), [WED]: trained(4), [THU]: trained(6), [SUN]: trained(2) },
    cutoffKey: NEXT_MON,
  });
  assert.equal(week.completedCount, 4);
  assert.equal(adh.completionFromWeek(week).completedAll, true);
});

test('attendance: Thursday days on/after the cutoff are upcoming, never missed or counted', () => {
  const p = adh.attendancePeriod('2026-09-17');
  const week = adh.buildWeekAdherence({
    weekStart: p.weekStart,
    planned: adh.plannedTarget(4, adh.PLANNED_SOURCE.templates),
    // A stat for the checkpoint day itself (and later) must be ignored.
    dayStats: { '2026-09-14': trained(3), '2026-09-17': trained(9), '2026-09-19': trained(2) },
    cutoffKey: p.cutoffKey,
    period: p.period,
  });
  assert.deepEqual(week.days.map((d) => d.counted), [true, true, true, false, false, false, false]);
  assert.deepEqual(week.days.map((d) => d.trained), [true, false, false, false, false, false, false]);
  assert.equal(week.completedCount, 1);
});

test('attendance: checkpoint identity follows the coach timezone, including NZ DST start', () => {
  // NZ DST begins 2026-09-27 02:00 NZST. 2026-09-27T13:30Z is Monday 28 Sep
  // 02:30 NZDT, but still Sunday 27 Sep in Los Angeles.
  const instant = new Date('2026-09-27T13:30:00Z');
  const nzKey = cov.checkpointOnOrBefore(cov.localDateKey(instant, 'Pacific/Auckland'));
  const laKey = cov.checkpointOnOrBefore(cov.localDateKey(instant, 'America/Los_Angeles'));
  assert.equal(nzKey, '2026-09-28');
  assert.equal(laKey, '2026-09-24');
  assert.deepEqual(adh.attendancePeriod(nzKey),
    { period: 'previousWeek', weekStart: '2026-09-21', weekEnd: '2026-09-28', cutoffKey: '2026-09-28' });
  assert.deepEqual(adh.attendancePeriod(laKey),
    { period: 'currentWeek', weekStart: '2026-09-21', weekEnd: '2026-09-28', cutoffKey: '2026-09-24' });
});

// ── Completed-set semantics (shared with HomeV2CalendarService) ─────────────

test('completed day: logged sets count even with no planned exercises', () => {
  assert.equal(adh.hasCompletedSets({
    exercises: [{ exerciseId: 'x', sets: [{ weight: 60, reps: 8 }] }],
  }), true);
  assert.equal(adh.hasCompletedSets({
    exercises: [{ exerciseId: 'x', sets: [{ weight: 60, reps: 8 }] }],
    wesPlannedExercises: [],
  }), true);
});

test('completed day: planned-only and empty placeholder workouts do not count', () => {
  assert.equal(adh.hasCompletedSets({ wesPlannedExercises: [{ exerciseId: 'x' }] }), false);
  assert.equal(adh.hasCompletedSets({ exercises: [] }), false);
  assert.equal(adh.hasCompletedSets({
    exercises: [{ exerciseId: 'x', sets: [{ weight: 60, reps: 0 }, { weight: 0, reps: 5 }, {}] }],
  }), false);
  assert.equal(adh.hasCompletedSets(null), false);
});

test('completed day: legacy actualWeight/actualReps and numeric strings are read like the calendar', () => {
  assert.equal(adh.hasCompletedSets({ exercises: [{ id: 'x', sets: [{ actualWeight: 50, actualReps: 5 }] }] }), true);
  assert.equal(adh.hasCompletedSets({ exercises: [{ id: 'x', sets: [{ weight: '52.5', reps: '6' }] }] }), true);
  assert.equal(adh.hasCompletedSets({ exercises: [{ id: 'x', sets: [{ weight: 'abc', reps: 6 }] }] }), false);
  assert.equal(adh.hasCompletedSets({ exercises: [{ id: 'x', sets: [{ weight: true, reps: 6 }] }] }), false);
});

// ── Target for the week being reported ─────────────────────────────────────

const T4 = [tmpl('a1', { blockId: 'old' }), tmpl('a2', { blockId: 'old' }), tmpl('a3', { blockId: 'old' }),
  tmpl('b1', { blockId: 'new' }), tmpl('b2', { blockId: 'new' })];

test('week target: active block covering the week supplies the target', () => {
  const active = { blockId: 'new', name: 'New', startKey: '2026-08-31' };
  const r = adh.resolveWeekBlock({ activeBlock: active, blocks: [], weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(r.block, active);
  assert.deepEqual(adh.plannedForWeek(r, T4),
    { count: 2, known: true, source: adh.PLANNED_SOURCE.templates });
});

test('week target: a legacy active block without a start date keeps the template target', () => {
  const active = { blockId: 'new', name: 'New', startKey: null };
  const r = adh.resolveWeekBlock({ activeBlock: active, blocks: [], weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(adh.plannedForWeek(r, T4).count, 2);
});

test('week target: block changed on Monday — last week uses the previous block, never the new one', () => {
  const active = { blockId: 'new', name: 'New', startKey: NEXT_MON };
  const blocks = [
    active,
    { blockId: 'old', name: 'Old', startKey: '2026-08-10', endKey: '2026-09-13' },
    { blockId: 'older', name: 'Older', startKey: '2026-07-01', endKey: '2026-08-09' },
  ];
  const r = adh.resolveWeekBlock({ activeBlock: active, blocks, weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(r.block.blockId, 'old');
  assert.equal(r.historical, true);
  assert.deepEqual(adh.plannedForWeek(r, T4),
    { count: 3, known: true, source: adh.PLANNED_SOURCE.weekBlockTemplates });
});

test('week target: previous block with no templates left is UNKNOWN, not 0 and not the new target', () => {
  const active = { blockId: 'new', name: 'New', startKey: NEXT_MON };
  const blocks = [active, { blockId: 'old', name: 'Old', startKey: '2026-08-10', endKey: '2026-09-13' }];
  const r = adh.resolveWeekBlock({ activeBlock: active, blocks, weekStart: MON, weekEnd: NEXT_MON });
  const planned = adh.plannedForWeek(r, [tmpl('b1', { blockId: 'new' })]);
  assert.equal(planned.count, null);
  assert.equal(planned.known, false);
  assert.equal(planned.source, adh.PLANNED_SOURCE.historicalUnavailable);
});

test('week target: no earlier block, or a block starting mid-week → unknown', () => {
  const active = { blockId: 'new', name: 'New', startKey: NEXT_MON };
  const none = adh.resolveWeekBlock({ activeBlock: active, blocks: [active], weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(adh.plannedForWeek(none, T4).known, false);

  const midWeek = { blockId: 'new', name: 'New', startKey: WED };
  const mixed = adh.resolveWeekBlock({ activeBlock: midWeek, blocks: [], weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(mixed.reason, adh.PLANNED_SOURCE.blockChanged);
  assert.deepEqual(adh.plannedForWeek(mixed, T4),
    { count: null, known: false, source: adh.PLANNED_SOURCE.blockChanged });

  const noActive = adh.resolveWeekBlock({ activeBlock: null, blocks: [], weekStart: MON, weekEnd: NEXT_MON });
  assert.equal(adh.plannedForWeek(noActive, T4).source, adh.PLANNED_SOURCE.noActiveBlock);
});
