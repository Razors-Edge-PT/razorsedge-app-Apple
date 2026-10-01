// Aurelian 2.0 on the REAL WES2 screen: the action service drives the screen
// through its WorkoutActionPort adapter, and every change lands through the
// same canonical paths (typed-entry save, note saves, the Done coordinator,
// the Delete core, the floating timer) as the screen's own controls.
//
// Harness copied from wes2_voice_bridge_e2e_test.dart (its classes are private).

import 'dart:async';
import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_local_store.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/WES2_screen.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/user_context.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';
import 'package:localtest222/wes2_sync/wes2_sync_services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const String _uid = 'u1';
const String _blockId = 'b1';
const String _exA = 'ex_press';
const String _nameA = 'Seated Shoulder Dumbbell Press';
const String _exB = 'ex_row';
const String _exC = 'ex_curl';
const String _bench = 'AmfUWbF1DH3I7qPAdh5k';
const String _benchName = 'Bench Press, Barbell';
final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settingsFor(String id) => <String, dynamic>{
      'periodizationModel': 'Linear, Classic',
      'weeklyFrequency': 1,
      'increments': <String, dynamic>{'primary': 2.5},
      'repTargets': <String, dynamic>{
        'week1': <String, dynamic>{'instance1': '10 x 3'},
        'week2': <String, dynamic>{'instance1': '10 x 3'},
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
    };

class _FakePlanService implements Wes2PlanService {
  @override
  Future<Map<String, dynamic>> loadExerciseSettings(
          {required String uid, required String blockId}) async =>
      <String, dynamic>{
        for (final String id in <String>[_exA, _exB, _exC]) id: _settingsFor(id)
      };

  @override
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async =>
      const <Wes2ExerciseRow>[];

  @override
  Future<Map<String, String>> loadExerciseTypes(List<String> exerciseIds,
          {String uid = ''}) async =>
      <String, String>{};

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

class _OfflineRepository implements Wes2Repository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('offline'));
}

class _MemoryLocalStore implements Wes2LocalStore {
  final Map<String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})>
      drafts =
      <String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})>{};

  String _key(String uid, DateTime d) => '$uid|${d.year}-${d.month}-${d.day}';

  @override
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    int workoutDurationMs = 0,
  }) async {
    drafts[_key(uid, date)] = (
      rows: rows
          .map((Wes2ExerciseRow r) => Wes2ExerciseRow.fromJson(r.toJson()))
          .toList(),
      workoutDurationMs: workoutDurationMs,
    );
  }

  @override
  Future<({List<Wes2ExerciseRow> rows, int workoutDurationMs})?> loadDraft({
    required String uid,
    required DateTime date,
  }) async =>
      drafts[_key(uid, date)];

  @override
  Future<void> saveExpandedState(
      {required String uid,
      required DateTime date,
      required Map<String, bool> expandedByExerciseId}) async {}

  @override
  Future<Map<String, bool>> loadExpandedState(
          {required String uid, required DateTime date}) async =>
      const <String, bool>{};

  @override
  Future<void> saveScrollAnchor(
      {required String uid,
      required DateTime date,
      required String exerciseId,
      required int setIndex}) async {}

  @override
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor(
          {required String uid, required DateTime date}) async =>
      null;

  @override
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  }) async {}

  @override
  Future<void> dequeueOfflineSave(
      {required String uid, required DateTime date}) async {}
}

/// One fresh world: Firestore, draft store, outbox and sync engine.
class _World {
  _World({required this.online}) {
    fs = FakeFirebaseFirestore();
    store = _MemoryLocalStore();
    db = Wes2MutationDatabase.memory();
    outbox = Wes2MutationOutbox(db);
    engine = Wes2SyncEngine(
      outbox: outbox,
      repository: online
          ? FirestoreWes2Repository(firestore: fs)
          : _OfflineRepository(),
      currentActorUid: () => _uid,
      autoStartTimer: false,
    );
    Wes2SyncServices.debugOverride(outbox: outbox, engine: engine);
    ExerciseCatalog.debugFirestoreOverride = fs;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = fs;
  }

