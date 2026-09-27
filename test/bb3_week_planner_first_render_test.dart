// Full planner → panel first render with the viewed athlete's progression
// history deliberately NOT ready (structural proof that hydration cannot block
// the first render; no wall-clock timing).
//
// Exercises the real production path:
//   BB3WeekPlanner._boot → _loadBlocks → _selectBlock → _loadWeek
//     (history gate ensure() fired, never awaited) → 7 × getPlannedDay /
//     getCompletedExercises (fake Firestore via the service's test seam)
//   → _refreshExposureHintCache → getExposureHintIndex (cache-loaded position)
//   → _buildDayList (history readiness → withheld set / active instances)
//   → BB3DayPanel._computeRowHintsViaCascade → BB3HintService
//   → dispose flush → BB3PlannedExerciseService.savePlannedDay (fake only)
//
// Only two seams are used, both @visibleForTesting and inert in production:
// BB3PlannedExerciseService.debugFirestoreOverride and
// BB3WeekPlanner(historyGate:).

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/active_instance.dart';
import 'package:localtest222/bb3_day_panel.dart';
import 'package:localtest222/bb3_hint_service.dart';
import 'package:localtest222/bb3_history_gate.dart';
import 'package:localtest222/bb3_planned_exercise_service.dart';
import 'package:localtest222/bb3_week_planner.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/units/weight_unit.dart';
import 'package:localtest222/user_context.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bb3_wes2_instance_fixture.dart' as fx;

const String kCoach = 'coach_uid';
const String kAthlete = 'athlete_uid';
const String kBlock = 'block_first_render';
const String kLinearId = 'ex_contract_row';
const String kLinearName = 'Contract Test Row';

/// Counts readiness checks and readiness callbacks; hydration is a future the
/// test resolves by hand.
class _TestGate extends Bb3HistoryGate {
  _TestGate(this.hydration)
      : super(
          isReady: (String uid) => _TestGate.ready && uid == kAthlete,
          hydrate: (String uid) {
            _TestGate.hydrateCalls.add(uid);
            return hydration.future;
          },
        );

  final Completer<void> hydration;
  static bool ready = false;
  static final List<String> hydrateCalls = <String>[];
  int readyChecks = 0;
  int readyCallbacks = 0;

  @override
  bool isReady(String uid) {
    readyChecks++;
    return super.isReady(uid);
  }

  @override
  void ensure(String uid, void Function() onReady) => super.ensure(uid, () {
        readyCallbacks++;
        onReady();
      });
}

/// No local disk in widget tests: the planner's Isar layer (block-plan cache)
/// fails fast here — as production already tolerates — instead of opening a
/// real database whose I/O never completes inside the test's fake-async zone.
class _NoDiskPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw UnsupportedError('no disk in widget tests');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      throw UnsupportedError('no disk in widget tests');
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _mondayOf(DateTime d) =>
    _day(d).subtract(Duration(days: d.weekday - DateTime.monday));

