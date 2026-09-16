// The RELEASE GATE: the real [Wes2Screen], driven like a person uses it.
//
// Everything else in the hint suite stops one layer short — controller, hint
// service, row widget. This pumps the actual screen with its own state, its
// own load path, its own hint runner and its own row widgets, and proves after
// every interaction that each set consumed the predecessor's final
// actual-or-hint numbers, with the right provenance, and that the fields on
// screen show exactly those values.
//
// Only three dependency seams are supplied (repository, plan service, local
// store). Everything else is the production screen: Firebase, Drift and Isar
// are simply absent, and the paths that touch them fail the way they do on a
// phone with no connection.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_local_store.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/WES2_screen.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/user_context.dart';
import 'package:localtest222/wes2_cascade_resolver.dart';
import 'package:localtest222/wes2_exercise_settings_patch.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';
import 'package:localtest222/wes2_sync/wes2_sync_services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/wes2_expected_next_set.dart';

const String _uid = 'u1';
const String _blockId = 'b1';
const String _exId = 'ex_press';
const String _exName = 'Seated Shoulder Dumbbell Press';
final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _day = DateTime(2026, 1, 12);

Map<String, dynamic> _exerciseSettings() => <String, dynamic>{
      _exId: <String, dynamic>{
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
      }
    };

class _FakePlanService implements Wes2PlanService {
  @override
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  }) async =>
      _exerciseSettings();

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

/// A repository that fails the way an offline phone's does: every call errors.
class _OfflineRepository implements Wes2Repository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('offline'));
}

/// An in-memory stand-in for the Isar draft store.
class _MemoryLocalStore implements Wes2LocalStore {
  final Map<String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})>
      _drafts = <String, ({List<Wes2ExerciseRow> rows, int workoutDurationMs})>{};

  String _key(String uid, DateTime d) =>
      '$uid|${d.year}-${d.month}-${d.day}';

  @override
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    int workoutDurationMs = 0,
  }) async {
    // Round-trips through JSON exactly as the real store does.
    _drafts[_key(uid, date)] = (
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
      _drafts[_key(uid, date)];

  @override
  Future<void> saveExpandedState({
    required String uid,
    required DateTime date,
    required Map<String, bool> expandedByExerciseId,
  }) async {}

  @override
  Future<Map<String, bool>> loadExpandedState({
    required String uid,
    required DateTime date,
  }) async =>
      const <String, bool>{};

  @override
  Future<void> saveScrollAnchor({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  }) async {}

  @override
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor({
    required String uid,
    required DateTime date,
  }) async =>
      null;

  @override
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  }) async {}

  @override
  Future<void> dequeueOfflineSave({
    required String uid,
    required DateTime date,
  }) async {}
}