  final bool online;
  late final FakeFirebaseFirestore fs;
  late final _MemoryLocalStore store;
  late final Wes2MutationDatabase db;
  late final Wes2MutationOutbox outbox;
  late final Wes2SyncEngine engine;

  Future<void> seed(
      List<({String id, String name, int sets})> exercises) async {
    await fs.collection('exercises').doc(_bench).set(
        <String, dynamic>{'name': _benchName, 'category': 'Horizontal Press'});
    await fs.collection('exercises').doc('db_bench').set(<String, dynamic>{
      'name': 'Bench Press, Dumbbell',
      'category': 'Horizontal Press'
    });
    await fs.collection('exercises').doc('cable_row_a').set(<String, dynamic>{
      'name': 'Seated Cable Row',
      'category': 'Horizontal Pull'
    });
    await fs.collection('exercises').doc('cable_row_b').set(<String, dynamic>{
      'name': 'Cable Row, Seated',
      'category': 'Horizontal Pull'
    });
    final List<Map<String, dynamic>> docs = <Map<String, dynamic>>[
      for (int i = 0; i < exercises.length; i++)
        <String, dynamic>{
          'exerciseId': exercises[i].id,
          'name': exercises[i].name,
          'circuitIndex': 0,
          'orderIndex': i,
          'setCount': exercises[i].sets,
          'sets': <Map<String, dynamic>>[
            for (int s = 0; s < exercises[i].sets; s++)
              <String, dynamic>{'setIndex': s},
          ],
        },
    ];
    if (online) {
      await fs
          .collection('users')
          .doc(_uid)
          .collection('workouts')
          .doc('2026-01-12')
          .set(<String, dynamic>{
        'userId': _uid,
        'date': '2026-01-12',
        'exercises': docs,
        'wesPlannedExercises': <dynamic>[],
      });
    } else {
      await store.saveDraft(
        uid: _uid,
        date: _day,
        rows: <Wes2ExerciseRow>[
          for (final Map<String, dynamic> d in docs)
            Wes2ExerciseRow(
              exerciseId: d['exerciseId'] as String,
              name: d['name'] as String,
              circuitIndex: 0,
              orderIndex: d['orderIndex'] as int,
              setCount: d['setCount'] as int,
              sets: <Wes2SetState>[
                for (int s = 0; s < (d['setCount'] as int); s++)
                  Wes2SetState(setIndex: s)
              ],
              source: Wes2RowSource.wes2Manual,
            ),
        ],
      );
    }
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    final UserContext uc = UserContext(actorUid: _uid, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: _blockId, startDate: _blockStart);
    await tester.pumpWidget(
      ChangeNotifierProvider<UserContext>.value(
        value: uc,
        child: MaterialApp(
          home: Wes2Screen(
            initialDate: _day,
            repositoryOverride: online
                ? FirestoreWes2Repository(firestore: fs)
                : _OfflineRepository(),
            planServiceOverride: _FakePlanService(),
            localStoreOverride: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    Wes2SyncServices.debugReset();
    await engine.dispose();
    await db.close();
  }

  /// The stored workout's set values per exercise ("40.0x8@1.0").
  Future<Map<String, List<String>>> storedSets() async {
    final Map<String, dynamic>? doc = (await fs
            .collection('users')
            .doc(_uid)
            .collection('workouts')
            .doc('2026-01-12')
            .get())
        .data();
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final dynamic e
        in (doc?['exercises'] as List<dynamic>? ?? <dynamic>[])) {
      final Map<String, dynamic> ex = e as Map<String, dynamic>;
      out[ex['exerciseId'] as String] = <String>[
        for (final dynamic s in ex['sets'] as List<dynamic>)
          '${(s as Map<String, dynamic>)['weight']}x${s['reps']}@${s['rir']}',
      ];
    }
    return out;
  }

  /// Queued field mutations as comparable "exercise|set|field=value" lines.
  Future<List<String>> queuedFieldEdits() async {
    final List<Wes2MutationRow> rows = await outbox.pendingForDay(
        actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    return <String>[
      for (final Wes2MutationRow r in rows)
        if (r.kind == Wes2MutationKind.field)
          () {
            final Map<String, dynamic> p =
                Wes2Mutation.decodePayload(r.payloadJson);
            return '${r.exerciseId}|${r.setIndex}|${Wes2Mutation.fieldKeyFrom(p)?.name}=${p['value']}';
          }(),
    ]..sort();
  }
}

List<Wes2SetRow> _rows(WidgetTester tester) =>
    tester.widgetList<Wes2SetRow>(find.byType(Wes2SetRow)).toList();

/// Runs one Aurelian 2.0 action through the real service on the real screen.
Future<Map<String, dynamic>> _act(
    WidgetTester tester, String action, Map<String, Object?> payload,
    {String? token}) async {
  String? out;
  unawaited(AurelianActionService.instance
      .handleJson(envelope(action, payload, confirmationToken: token))
      .then((String r) => out = r));
  for (int i = 0; i < 300 && out == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (i > 10) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
  }
  await tester.pumpAndSettle();
  expect(out, isNotNull, reason: 'no answer for $action');
  return jsonDecode(out!) as Map<String, dynamic>;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AurelianCommandBus.instance.debugReset();
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
    ExerciseUnitRegistry.shared = ExerciseUnitRegistry();
    AurelianActionService.instance.athletePort = FakeAthletes(actor: _uid);
  });

  tearDown(() {
    AurelianCommandBus.instance.debugReset();
    AurelianActionService.instance.athletePort = null;
    ExerciseCatalog.debugFirestoreOverride = null;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = null;
  });

  const List<({String id, String name, int sets})> twoExercises =
      <({String id, String name, int sets})>[
    (id: _exA, name: _nameA, sets: 3),
    (id: _bench, name: _benchName, sets: 3),
  ];

  testWidgets(
      'set.update runs the typed-entry path: same durable writes, verified, never Done',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(twoExercises);
    await w.pump(tester);
    final Map<String, dynamic> r = await _act(
        tester, 'set.update', <String, Object?>{
      'exercise': 'bench press',
      'set': 1,
      'weight': 150,
      'reps': 5,
      'rir': 1
    });
    expect(r['status'], 'success');
    expect(r['verified'], isTrue);
    expect(r['summary'], '$_benchName · Set 1: 150 kg · 5 reps · RIR 1');
    final Wes2SetRow benchSet1 = _rows(tester)[3];
    expect(benchSet1.set.weight.actualValue, 150.0);
    expect(benchSet1.set.reps.actualValue, 5);
    expect(await w.queuedFieldEdits(), <String>[
      '$_bench|0|reps=5',
      '$_bench|0|rir=1.0',
      '$_bench|0|weight=150.0'
    ]);
    // Entering values never marks the exercise completed.
    final Map<String, dynamic> read =
        await _act(tester, 'workout.read', <String, Object?>{});
    final List<dynamic> list =
        (read['data'] as Map<String, dynamic>)['exercises'] as List<dynamic>;
    expect(list.map((dynamic e) => (e as Map<String, dynamic>)['done']),
        <bool>[false, false]);
    // A correction ("make that 152.5") then undo restores exactly 150.
    final Map<String, dynamic> c = await _act(
        tester, 'set.update', <String, Object?>{'set': 1, 'weight': 152.5});
    expect(_rows(tester)[3].set.weight.actualValue, 152.5);
    final Map<String, dynamic> u = await _act(
        tester, 'undo', <String, Object?>{'undoToken': c['undoToken']});
    expect(u['status'], 'success');
    expect(_rows(tester)[3].set.weight.actualValue, 150.0);
    expect(_rows(tester)[3].set.reps.actualValue, 5);
    await w.close(tester);
  });

  testWidgets(
      'set note and explicit completion go through the screen\'s own saves',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(twoExercises);
    await w.pump(tester);
    final Map<String, dynamic> n =
        await _act(tester, 'set.note', <String, Object?>{
      'exercise': 'bench press',
      'set': 3,
      'text': 'third rep velocity was 0.23',
    });
    expect(n['status'], 'success');
    expect(_rows(tester)[5].set.executionNote, 'third rep velocity was 0.23');
    expect(
        (await _act(tester, 'exercise.complete', <String, Object?>{
          'exercise': 'bench press',
          'completed': true
        }))['status'],
        'invalid',
        reason: 'nothing logged yet');
    await _act(tester, 'set.update', <String, Object?>{
      'exercise': 'bench press',
      'set': 1,
      'weight': 100,
      'reps': 5
    });
    final Map<String, dynamic> done = await _act(tester, 'exercise.complete',
        <String, Object?>{'exercise': 'bench press', 'completed': true});
    expect(done['summary'], '$_benchName marked completed');
    final List<Wes2MutationRow> queued = await w.outbox
        .pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    expect(queued.map((Wes2MutationRow r) => r.kind),
        contains(Wes2MutationKind.markDone));
    await w.close(tester);
  });

