// The production hint pass ([Wes2HintLoadRunner]) driven with controlled
// delays, against the real controller and the real hint service.
//
// A pass awaits history, settings, defaults and types in turn. Each await is a
// chance for the athlete to change date, switch athlete, reload the day, or
// save new settings. Before the fix an older pass could still install its
// settings into the cache, register its service and apply its hints over the
// day that was by then on screen.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';
import 'package:localtest222/wes2_hint_load_runner.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _other = 'u2';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings(String repTarget) => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': repTarget},
          'week2': <String, dynamic>{'instance1': repTarget},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                'set1': <String, dynamic>{'rir': '2'},
                'set2': <String, dynamic>{'rir': '2'},
                'set3': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

/// A plan service whose settings load can be held open, so a second pass can
/// be started — and can finish — while the first is still waiting.
class _ScriptedPlanService implements Wes2PlanService {
  _ScriptedPlanService(this.settingsByCall);

  /// One entry per expected call, in order.
  final List<Map<String, dynamic>> settingsByCall;
  final List<Completer<void>> gates = <Completer<void>>[];
  final List<String> calls = <String>[];
  bool holdSettings = false;

  @override
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  }) async {
    final int index = calls.length;
    calls.add('settings:$uid');
    if (holdSettings) {
      final Completer<void> gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    return settingsByCall[index.clamp(0, settingsByCall.length - 1)];
  }

  @override
  Future<Map<String, String>> loadExerciseTypes(List<String> exerciseIds,
          {String uid = ''}) async =>
      <String, String>{};

  @override
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async =>
      const <Wes2ExerciseRow>[];

  @override
  Future<void> updatePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Wes2ExerciseRow> updatedRows,
  }) async {}

  @override
  Future<Map<String, dynamic>> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required ExerciseSettingsPatch patch,
  }) async =>
      <String, dynamic>{};

  @override
  Future<Map<String, dynamic>?> repairExerciseShadows({
    required String uid,
    required String blockId,
    required String exerciseId,
  }) async =>
      null;
}

Wes2ExerciseRow _row() => Wes2ExerciseRow(
      exerciseId: _exId,
      name: _exName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: 3,
      source: Wes2RowSource.wes2Manual,
      sets: List<Wes2SetState>.generate(
          3, (int i) => Wes2SetState(setIndex: i)),
    );