void main() {
  final DateTime today = _day(DateTime.now());
  final DateTime weekStart = _mondayOf(today);
  final DateTime blockStart = weekStart.subtract(const Duration(days: 21));
  final DateTime blockEnd = weekStart.add(const Duration(days: 60));
  final List<String> priorDates = <int>[19, 16, 12, 9]
      .map((int n) =>
          ActiveInstanceResolver.dateKey(today.subtract(Duration(days: n))))
      .toList();
  final ({int weekIndex, int dayIndex}) todayWd =
      BB3PlannedExerciseService.dateToWeekDay(blockStart, today);
  final int todayIdxInWeek = today.difference(weekStart).inDays;

  final Map<String, dynamic> exposureSettings = fx.exerciseSettingsFor();
  final Map<String, dynamic> linearSettings =
      fx.exerciseSettingsFor(model: 'Linear, Classic');
  final Map<String, dynamic> allSettings = <String, dynamic>{
    fx.kExId: exposureSettings,
    kLinearId: linearSettings,
  };

  late FakeFirebaseFirestore db;
  late _TestGate gate;

  Future<void> seed() async {
    db = FakeFirebaseFirestore();
    final DocumentReference<Map<String, dynamic>> block = db
        .collection('users')
        .doc(kAthlete)
        .collection('planned_blocks')
        .doc(kBlock);
    await block.set(<String, dynamic>{
      'name': 'First render block',
      'startDate': Timestamp.fromDate(blockStart),
      'endDate': Timestamp.fromDate(blockEnd),
      'exerciseSettings': allSettings,
    });
    Map<String, dynamic> planned(String id, String name, int order) =>
        <String, dynamic>{
          'exerciseId': id,
          'name': name,
          'circuitIndex': 0,
          'orderIndex': order,
          'sets': List<Map<String, dynamic>>.generate(
              3, (_) => <String, dynamic>{}),
        };
    await block
        .collection('weeks')
        .doc('week_${todayWd.weekIndex}')
        .collection('days')
        .doc('day_${todayWd.dayIndex}')
        .set(<String, dynamic>{
      'exercises': <Map<String, dynamic>>[
        planned(fx.kExId, fx.kExName, 0),
        planned(kLinearId, kLinearName, 1),
      ],
    });
    for (final String d in priorDates) {
      await db
          .collection('users')
          .doc(kAthlete)
          .collection('workouts')
          .doc(d)
          .set(
        <String, dynamic>{
          'exercises': <Map<String, dynamic>>[
            <String, dynamic>{
              'exerciseId': fx.kExId,
              'name': fx.kExName,
              'sets': <Map<String, dynamic>>[
                <String, dynamic>{'weight': 100.0, 'reps': 5, 'rir': 2.0},
              ],
            },
          ],
        },
      );
    }
    BB3PlannedExerciseService.debugFirestoreOverride = db;
    ExerciseUnitRegistry.shared = ExerciseUnitRegistry(firestore: db);
    // In-memory history (the engine's source) is present from the start: the
    // gate — not missing data — is what withholds the exposure hints.
    fx.seedHistory(<Map<String, dynamic>>[
      for (final String d in priorDates) fx.workout(d, weight: 100),
    ]);
  }

  /// The hints the planner → panel path must show once ready.
  String exposureWeightText() {
    final ActiveInstance active = ActiveInstanceResolver.forSettings(
      exSettings: exposureSettings,
      exposurePosition: ActiveInstanceResolver.exposurePosition(
        selectedDate: today,
        completedDates: priorDates,
        blockStartDate: blockStart,
      ),
      weekIndex: todayWd.weekIndex,
    );
    final BB3SetHint h = BB3HintService.getHintsForSet(
      exerciseId: fx.kExId,
      exerciseName: fx.kExName,
      fullExerciseSettings: allSettings,
      weekIndex: todayWd.weekIndex,
      sessionIndex: active.repInstanceIndex,
      rirSessionIndex: todayWd.dayIndex,
      exposurePosition: active.exposurePosition,
      setIndex: 0,
      blockStartDate: blockStart,
      blockEndDate: blockEnd,
      selectedDate: today,
      uid: kAthlete,
    );
    return formatWeightNumber(h.weightKg!);
  }

  /// The linear (non-exposure) row's weight hint — its pre-existing path:
  /// within-week instance 0 today, RIR from the same index, no history.
  String linearWeightText() {
    final BB3SetHint h = BB3HintService.getHintsForSet(
      exerciseId: kLinearId,
      exerciseName: kLinearName,
      fullExerciseSettings: allSettings,
      weekIndex: todayWd.weekIndex,
      sessionIndex: 0,
      setIndex: 0,
      blockStartDate: blockStart,
      blockEndDate: blockEnd,
      selectedDate: today,
      uid: kAthlete,
    );
    return formatWeightNumber(h.weightKg!);
  }

  Finder todayPanel() => find.byKey(
      ValueKey<String>('day_$todayIdxInWeek${weekStart.toIso8601String()}'));

  Finder inToday(String text) =>
      find.descendant(of: todayPanel(), matching: find.text(text));

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoDiskPathProvider();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _TestGate.ready = false;
    _TestGate.hydrateCalls.clear();
    gate = _TestGate(Completer<void>());
    await seed();
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
    BB3PlannedExerciseService.debugFirestoreOverride = null;
    fx.clearHistory();
  });

  testWidgets(
      'unresolved history: planner and panels render, exposure hints withheld, '
      'released once by hydration; linear rows unchanged; dispose writes only '
      'to the fake', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final UserContext uc = UserContext(actorUid: kCoach, isCoach: true)
      ..actingAsUid = kAthlete;
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child:
          MaterialApp(home: Scaffold(body: BB3WeekPlanner(historyGate: gate))),
    ));
    await settle(tester);

    // ── Rendered while the hydration future is still unresolved ─────────────
    expect(gate.hydration.isCompleted, isFalse);
    expect(find.byType(BB3DayPanel), findsWidgets,
        reason: 'the planner shell and its day panels render');
    expect(todayPanel(), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: "the page's loading state does not wait for history");
    expect(inToday(fx.kExName), findsWidgets, reason: 'the row itself shows');

    // Hydration requested exactly once, for the VIEWED athlete (not the coach).
    expect(_TestGate.hydrateCalls, <String>[kAthlete]);

    // Exposure row: no guessed hint.
    final String exposureHint = exposureWeightText();
    expect(inToday(exposureHint), findsNothing,
        reason: 'no exposure-dependent weight hint before history is ready');

    // Non-exposure row: hinted normally while exposure hints are withheld.
    final String linearHint = linearWeightText();
    expect(linearHint, isNot(exposureHint), reason: 'distinguishable fixture');
    expect(inToday(linearHint), findsWidgets,
        reason: 'the linear row is not gated and keeps its hint');

    // ── Hydration completes: one readiness signal, correct hints appear ─────
    final int checksBefore = gate.readyChecks;
    _TestGate.ready = true;
    gate.hydration.complete();
    // The planner's load chain (fake Firestore futures) registers the gate's
    // continuation on the real event loop; let that loop turn once.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
    expect(gate.readyCallbacks, 1, reason: 'exactly one rebuild signal');
    expect(inToday(exposureHint), findsWidgets,
        reason: 'the correct exposure hint appears without interaction');
    final int checksAfterRelease = gate.readyChecks;
    expect(checksAfterRelease, greaterThan(checksBefore),
        reason: 'the release rebuilt the day list');
    await settle(tester);
    expect(gate.readyChecks, checksAfterRelease,
        reason: 'no further rebuilds once released (no rebuild loop)');
    expect(_TestGate.hydrateCalls, <String>[kAthlete],
        reason: 'still exactly one hydration');

    expect(inToday(linearHint), findsWidgets,
        reason: 'the linear row hint is unchanged by the release');

    // ── Dispose: the panel flush goes to the fake Firestore, never real ─────
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'FirebaseFirestore.instance would throw in tests');
    final DocumentSnapshot<Map<String, dynamic>> flushed = await db
        .collection('users')
        .doc(kAthlete)
        .collection('planned_blocks')
        .doc(kBlock)
        .collection('weeks')
        .doc('week_${todayWd.weekIndex}')
        .collection('days')
        .doc('day_${todayWd.dayIndex}')
        .get();
    expect(flushed.exists, isTrue, reason: 'the realistic flush path ran');
  });
}