  testWidgets(
      'the general workout timer is the floating timer, not a set stopwatch',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(twoExercises);
    await w.pump(tester);
    final Map<String, dynamic> s =
        await _act(tester, 'timer.general.start', <String, Object?>{});
    expect(s['summary'], 'Workout timer started');
    expect(AurelianActionService.instance.workoutPort!.generalTimer.visible,
        isTrue);
    expect(AurelianActionService.instance.workoutPort!.generalTimer.running,
        isTrue);
    await tester.pump(const Duration(seconds: 2));
    final Map<String, dynamic> t =
        await _act(tester, 'timer.general.stop', <String, Object?>{});
    expect(t['status'], 'success');
    expect(AurelianActionService.instance.workoutPort!.generalTimer.running,
        isFalse);
    expect(
        (await _act(tester, 'timer.exercise.start',
            <String, Object?>{'exercise': 'bench press', 'set': 1}))['status'],
        'invalid',
        reason: 'bench press is not timed');
    await w.close(tester);
  });

  testWidgets(
      'deleting a populated exercise asks first, then runs the Delete core; undo restores its values',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(twoExercises);
    await w.pump(tester);
    await _act(tester, 'set.update', <String, Object?>{
      'exercise': 'bench press',
      'set': 2,
      'weight': 120,
      'reps': 3
    });
    final Map<String, dynamic> ask = await _act(tester, 'exercise.delete',
        <String, Object?>{'exercise': 'bench press'});
    expect(ask['status'], 'requires_confirmation');
    expect(find.text(_benchName), findsWidgets, reason: 'nothing deleted yet');
    final Map<String, dynamic> ok = await _act(
        tester, 'exercise.delete', <String, Object?>{'exercise': 'bench press'},
        token: ask['confirmationToken'] as String);
    expect(ok['status'], 'success');
    expect(
        AurelianActionService.instance.workoutPort!.exercises
            .map((e) => e.exerciseId),
        <String>[_exA]);
    final Map<String, dynamic> u = await _act(
        tester, 'undo', <String, Object?>{'undoToken': ok['undoToken']});
    expect(u['status'], 'success');
    final bench = AurelianActionService.instance.workoutPort!.exercises
        .firstWhere((e) => e.exerciseId == _bench);
    expect(bench.set(1).weightKg, 120.0);
    expect(bench.set(1).reps, 3);
    await w.close(tester);
  });
}
