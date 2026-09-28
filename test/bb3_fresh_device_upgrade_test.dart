// Fresh device / app update through BB3 (the week planner where exercises are
// dragged into days): opening the populated pre-update active block and
// leaving without an edit writes nothing, and adding / reordering exercises
// in a day never touches the block's per-exercise settings.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/bb3_day_panel.dart';
import 'package:localtest222/bb3_history_gate.dart';
import 'package:localtest222/bb3_models.dart';
import 'package:localtest222/bb3_planned_exercise_service.dart';
import 'package:localtest222/bb3_week_planner.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/user_context.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pre_update_block_fixture.dart';

class _NoDiskPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw UnsupportedError('no disk in widget tests');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      throw UnsupportedError('no disk in widget tests');
}

String _enc(Object? o) => jsonEncode(o,
    toEncodable: (v) =>
        v is Timestamp ? v.millisecondsSinceEpoch : v.toString());

/// Database state minus the fake's empty `.doc(id)` placeholders.
String _state(FakeFirebaseFirestore db) {
  Object? prune(Object? v) {
    if (v is Map) {
      final out = <String, Object?>{};
      v.forEach((k, val) {
        final p = prune(val);
        if (p is Map && p.isEmpty) return;
        out[k.toString()] = p;
      });
      return out;
    }
    if (v is List) return v.map(prune).toList();
    return v;
  }

  return jsonEncode(prune(jsonDecode(db.dump())));
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

void main() {
  final DateTime today = _day(DateTime.now());
  final DateTime weekStart =
      today.subtract(Duration(days: today.weekday - DateTime.monday));
  final DateTime blockStart = weekStart.subtract(const Duration(days: 14));
  final DateTime blockEnd = weekStart.add(const Duration(days: 69));

  late FakeFirebaseFirestore db;
  late PathProviderPlatform originalPathProvider;

  DocumentReference<Map<String, dynamic>> blockRef() => db
      .collection('users')
      .doc(kFxAthlete)
      .collection('planned_blocks')
      .doc(kFxActive);

  ({int weekIndex, int dayIndex}) todayWd() =>
      BB3PlannedExerciseService.dateToWeekDay(blockStart, today);

  Map<String, dynamic> row(String id, int order) => {
        'exerciseId': id,
        'name': kFxNames[id],
        'circuitIndex': 0,
        'orderIndex': order,
        'sets': [
          {'weight': 60.0, 'reps': 8},
          <String, dynamic>{},
        ],
        'plannedByCoach': true, // a field BB3's own model does not carry
      };

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoDiskPathProvider();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = FakeFirebaseFirestore();
    await seedPreUpdateBlock(db);
    // Keep the block around "today" whenever the test runs.
    await blockRef().update({
      'startDate': Timestamp.fromDate(blockStart),
      'endDate': Timestamp.fromDate(blockEnd),
    });
    final wd = todayWd();
    await blockRef()
        .collection('weeks')
        .doc('week_${wd.weekIndex}')
        .collection('days')
        .doc('day_${wd.dayIndex}')
        .set({
      'exercises': [row(kFxBench, 0), row(kFxSquat, 1)]
    });
    BB3PlannedExerciseService.debugFirestoreOverride = db;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = db;
    ExerciseCatalog.debugFirestoreOverride = db;
    ExerciseUnitRegistry.shared = ExerciseUnitRegistry(firestore: db);
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
    BB3PlannedExerciseService.debugFirestoreOverride = null;
    BlockExerciseDefaultsRepository.debugFirestoreOverride = null;
    ExerciseCatalog.debugFirestoreOverride = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets(
      'fresh cache: BB3 opens the active block and leaves with zero writes',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final before = _state(db);

    final uc = UserContext(actorUid: kFxAthlete, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: kFxActive);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child: MaterialApp(
        home: Scaffold(
          body: BB3WeekPlanner(
            historyGate: Bb3HistoryGate(
              isReady: (_) => true,
              hydrate: (_) async {},
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(find.byType(BB3DayPanel), findsWidgets);
    expect(find.text(kFxNames[kFxBench]!), findsWidgets,
        reason: 'the planned day loaded');
    expect(_state(db), before, reason: 'opening wrote nothing');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(_state(db), before,
        reason: 'leaving without an edit flushes nothing');
  });

  test(
      'adding (dragging) an exercise that already has settings, and '
      'reordering a day, preserve every settings map byte for byte', () async {
    final settingsBefore = _enc((await blockRef().get()).data()!);

    // What the BB3 add/drag path runs for an exercise with stored settings.
    for (final id in kFxMembers) {
      await BlockExerciseDefaultsRepository.ensureExerciseDefaults(
          uid: kFxAthlete, blockId: kFxActive, exerciseId: id);
    }
    expect(_enc((await blockRef().get()).data()!), settingsBefore);

    // Reorder today's day (squat first) — only the day document changes.
    final wd = todayWd();
    await BB3PlannedExerciseService.savePlannedDay(
      uid: kFxAthlete,
      blockId: kFxActive,
      weekIndex: wd.weekIndex,
      dayIndex: wd.dayIndex,
      exercises: [
        BB3Exercise.fromMap(row(kFxSquat, 0)),
        BB3Exercise.fromMap(row(kFxBench, 1)),
        BB3Exercise.fromMap(row(kFxRow, 2)),
      ],
    );
    expect(_enc((await blockRef().get()).data()!), settingsBefore,
        reason: 'the block document (all settings) is untouched');
    final day = await blockRef()
        .collection('weeks')
        .doc('week_${wd.weekIndex}')
        .collection('days')
        .doc('day_${wd.dayIndex}')
        .get();
    expect((day.data()!['exercises'] as List).map((e) => e['exerciseId']),
        [kFxSquat, kFxBench, kFxRow]);
  });
}