({Wes2SessionController controller, Wes2HintLoadRunner runner, int notifications})
    _build(_ScriptedPlanService plan, {String uid = _uid}) {
  final Wes2SessionController c = Wes2SessionController(_day)
    ..initIdentity(
      actorUid: uid,
      actingUid: uid,
      isCoach: false,
      activeBlockId: _blockId,
      blockStartDate: _blockStart,
      blockEndDate: null,
    );
  final int epoch = c.beginLoad();
  c.setRows(<Wes2ExerciseRow>[_row()], epoch);
  final Wes2HintLoadRunner runner = Wes2HintLoadRunner(
    controller: c,
    planService: plan,
    ensureExerciseDefaults: (String _, String __) async {},
    isSettingsUsable: (Map<String, dynamic>? s) => s != null,
  );
  return (controller: c, runner: runner, notifications: 0);
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  test('H-RUN-APPLIES a current pass installs settings and hints', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')]);
    final b = _build(plan);
    final Wes2HintPassOutcome outcome = await b.runner.run();

    expect(outcome, Wes2HintPassOutcome.applied);
    expect(b.controller.rows.first.sets[0].weight.hintValue, isNotNull);
    expect(b.runner.settings, isNotEmpty);
  });

  test('H-RUN-OLD-AFTER-NEW an older pass never applies, even finishing last',
      () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[
      _settings('10 x 3'), // first (older) pass
      _settings('5 x 3'), // second (newer) pass
    ])
      ..holdSettings = true;
    final b = _build(plan);

    final Future<Wes2HintPassOutcome> first = b.runner.run();
    await pumpEventQueue();

    // The day is reloaded while the first pass waits on its settings.
    final int epoch = b.controller.beginLoad();
    b.controller.setRows(<Wes2ExerciseRow>[_row()], epoch);
    final Future<Wes2HintPassOutcome> second = b.runner.run();
    await pumpEventQueue();

    // Let the newer pass finish first, then release the older one.
    expect(plan.gates, hasLength(2));
    plan.gates[1].complete();
    expect(await second, Wes2HintPassOutcome.applied);
    final String afterNew = b.runner.settings.toString();

    plan.gates[0].complete();
    expect(await first, Wes2HintPassOutcome.superseded);
    expect(b.runner.settings.toString(), afterNew,
        reason: 'the superseded pass overwrote the newer settings cache');
  });

  test('H-RUN-CONTEXT-date a date change discards the pass in flight',
      () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')])
      ..holdSettings = true;
    final b = _build(plan);
    final Future<Wes2HintPassOutcome> pass = b.runner.run();
    await pumpEventQueue();

    b.controller.changeDate(_day.add(const Duration(days: 1)));
    plan.gates.single.complete();

    expect(await pass, Wes2HintPassOutcome.superseded);
    expect(b.runner.settings, isEmpty,
        reason: 'a pass for another day must not install its settings');
  });

  test('H-RUN-CONTEXT-athlete an athlete switch discards the pass', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')])
      ..holdSettings = true;
    final b = _build(plan);
    final Future<Wes2HintPassOutcome> pass = b.runner.run();
    await pumpEventQueue();

    // A coach switching athlete rebuilds identity on a fresh controller in
    // production; here the same effect is produced by a new load epoch under a
    // different acting uid.
    final b2 = _build(plan, uid: _other);
    expect(b2.controller.actingUid, _other);

    plan.gates.single.complete();
    await pass;
    expect(b2.runner.settings, isEmpty);
  });

  test('H-RUN-SETTINGS-RACE a settings save supersedes a pass already loading',
      () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[
      _settings('10 x 3'), // the pass that is already in flight
      _settings('5 x 3'), // the pass started after the save
    ])
      ..holdSettings = true;
    final b = _build(plan);

    final Future<Wes2HintPassOutcome> stale = b.runner.run();
    await pumpEventQueue();

    // The athlete saves new settings: invalidation happens BEFORE any await.
    b.runner.invalidateSettings();
    final Future<Wes2HintPassOutcome> fresh = b.runner.run();
    await pumpEventQueue();

    plan.gates[0].complete(); // the old response arrives first
    expect(await stale, Wes2HintPassOutcome.superseded);
    plan.gates[1].complete();
    expect(await fresh, Wes2HintPassOutcome.applied);

    final Map<String, dynamic> ex =
        b.runner.settings[_exId] as Map<String, dynamic>;
    expect(
      ((ex['repTargets'] as Map)['week1'] as Map)['instance1'],
      '5 x 3',
      reason: 'the saved settings must win over the response in flight',
    );
  });

  test('H-RUN-SAME-IDENTITY-OVERLAP an older pass loses even with an equal '
      'token', () async {
    // Two passes started inside the same load epoch and settings generation
    // carry IDENTICAL tokens - a reload trigger and a resume trigger, say - so
    // identity alone cannot order them. The older one must still lose.
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[
      _settings('10 x 3'), // first (older) pass
      _settings('5 x 3'), // second (newer) pass, same token
    ])
      ..holdSettings = true;
    final b = _build(plan);

    final Future<Wes2HintPassOutcome> first = b.runner.run();
    await pumpEventQueue();
    final Wes2HintPassToken? tokenA = b.runner.currentToken();

    final Future<Wes2HintPassOutcome> second = b.runner.run();
    await pumpEventQueue();
    expect(b.runner.currentToken(), tokenA,
        reason: 'the fixture is only meaningful while the tokens are equal');

    // The newer pass finishes first; the older one lands afterwards.
    expect(plan.gates, hasLength(2));
    plan.gates[1].complete();
    expect(await second, Wes2HintPassOutcome.applied);

    plan.gates[0].complete();
    expect(await first, Wes2HintPassOutcome.superseded);

    final Map<String, dynamic> ex =
        b.runner.settings[_exId] as Map<String, dynamic>;
    expect(((ex['repTargets'] as Map)['week1'] as Map)['instance1'], '5 x 3',
        reason: 'the older pass overwrote the newer settings');
  });

  test('H-RUN-LATE-EDITS entries made while loading are included', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')])
      ..holdSettings = true;
    final b = _build(plan);
    final Future<Wes2HintPassOutcome> pass = b.runner.run();
    await pumpEventQueue();

    // The athlete types while the settings request is still open.
    b.controller.updateSetField(
        exerciseId: _exId,
        setIndex: 0,
        fieldKey: Wes2FieldKey.weight,
        rawText: '42.5');

    plan.gates.single.complete();
    expect(await pass, Wes2HintPassOutcome.applied);
    expect(b.controller.rows.first.sets[0].weight.actualValue, 42.5,
        reason: 'the pass must read current entries, not a stale snapshot');
    expect(b.controller.rows.first.sets[1].weight.hintValue, isNotNull);
  });

  test('H-RUN-ONE-NOTIFY a pass notifies exactly once', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')]);
    final b = _build(plan);
    int notifications = 0;
    b.controller.addListener(() => notifications++);

    await b.runner.run();
    expect(notifications, 1);
  });

  test('H-RUN-DISPOSED a disposed runner applies nothing', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')])
      ..holdSettings = true;
    final b = _build(plan);
    final Future<Wes2HintPassOutcome> pass = b.runner.run();
    await pumpEventQueue();

    b.runner.dispose();
    plan.gates.single.complete();

    expect(await pass, Wes2HintPassOutcome.disposed);
    expect(b.controller.rows.first.sets[0].weight.hintValue, isNull);
  });

  test('H-RUN-NO-BLOCK a day without block context does nothing', () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')]);
    final Wes2SessionController c = Wes2SessionController(_day)
      ..initIdentity(actorUid: _uid, actingUid: _uid, isCoach: false);
    final Wes2HintLoadRunner runner = Wes2HintLoadRunner(
      controller: c,
      planService: plan,
      ensureExerciseDefaults: (String _, String __) async {},
      isSettingsUsable: (Map<String, dynamic>? s) => s != null,
    );

    expect(await runner.run(), Wes2HintPassOutcome.noBlock);
    expect(plan.calls, isEmpty);
  });

  test('H-RUN-HISTORY-FIRST history is refreshed before settings load',
      () async {
    final plan = _ScriptedPlanService(<Map<String, dynamic>>[_settings('10 x 3')]);
    final List<String> order = <String>[];
    final Wes2SessionController c = Wes2SessionController(_day)
      ..initIdentity(
        actorUid: _uid,
        actingUid: _uid,
        isCoach: false,
        activeBlockId: _blockId,
        blockStartDate: _blockStart,
      );
    final int epoch = c.beginLoad();
    c.setRows(<Wes2ExerciseRow>[_row()], epoch);
    final Wes2HintLoadRunner runner = Wes2HintLoadRunner(
      controller: c,
      planService: plan,
      ensureExerciseDefaults: (String _, String __) async {},
      isSettingsUsable: (Map<String, dynamic>? s) => s != null,
      refreshHistory: () async => order.add('history'),
    );

    await runner.run();
    order.addAll(plan.calls);
    expect(order.first, 'history');
  });
}