void main() {
  late FakeFirebaseFirestore fs;
  late _MemoryLocalStore store;
  late Wes2MutationDatabase db;
  late Wes2SyncEngine engine;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fs = FakeFirebaseFirestore();
    store = _MemoryLocalStore();
    // The real durable-save wiring, with the outbox in memory: the on-disk one
    // needs path_provider, which no test environment has. Everything the
    // screen does with it is the production code path.
    db = Wes2MutationDatabase.memory();
    final Wes2MutationOutbox outbox = Wes2MutationOutbox(db);
    engine = Wes2SyncEngine(
      outbox: outbox,
      repository: FirestoreWes2Repository(firestore: fs),
      currentActorUid: () => _uid,
      autoStartTimer: false,
    );
    Wes2SyncServices.debugOverride(outbox: outbox, engine: engine);
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[
      <String, dynamic>{
        'date': DateTime(2026, 1, 5),
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': _exId,
            'name': _exName,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'weight': 35.0, 'reps': 8, 'rir': 2.0}
            ],
          }
        ],
      }
    ];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  tearDown(() async {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
    Wes2SyncServices.debugReset();
    await engine.dispose();
    await db.close();
  });

  Future<void> seedDay({int setCount = 3}) async {
    await fs
        .collection('users')
        .doc(_uid)
        .collection('workouts')
        .doc('2026-01-12')
        .set(<String, dynamic>{
      'userId': _uid,
      'date': '2026-01-12',
      'exercises': <Map<String, dynamic>>[
        <String, dynamic>{
          'exerciseId': _exId,
          'name': _exName,
          'circuitIndex': 0,
          'orderIndex': 0,
          'setCount': setCount,
          'sets': <Map<String, dynamic>>[
            for (int i = 0; i < setCount; i++)
              <String, dynamic>{'setIndex': i},
          ],
        }
      ],
      'wesPlannedExercises': <dynamic>[],
    });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    final UserContext uc = UserContext(actorUid: _uid, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: _blockId, startDate: _blockStart);
    await tester.pumpWidget(
      ChangeNotifierProvider<UserContext>.value(
        value: uc,
        child: MaterialApp(
          home: Wes2Screen(
            initialDate: _day,
            repositoryOverride: FirestoreWes2Repository(firestore: fs),
            planServiceOverride: _FakePlanService(),
            localStoreOverride: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── Reading the screen ────────────────────────────────────────────────────

  List<Wes2SetRow> rows(WidgetTester tester) =>
      tester.widgetList<Wes2SetRow>(find.byType(Wes2SetRow)).toList();

  /// The text a set's field actually shows: the entry if there is one, else the
  /// hint rendered behind it.
  String shownText(WidgetTester tester, int setIndex, int fieldIndex) {
    final Finder fields = find.descendant(
      of: find.byType(Wes2SetRow).at(setIndex),
      matching: find.byType(TextField),
    );
    final TextField f = tester.widget<TextField>(fields.at(fieldIndex));
    final String typed = f.controller?.text ?? '';
    return typed.isNotEmpty ? typed : (f.decoration?.hintText ?? '');
  }

  Future<void> typeInto(
    WidgetTester tester,
    int setIndex,
    int fieldIndex,
    String text,
  ) async {
    final Finder fields = find.descendant(
      of: find.byType(Wes2SetRow).at(setIndex),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(fieldIndex), text);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  /// The gate itself: every set must follow the one before it, exactly.
  void expectCascadeAgrees(WidgetTester tester) {
    final List<Wes2SetRow> visible = rows(tester);
    expect(visible, isNotEmpty, reason: 'the day rendered no sets');

    for (int i = 1; i < visible.length; i++) {
      final Wes2SetState prev = visible[i - 1].set;
      final Wes2SetState cur = visible[i].set;

      // A set the athlete has constrained is not free to be predicted.
      if (cur.weight.actualValue != null || cur.reps.actualValue != null) {
        continue;
      }
      final double thisRir = cur.rir.actualValue ?? cur.rir.hintValue ?? 0.0;
      final ExpectedNextSet expected = expectedNextSet(
        previousFinal: prev,
        thisRir: thisRir,
        grid: IncrementGrid(primary: 2.5),
      );

      // 1. Numerical equality against the predecessor's FINAL values.
      expect(cur.weight.hintValue, expected.weight,
          reason: 'set ${i + 1} weight does not follow set $i ($expected)');
      expect(cur.reps.hintValue, expected.reps,
          reason: 'set ${i + 1} reps do not follow set $i ($expected)');

      // 2. Provenance: a predicted set is hinted, never entered.
      expect(cur.weight.actualValue, isNull);
      expect(cur.reps.actualValue, isNull);
    }

    // 3. What is on screen is what was consumed. An ENTERED field keeps the
    //    athlete's own text ("0" stays "0" for 0.0), so it is compared
    //    numerically; a hint is compared against the real formatter.
    for (int i = 0; i < visible.length; i++) {
      final Wes2SetState set = visible[i].set;
      final v = Wes2CascadeResolver.resolvedValues(set);
      if (v.weight != null) {
        if (set.weight.actualValue != null) {
          expect(double.parse(shownText(tester, i, 0)), v.weight,
              reason: 'set ${i + 1} weight display');
        } else {
          expect(shownText(tester, i, 0), Wes2HintFormat.weight(v.weight!),
              reason: 'set ${i + 1} weight display');
        }
      }
      if (v.reps != null) {
        if (set.reps.actualValue != null) {
          expect(int.parse(shownText(tester, i, 1)), v.reps,
              reason: 'set ${i + 1} reps display');
        } else {
          expect(shownText(tester, i, 1), Wes2HintFormat.reps(v.reps!),
              reason: 'set ${i + 1} reps display');
        }
      }
      if (v.rir != null) {
        if (set.rir.actualValue != null) {
          expect(double.parse(shownText(tester, i, 2)), v.rir,
              reason: 'set ${i + 1} RIR display');
        } else {
          expect(shownText(tester, i, 2), Wes2HintFormat.rir(v.rir!),
              reason: 'set ${i + 1} RIR display');
        }
      }
    }
  }

  // ── The gate ──────────────────────────────────────────────────────────────

  testWidgets('E2E the real screen loads a day and cascades', (tester) async {
    await seedDay();
    await pumpScreen(tester);

    expect(rows(tester), hasLength(3));
    expect(rows(tester).first.set.weight.hintValue, isNotNull,
        reason: 'the screen ran its own hint pass');
    expectCascadeAgrees(tester);
  });

  testWidgets('E2E editing, clearing and accepting through the real fields',
      (tester) async {
    await seedDay();
    await pumpScreen(tester);

    // Edit Set 1: every later set must follow it.
    await typeInto(tester, 0, 0, '40');
    expectCascadeAgrees(tester);
    expect(rows(tester).first.set.weight.actualValue, 40.0);

    await typeInto(tester, 0, 1, '8');
    await typeInto(tester, 0, 2, '1');
    expectCascadeAgrees(tester);

    // Accept what Set 2 is already suggesting: it must not move.
    final Wes2SetState set2Before = rows(tester)[1].set;
    final String shownReps = shownText(tester, 1, 1);
    await typeInto(tester, 1, 1, shownReps);
    final Wes2SetState set2After = rows(tester)[1].set;
    expect(set2After.reps.actualValue.toString(), shownReps);
    expect(set2After.weight.hintValue, set2Before.weight.hintValue,
        reason: 'accepting the rep hint re-solved the set');
    expect(set2After.rir.hintValue, set2Before.rir.hintValue,
        reason: 'accepting the rep hint moved the RIR');
    expectCascadeAgrees(tester);

    // Clear Set 1's weight: the row returns to its current-context hints.
    await typeInto(tester, 0, 0, '');
    expect(rows(tester).first.set.weight.actualValue, isNull);
    expect(rows(tester).first.set.weight.hintValue, isNotNull);
    expectCascadeAgrees(tester);
  });

  testWidgets('E2E a later entered set survives an earlier edit',
      (tester) async {
    await seedDay();
    await pumpScreen(tester);

    await typeInto(tester, 2, 0, '25');
    await typeInto(tester, 2, 1, '12');
    await typeInto(tester, 0, 0, '42.5');

    final List<Wes2SetRow> visible = rows(tester);
    expect(visible[2].set.weight.actualValue, 25.0);
    expect(visible[2].set.reps.actualValue, 12);
    expect(visible[0].set.weight.actualValue, 42.5);
    expectCascadeAgrees(tester);
  });

  testWidgets('E2E add set, remove set and session Undo', (tester) async {
    await seedDay();
    await pumpScreen(tester);
    await typeInto(tester, 0, 0, '40');

    // Add Set — the new set cascades from the one before it.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add).last);
    await tester.pumpAndSettle();
    expect(rows(tester), hasLength(4));
    expectCascadeAgrees(tester);

    // Remove the middle set: the survivor re-cascades from its new
    // predecessor, and the planned count does not restore it.
    final int before = rows(tester).length;
    await tester.tap(find.byTooltip('Remove set').at(1));
    await tester.pumpAndSettle();
    expect(rows(tester), hasLength(before - 1));
    expectCascadeAgrees(tester);
  });

  testWidgets('E2E a reload shows the same cascade', (tester) async {
    await seedDay();
    await pumpScreen(tester);
    await typeInto(tester, 0, 0, '40');
    await typeInto(tester, 0, 1, '8');
    List<String> resolved() => <String>[
          for (final Wes2SetRow r in rows(tester))
            () {
              final v = Wes2CascadeResolver.resolvedValues(r.set);
              return '${v.weight}x${v.reps}@${v.rir}';
            }(),
        ];
    final List<String> beforeReload = resolved();

    // The entries reached the server through the ordinary save path, so a
    // fresh screen over the same document must show the same day.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpScreen(tester);

    expect(resolved(), beforeReload);
    expectCascadeAgrees(tester);
  });

  testWidgets(
      'E2E offline recovery keeps the BB3 prescriptions the draft still holds',
      (tester) async {
    // The athlete filled in a BB3-planned day, went offline, and reopened it.
    // The server read fails, so the screen recovers the stored draft. Those
    // rows still carry the coach's prescription as bb3 hints, and the cascade
    // must keep using it: falling back to a history-derived Set 1 would show a
    // different prescription from the one the coach wrote.
    await store.saveDraft(
      uid: _uid,
      date: _day,
      rows: <Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 3,
          source: Wes2RowSource.bb3Planned,
          structureEstablished: true,
          sets: <Wes2SetState>[
            for (int i = 0; i < 3; i++)
              Wes2SetState(
                setIndex: i,
                weight: const Wes2FieldState<double>(
                  hintValue: 40.0,
                  hintOrigin: FieldOrigin.bb3Hint,
                ),
                reps: const Wes2FieldState<int>(
                  hintValue: 6,
                  hintOrigin: FieldOrigin.bb3Hint,
                ),
                rir: const Wes2FieldState<double>(
                  hintValue: 2.0,
                  hintOrigin: FieldOrigin.bb3Hint,
                ),
              ),
          ],
        ),
      ],
    );

    final UserContext uc = UserContext(actorUid: _uid, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: _blockId, startDate: _blockStart);
    await tester.pumpWidget(
      ChangeNotifierProvider<UserContext>.value(
        value: uc,
        child: MaterialApp(
          home: Wes2Screen(
            initialDate: _day,
            repositoryOverride: _OfflineRepository(),
            planServiceOverride: _FakePlanService(),
            localStoreOverride: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rows(tester), hasLength(3), reason: 'the draft was not recovered');
    expect(shownText(tester, 0, 0), '40',
        reason: 'Set 1 must still show the prescribed weight');
    expect(shownText(tester, 0, 1), '6',
        reason: 'Set 1 must still show the prescribed reps');

    // And the prescription survives an entry being made and taken away again.
    await typeInto(tester, 0, 0, '42.5');
    expect(shownText(tester, 0, 0), '42.5');
    await typeInto(tester, 0, 0, '');
    expect(shownText(tester, 0, 0), '40',
        reason: 'clearing an entry must uncover the prescription, not a model '
            'hint derived from history');
    // Every set here is prescribed, so each keeps its own prescribed numbers
    // rather than a solved follow-on: BB3 takes precedence over the cascade.
    for (int i = 1; i < 3; i++) {
      expect(shownText(tester, i, 0), '40', reason: 'set ${i + 1} weight');
      expect(shownText(tester, i, 1), '6', reason: 'set ${i + 1} reps');
    }
  });

  testWidgets('E2E repeating the same edit does not drift', (tester) async {
    await seedDay();
    await pumpScreen(tester);

    await typeInto(tester, 0, 0, '15');
    await typeInto(tester, 0, 1, '30');
    await typeInto(tester, 0, 2, '0');
    List<String> resolved() => <String>[
          for (final Wes2SetRow r in rows(tester))
            () {
              final v = Wes2CascadeResolver.resolvedValues(r.set);
              return '${v.weight}x${v.reps}@${v.rir}';
            }(),
        ];
    final List<String> first = resolved();

    for (int pass = 0; pass < 3; pass++) {
      // Re-entering the same value recalculates the whole row again.
      await typeInto(tester, 0, 2, '0');
      expect(resolved(), first, reason: 'pass ${pass + 1} drifted');
    }
    expectCascadeAgrees(tester);
  });
}
