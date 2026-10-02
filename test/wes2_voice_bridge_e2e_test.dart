// Aurelian voice commands on the REAL WES2 screen, through the real command
// bus, compared with the same values typed into the real fields.
//
// Harness as in wes2_screen_cascade_e2e_test.dart: only the repository, plan
// service and local store are supplied; the durable outbox and sync engine
// are the production code with the outbox in memory.

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
import 'package:localtest222/WES2_widgets/WES2_exercise_picker.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/WES2_widgets/WES2_weight_converter_dialog.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/units/weight_unit.dart';
import 'package:localtest222/user_context.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';
import 'package:localtest222/wes2_sync/wes2_sync_services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _uid = 'u1';
const String _blockId = 'b1';
const String _exA = 'ex_press';
const String _nameA = 'Seated Shoulder Dumbbell Press';
const String _exB = 'ex_row';
const String _nameB = 'Row, Cable Seated';
const String _exC = 'ex_curl';
const String _nameC = 'Bicep Curl, Dumbbell';
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
  Future<Map<String, dynamic>> loadExerciseSettings({required String uid, required String blockId}) async =>
      <String, dynamic>{for (final String id in <String>[_exA, _exB, _exC]) id: _settingsFor(id)};

  @override
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async =>
      const <Wes2ExerciseRow>[];

  @override
  Future<Map<String, String>> loadExerciseTypes(List<String> exerciseIds, {String uid = ''}) async =>
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
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(StateError('offline'));
}

class _MemoryLocalStore implements Wes2LocalStore {
  final Map<String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})> drafts =
      <String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})>{};

  int saveDraftCalls = 0;

  String _key(String uid, DateTime d) => '$uid|${d.year}-${d.month}-${d.day}';

  @override
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    int workoutDurationMs = 0,
  }) async {
    saveDraftCalls++;
    drafts[_key(uid, date)] = (
      rows: rows.map((Wes2ExerciseRow r) => Wes2ExerciseRow.fromJson(r.toJson())).toList(),
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
  Future<void> saveExpandedState({required String uid, required DateTime date, required Map<String, bool> expandedByExerciseId}) async {}

  @override
  Future<Map<String, bool>> loadExpandedState({required String uid, required DateTime date}) async => const <String, bool>{};

  @override
  Future<void> saveScrollAnchor({required String uid, required DateTime date, required String exerciseId, required int setIndex}) async {}

  @override
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor({required String uid, required DateTime date}) async => null;

  @override
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  }) async {}

  @override
  Future<void> dequeueOfflineSave({required String uid, required DateTime date}) async {}
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
      repository: online ? FirestoreWes2Repository(firestore: fs) : _OfflineRepository(),
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

  Future<void> seed(List<({String id, String name, int sets})> exercises) async {
    await fs.collection('exercises').doc(_bench).set(<String, dynamic>{'name': _benchName, 'category': 'Horizontal Press'});
    await fs.collection('exercises').doc('db_bench').set(<String, dynamic>{'name': 'Bench Press, Dumbbell', 'category': 'Horizontal Press'});
    await fs.collection('exercises').doc('cable_row_a').set(<String, dynamic>{'name': 'Seated Cable Row', 'category': 'Horizontal Pull'});
    await fs.collection('exercises').doc('cable_row_b').set(<String, dynamic>{'name': 'Cable Row, Seated', 'category': 'Horizontal Pull'});
    final List<Map<String, dynamic>> docs = <Map<String, dynamic>>[
      for (int i = 0; i < exercises.length; i++)
        <String, dynamic>{
          'exerciseId': exercises[i].id,
          'name': exercises[i].name,
          'circuitIndex': 0,
          'orderIndex': i,
          'setCount': exercises[i].sets,
          'sets': <Map<String, dynamic>>[
            for (int s = 0; s < exercises[i].sets; s++) <String, dynamic>{'setIndex': s},
          ],
        },
    ];
    if (online) {
      await fs.collection('users').doc(_uid).collection('workouts').doc('2026-01-12').set(<String, dynamic>{
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
              sets: <Wes2SetState>[for (int s = 0; s < (d['setCount'] as int); s++) Wes2SetState(setIndex: s)],
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
            repositoryOverride: online ? FirestoreWes2Repository(firestore: fs) : _OfflineRepository(),
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
    final Map<String, dynamic>? doc =
        (await fs.collection('users').doc(_uid).collection('workouts').doc('2026-01-12').get()).data();
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final dynamic e in (doc?['exercises'] as List<dynamic>? ?? <dynamic>[])) {
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
    final List<Wes2MutationRow> rows =
        await outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    return <String>[
      for (final Wes2MutationRow r in rows)
        if (r.kind == Wes2MutationKind.field)
          () {
            final Map<String, dynamic> p = Wes2Mutation.decodePayload(r.payloadJson);
            return '${r.exerciseId}|${r.setIndex}|${Wes2Mutation.fieldKeyFrom(p)?.name}=${p['value']}';
          }(),
    ]..sort();
  }
}

List<Wes2SetRow> _rows(WidgetTester tester) => tester.widgetList<Wes2SetRow>(find.byType(Wes2SetRow)).toList();

Future<void> _type(WidgetTester tester, int rowIndex, int field, String text) async {
  final Finder fields = find.descendant(of: find.byType(Wes2SetRow).at(rowIndex), matching: find.byType(TextField));
  await tester.enterText(fields.at(field), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// Says [command] through the real bus (as the native bridge would deliver it).
Future<AurelianResult> _say(WidgetTester tester, AurelianCommand command) async {
  AurelianResult? result;
  unawaited(AurelianCommandBus.instance.dispatch(command).then((AurelianResult r) => result = r));
  for (int i = 0; i < 300 && result == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    // Structural edits also reach the set-video store, whose (absent in tests)
    // platform services answer on the real event loop, not the fake clock.
    if (i > 10) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
  }
  await tester.pumpAndSettle();
  expect(result, isNotNull, reason: 'no answer for $command');
  return result!;
}

List<String> _setState(Wes2SetState s) => <String>[
      '${s.weight.actualValue}',
      '${s.reps.actualValue}',
      '${s.rir.actualValue}',
      '${s.weight.hintValue}',
      '${s.reps.hintValue}',
      '${s.rir.hintValue}',
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AurelianCommandBus.instance.debugReset();
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
    ExerciseUnitRegistry.shared = ExerciseUnitRegistry();
  });

  tearDown(() {
    AurelianCommandBus.instance.debugReset();
    ExerciseCatalog.debugFirestoreOverride = null;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = null;
  });

  const List<({String id, String name, int sets})> threeExercises = <({String id, String name, int sets})>[
    (id: _exA, name: _nameA, sets: 3),
    (id: _exB, name: _nameB, sets: 3),
    (id: _exC, name: _nameC, sets: 3),
  ];

  testWidgets('voice set entry gives the SAME model, cascade and stored workout as typing', (WidgetTester tester) async {
    // Typed by hand.
    final _World typed = _World(online: true);
    await typed.seed(threeExercises);
    await typed.pump(tester);
    await _type(tester, 0, 0, '50');
    await _type(tester, 0, 1, '5');
    await _type(tester, 0, 2, '2');
    final List<List<String>> typedState = <List<String>>[for (final Wes2SetRow r in _rows(tester)) _setState(r.set)];
    await typed.engine.processNow();
    final Map<String, List<String>> typedStored = await typed.storedSets();
    await typed.close(tester);

    // Said by voice, one command per field.
    AurelianCommandBus.instance.debugReset();
    final _World voice = _World(online: true);
    await voice.seed(threeExercises);
    await voice.pump(tester);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
            setNumber: 1, weight: 50, weightUnit: ExerciseWeightUnit.kg))).isOk, isTrue);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 5))).isOk, isTrue);
    final AurelianResult rir = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, rir: 2));
    expect(rir.message, '$_nameA · Set 1: RIR 2');
    final List<List<String>> voiceState = <List<String>>[for (final Wes2SetRow r in _rows(tester)) _setState(r.set)];
    await voice.engine.processNow();
    final Map<String, List<String>> voiceStored = await voice.storedSets();
    await voice.close(tester);

    expect(voiceState, typedState, reason: 'actuals AND the recomputed hints of every set');
    expect(voiceStored, typedStored, reason: 'the same durable writes reached the server');
    expect(voiceStored[_exA]!.first, '50.0x5@2.0');
  });

  testWidgets('offline: voice entry is queued durably exactly like typed entry, unrelated fields untouched',
      (WidgetTester tester) async {
    final _World typed = _World(online: false);
    await typed.seed(threeExercises);
    await typed.pump(tester);
    await _type(tester, 3, 0, '30'); // exercise B, set 1
    await _type(tester, 3, 1, '10');
    final List<String> typedQueue = await typed.queuedFieldEdits();
    await typed.close(tester);

    AurelianCommandBus.instance.debugReset();
    final _World voice = _World(online: false);
    await voice.seed(threeExercises);
    await voice.pump(tester);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise))).message, '$_nameB (2 of 3)');
    final AurelianResult r = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 30, weightUnit: ExerciseWeightUnit.kg, reps: 10));
    expect(r.message, '$_nameB · Set 1: 30 kg · 10 reps');
    final List<String> voiceQueue = await voice.queuedFieldEdits();
    // Nothing else was written: exercise A and the other sets of B are untouched.
    final List<Wes2SetRow> rows = _rows(tester);
    expect(rows[0].set.weight.actualValue, isNull);
    expect(rows[4].set.weight.actualValue, isNull);
    expect(rows[3].set.rir.actualValue, isNull);
    await voice.close(tester);
    // Leaving the screen saved the local draft, as it does after typing.
    final List<Wes2ExerciseRow> draft = voice.store.drafts.values.single.rows;
    expect(draft.firstWhere((Wes2ExerciseRow x) => x.exerciseId == _exB).sets.first.weight.actualValue, 30.0);

    expect(voiceQueue, typedQueue);
    expect(voiceQueue, <String>['$_exB|0|reps=10', '$_exB|0|weight=30.0']);
  });

  testWidgets('pounds and the exercise display unit convert exactly like the lb field', (WidgetTester tester) async {
    final _World w = _World(online: false);
    ExerciseUnitRegistry.shared.noteLocalChoice(_uid, _exA, ExerciseWeightUnit.lb);
    await w.seed(threeExercises);
    await w.pump(tester);
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, weight: 135, weightUnit: ExerciseWeightUnit.lb));
    expect(_rows(tester)[0].set.weight.actualValue, closeTo(61.235, 0.001));
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 2, weight: 100));
    expect(_rows(tester)[1].set.weight.actualValue, closeTo(45.359, 0.001), reason: 'no unit said: the exercise shows lb');
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 3, weight: 50, weightUnit: ExerciseWeightUnit.kg));
    expect(_rows(tester)[2].set.weight.actualValue, 50.0);
    await w.close(tester);
  });

  testWidgets('arbitrary set N, and invalid values change nothing', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(<({String id, String name, int sets})>[(id: _exA, name: _nameA, sets: 6)]);
    await w.pump(tester);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 6, reps: 4))).isOk, isTrue);
    expect(_rows(tester)[5].set.reps.actualValue, 4);
    final List<String> before = await w.queuedFieldEdits();
    final AurelianResult tooFar = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 7, reps: 4));
    expect(tooFar.status, AurelianStatus.invalid);
    expect(tooFar.message, contains('add set'));
    final AurelianResult badRir = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 5, rir: 11));
    expect(badRir.status, AurelianStatus.invalid);
    expect(_rows(tester)[0].set.reps.actualValue, isNull, reason: 'validated first: nothing half-applied');
    expect(await w.queuedFieldEdits(), before);
    await w.close(tester);
  });

  testWidgets('add exercise opens the real WES2 picker; select adds it and it becomes the voice target',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    final AurelianResult opened = await _say(tester, const AurelianCommand(AurelianCommandKind.addExercise));
    expect(opened.isOk, isTrue);
    expect(find.byType(Wes2ExercisePicker), findsOneWidget);

    // Two genuinely different exercises share these words: asked, not guessed.
    final AurelianResult which = await _say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'row cable seated'));
    expect(which.status, AurelianStatus.ambiguous);
    expect(which.candidates, unorderedEquals(<String>['Seated Cable Row', 'Cable Row, Seated']));
    expect(find.byType(Wes2ExercisePicker), findsOneWidget);

    // An exercise already in the day is not offered again.
    final AurelianResult already = await _say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: _nameA));
    expect(already.status, AurelianStatus.notFound);

    final AurelianResult added = await _say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'bench press barbell'));
    expect(added.message, '$_benchName added');
    expect(find.byType(Wes2ExercisePicker), findsNothing);
    expect(find.text(_benchName), findsWidgets);

    // Set entry now goes to the new exercise.
    final AurelianResult set = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 8));
    expect(set.message, startsWith(_benchName));
    expect(await w.queuedFieldEdits(), contains('$_bench|0|reps=8'));
    await w.close(tester);
  });

  testWidgets('next / previous / select move the voice target and scroll it into view with the card keys',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise))).message, '$_nameB (2 of 3)');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise))).message, '$_nameC (3 of 3)');
    final AurelianResult last = await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise));
    expect(last.status, AurelianStatus.unavailable);
    // The target card is on screen (scrolled by layout, not coordinates).
    final Rect card = tester.getRect(find.text(_nameC).first);
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(900));
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.previousExercise))).message, '$_nameB (2 of 3)');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'seated shoulder dumbbell press'))).message,
        '$_nameA selected');
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 3));
    expect(_rows(tester)[0].set.reps.actualValue, 3);
    await w.close(tester);
  });

  testWidgets('add note to set N opens the existing set-note dialog for setIndex N-1', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    final AurelianResult r = await _say(tester, const AurelianCommand(AurelianCommandKind.openSetNote, setNumber: 2));
    expect(r.isOk, isTrue);
    expect(find.text('$_nameA — Set 2 Notes'), findsOneWidget, reason: 'the real dialog, 1-based title from setIndex 1');
    // The note field has focus, ready for "type …".
    final EditableText field = tester.widget<EditableText>(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isTrue);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'felt very easy');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_rows(tester)[1].set.executionNote, 'felt very easy');
    // A workout command with the dialog open is refused, not dismissing it.
    await _say(tester, const AurelianCommand(AurelianCommandKind.openSetNote, setNumber: 1));
    final AurelianResult blocked = await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise));
    expect(blocked.message, 'Close the open dialog first');
    expect(find.byType(AlertDialog), findsOneWidget);
    await w.close(tester);
  });

  testWidgets('weight converter from the real WES2 menu: a pending edit survives, calculator input changes nothing, voice cannot bypass it',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    // A typed weight whose field still has focus: it is saved on focus loss.
    final Finder setFields =
        find.descendant(of: find.byType(Wes2SetRow).at(0), matching: find.byType(TextField));
    await tester.enterText(setFields.at(0), '50');
    await tester.pump();

    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weight converter'));
    await tester.pumpAndSettle();
    expect(find.byType(Wes2WeightConverterDialog), findsOneWidget);
    expect(find.text('Weight converter'), findsOneWidget, reason: 'the dialog title');

    // Opening the menu ran the normal focus-loss save of the pending edit.
    expect(await w.queuedFieldEdits(), <String>['$_exA|0|weight=50.0']);
    expect(_rows(tester)[0].set.weight.actualValue, 50.0);

    // Snapshot everything the calculator must leave alone.
    final List<List<String>> setsBefore = <List<String>>[for (final Wes2SetRow r in _rows(tester)) _setState(r.set)];
    final int pendingBefore =
        (await w.outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12')).length;
    final int draftSavesBefore = w.store.saveDraftCalls;
    final String draftBefore = jsonEncode(
        w.store.drafts.values.single.rows.map((Wes2ExerciseRow r) => r.toJson()).toList());
    final VoidCallback? undoBefore =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo)).onPressed;

    final Finder input =
        find.descendant(of: find.byType(Wes2WeightConverterDialog), matching: find.byType(TextField));
    final Finder result = find.byKey(const ValueKey('weightConverterResult'));
    await tester.enterText(input, '225');
    await tester.pump();
    expect(tester.widget<Text>(result).data, '102.058 kg');
    await tester.tap(find.text('kg → lb'));
    await tester.pumpAndSettle();
    await tester.enterText(input, '100');
    await tester.pump();
    expect(tester.widget<Text>(result).data, '220.462 lb');
    await tester.enterText(input, '-5');
    await tester.pump();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.enterText(input, '60');
    await tester.pump();

    // Voice workout actions are refused while it is open and do not dismiss it.
    final AurelianResult next = await _say(tester, const AurelianCommand(AurelianCommandKind.nextExercise));
    expect(next.message, 'Close the open dialog first');
    final AurelianResult set = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 70, weightUnit: ExerciseWeightUnit.kg));
    expect(set.message, 'Close the open dialog first');
    expect(find.byType(Wes2WeightConverterDialog), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '60');

    expect(<List<String>>[for (final Wes2SetRow r in _rows(tester)) _setState(r.set)], setsBefore);
    expect((await w.outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12')).length,
        pendingBefore);
    expect(w.store.saveDraftCalls, draftSavesBefore, reason: 'calculator input never enters the save path');

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // Back on the same WES2 session, with the edit intact and nothing else changed.
    expect(find.byType(Wes2WeightConverterDialog), findsNothing);
    expect(find.byType(Wes2Screen), findsOneWidget);
    expect(tester.widget<TextField>(setFields.at(0)).controller!.text, '50');
    expect(<List<String>>[for (final Wes2SetRow r in _rows(tester)) _setState(r.set)], setsBefore);
    expect(await w.queuedFieldEdits(), <String>['$_exA|0|weight=50.0']);
    expect(
        jsonEncode(w.store.drafts.values.single.rows.map((Wes2ExerciseRow r) => r.toJson()).toList()),
        draftBefore);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo)).onPressed == null,
        undoBefore == null);
    await w.close(tester);
  });

  testWidgets('add set and exercise done use the canonical paths', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    final AurelianResult notYet = await _say(tester, const AurelianCommand(AurelianCommandKind.markExerciseDone));
    expect(notYet.status, AurelianStatus.invalid, reason: 'the card offers Done only once a set is logged');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.addSet))).message, '$_nameA · set 4 added');
    expect(_rows(tester).length, 10);
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 20, weightUnit: ExerciseWeightUnit.kg, reps: 10, rir: 2));
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.markExerciseDone))).message, '$_nameA marked done');
    final List<Wes2MutationRow> queued =
        await w.outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    expect(queued.map((Wes2MutationRow r) => r.kind), contains(Wes2MutationKind.markDone));
    expect(jsonDecode(queued.lastWhere((Wes2MutationRow r) => r.kind == Wes2MutationKind.markDone).payloadJson), isA<Map<String, dynamic>>());
    await w.close(tester);
  });
  // ── Voice UX expansion ──────────────────────────────────────────────────────

  List<String> names(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((Text t) => t.data ?? '')
      .where((String d) => <String>[_nameA, _nameB, _nameC, _benchName, 'Bench Press, Dumbbell', 'Seated Cable Row']
          .contains(d))
      .toSet()
      .toList();

  testWidgets('a named exercise takes the set entry and becomes the voice target', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    // "for set 1 of row cable seated put 30 for 10": the words in another order.
    final AurelianResult r = await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 30, weightUnit: ExerciseWeightUnit.kg, reps: 10, exercise: 'cable seated row'));
    expect(r.message, '$_nameB · Set 1: 30 kg · 10 reps');
    expect(await w.queuedFieldEdits(), <String>['$_exB|0|reps=10', '$_exB|0|weight=30.0']);
    // It is now the target: an unnamed command follows it.
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 2, reps: 9));
    expect(_rows(tester)[4].set.reps.actualValue, 9);
    // A close misspelling is fine for entering values (fuzzy, clear margin).
    final AurelianResult fuzzy = await _say(tester,
        const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 7, exercise: 'bicep curl dumbell'));
    expect(fuzzy.message, startsWith(_nameC));
    // Not in the workout: said so, nothing written.
    final List<String> before = await w.queuedFieldEdits();
    final AurelianResult missing = await _say(tester,
        const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 7, exercise: 'deadlift'));
    expect(missing.status, AurelianStatus.notFound);
    expect(await w.queuedFieldEdits(), before);
    await w.close(tester);
  });

  testWidgets('clear set N empties its logged fields through the typed-entry path; the set and its note stay',
      (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 40, weightUnit: ExerciseWeightUnit.kg, reps: 8, rir: 1));
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 2, reps: 6));
    final AurelianResult r = await _say(tester, const AurelianCommand(AurelianCommandKind.clearSet, setNumber: 1));
    expect(r.message, '$_nameA · set 1 cleared');
    final List<Wes2SetRow> rows = _rows(tester);
    expect(rows.length, 9, reason: 'no set removed');
    expect(rows[0].set.weight.actualValue, isNull);
    expect(rows[0].set.reps.actualValue, isNull);
    expect(rows[0].set.rir.actualValue, isNull);
    expect(rows[1].set.reps.actualValue, 6, reason: 'other sets untouched');
    // Explicit nulls reached the durable outbox (the last write per field wins).
    final List<Wes2MutationRow> queued =
        await w.outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    final Map<String, Object?> last = <String, Object?>{};
    for (final Wes2MutationRow q in queued.where((Wes2MutationRow q) => q.kind == Wes2MutationKind.field && q.setIndex == 0)) {
      final Map<String, dynamic> pl = Wes2Mutation.decodePayload(q.payloadJson);
      last['${Wes2Mutation.fieldKeyFrom(pl)?.name}'] = pl['value'];
    }
    expect(last, <String, Object?>{'weight': null, 'reps': null, 'rir': null});
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.clearSet, setNumber: 1))).message,
        '$_nameA · set 1 is already empty');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.clearSet, setNumber: 5))).status,
        AurelianStatus.invalid);
    await w.close(tester);
  });

  testWidgets('remove set N and delete an exercise reuse the canonical cores', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(<({String id, String name, int sets})>[
      (id: _exA, name: _nameA, sets: 3),
      (id: _exC, name: _nameC, sets: 3),
      (id: 'ex_solo', name: 'Landmine Press', sets: 1),
    ]);
    await w.pump(tester);
    final int before = _rows(tester).length;
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.removeSet, setNumber: 2))).message,
        '$_nameA · set 2 removed');
    expect(_rows(tester).length, before - 1);
    expect(find.text('Set removed'), findsNothing, reason: 'Undo exactly as the button offers it: only for logged values');
    // The only set is never removed by "remove set": the exercise must be named.
    final AurelianResult only = await _say(tester,
        const AurelianCommand(AurelianCommandKind.removeSet, setNumber: 1, exercise: 'landmine press'));
    expect(only.status, AurelianStatus.invalid);
    expect(only.message, contains('delete'));
    // Deleting never accepts a fuzzy name…
    final AurelianResult fuzzy = await _say(tester,
        const AurelianCommand(AurelianCommandKind.deleteExercise, exercise: 'bicep curl dumbell'));
    expect(fuzzy.status, AurelianStatus.notFound);
    expect(names(tester), contains(_nameC));
    // …but the exercise's own words, unique in this workout, are enough.
    final AurelianResult deleted =
        await _say(tester, const AurelianCommand(AurelianCommandKind.deleteExercise, exercise: 'bicep curl'));
    expect(deleted.message, 'Deleted $_nameC');
    expect(names(tester), isNot(contains(_nameC)));
    final List<Wes2MutationRow> queued =
        await w.outbox.pendingForDay(actorUid: _uid, athleteUid: _uid, dateKey: '2026-01-12');
    expect(queued.map((Wes2MutationRow r) => r.kind),
        containsAll(<String>[Wes2MutationKind.removeSet, Wes2MutationKind.deleteExercise]));
    await w.close(tester);
  });

  testWidgets('replace resolves the new exercise in the Replace picker list and asks which one', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    final AurelianResult which = await _say(tester, const AurelianCommand(AurelianCommandKind.replaceExercise,
        exercise: 'bicep curl dumbbell', replacement: 'bench press'));
    expect(which.status, AurelianStatus.ambiguous);
    expect(which.message, 'Which bench press?');
    expect(which.candidates, unorderedEquals(<String>[_benchName, 'Bench Press, Dumbbell']));
    expect(names(tester), contains(_nameC), reason: 'nothing changed while asking');
    final AurelianResult done = await _say(tester, const AurelianCommand(AurelianCommandKind.replaceExercise,
        exercise: 'bicep curl dumbbell', replacement: 'bench press', choices: <String>[_benchName]));
    expect(done.message, 'Replaced $_nameC with $_benchName');
    expect(names(tester), isNot(contains(_nameC)));
    expect(names(tester), contains(_benchName));
    // The replacement is the target now.
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 5));
    expect(await w.queuedFieldEdits(), contains('$_bench|0|reps=5'));
    await w.close(tester);
  });

  testWidgets('add several exercises: all resolved first, nothing added while one is unclear', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    final AurelianResult which = await _say(tester, const AurelianCommand(AurelianCommandKind.addExercises,
        phrase: 'bench press and seated cable row'));
    expect(which.status, AurelianStatus.ambiguous);
    expect(which.message, 'Which bench press?');
    expect(names(tester), isNot(contains('Seated Cable Row')), reason: 'no partial add');
    final AurelianResult added = await _say(tester, const AurelianCommand(AurelianCommandKind.addExercises,
        phrase: 'bench press and seated cable row', choices: <String>['Bench Press, Dumbbell']));
    expect(added.message, 'Added Bench Press, Dumbbell and Seated Cable Row');
    expect(names(tester), containsAll(<String>['Bench Press, Dumbbell', 'Seated Cable Row']));
    // The last one added is the target.
    final AurelianResult current =
        await _say(tester, const AurelianCommand(AurelianCommandKind.workoutAction, action: AurelianWorkoutAction.currentExercise));
    expect(current.message, 'On Seated Cable Row (5 of 5)');
    final AurelianResult unknown = await _say(tester,
        const AurelianCommand(AurelianCommandKind.addExercises, phrase: 'bench press barbell and zercher hover'));
    expect(unknown.status, AurelianStatus.notFound);
    expect(names(tester), isNot(contains(_benchName)));
    await w.close(tester);
  });

  testWidgets('named mark done, circuits and exercise controls', (WidgetTester tester) async {
    final _World w = _World(online: false);
    await w.seed(threeExercises);
    await w.pump(tester);
    await _say(tester, const AurelianCommand(AurelianCommandKind.setFields,
        setNumber: 1, weight: 12, weightUnit: ExerciseWeightUnit.kg, reps: 10, rir: 2, exercise: _nameC));
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.markExerciseDone, exercise: 'bicep curl'))).message,
        '$_nameC marked done');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.moveToCircuit, circuit: 1))).message,
        '$_nameC is already in Circuit 1');
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.moveToCircuit, circuit: 2))).status,
        AurelianStatus.invalid);
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.addExerciseToCircuit, circuit: 3))).status,
        AurelianStatus.invalid);
    final AurelianResult pick =
        await _say(tester, const AurelianCommand(AurelianCommandKind.addExerciseToCircuit, circuit: 1));
    expect(pick.isOk, isTrue);
    expect(find.byType(Wes2ExercisePicker), findsOneWidget, reason: 'the circuit\'s own Add Exercise picker');
    // With the picker open, "add bench press barbell" picks it there.
    expect((await _say(tester, const AurelianCommand(AurelianCommandKind.addExercises, phrase: 'bench press barbell'))).message,
        '$_benchName added');
    expect(find.byType(Wes2ExercisePicker), findsNothing);
    await w.close(tester);
  });
}
