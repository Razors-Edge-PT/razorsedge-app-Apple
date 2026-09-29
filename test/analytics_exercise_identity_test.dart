// Analytics exercise identity: ONE semantic identity per exercise, shared by
// E1RM, rep target, Velocity and Top Sets.
//
// Regressions covered:
//  * WES2 rows carry `exerciseId` (not `id`). They matched in the raw stage
//    but lost their id when parsed into `Exercise`, and the E1RM, rep-target
//    and Top Sets stages then re-matched and discarded them — only Velocity
//    (which reads raw maps) still showed data.
//  * Bench Press, Barbell history split across its catalogue id, a lower-cased
//    copy, a legacy NAME-FORM id ("Bench Press, Barbell") and id-less legacy
//    rows showed three picker rows ("(ID AmfU)", "(ID Benc)", "(older
//    entries)").

import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:localtest222/analytics_history_loader.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/exercise_details_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:localtest222/workout_model.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kAthlete = 'athleteUid';
const String kBench = 'AmfUWbF1DH3I7qPAdh5k';
const String kBenchName = 'Bench Press, Barbell';

/// The obsolete Bench id verified in production: older clients stored the
/// exercise NAME as its id.
const String kOldBench = 'Bench Press, Barbell';
const String kSquat = 'heeBViVINHO6tUScSd6y';
const String kSquatName = 'Back Squat, Barbell';

Map<String, dynamic> entry(
        Object? id, String name, List<Map<String, dynamic>> sets,
        {String idField = 'exerciseId'}) =>
    <String, dynamic>{if (id != null) idField: id, 'name': name, 'sets': sets};

Map<String, dynamic> set5(num weight, {double velocity = 0.5, double rir = 1}) =>
    <String, dynamic>{
      'weight': weight,
      'reps': 5,
      'rir': rir,
      'velocity': velocity,
    };

DateTime daysAgo(int n) {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day).subtract(Duration(days: n));
}

RawWorkoutDoc day(int n, List<Map<String, dynamic>> exercises,
        {String? docId}) =>
    RawWorkoutDoc(id: docId ?? 'd$n', date: daysAgo(n), exercises: exercises);

/// Richard's Bench, as stored in production, within the default 2-week view.
List<RawWorkoutDoc> benchHistory() => <RawWorkoutDoc>[
      day(1, <Map<String, dynamic>>[
        entry(kBench, kBenchName, <Map<String, dynamic>>[set5(100, velocity: 0.50)]),
        entry(kSquat, kSquatName, <Map<String, dynamic>>[set5(140, velocity: 0.40)]),
      ]),
      day(3, <Map<String, dynamic>>[
        entry(kBench.toLowerCase(), kBenchName,
            <Map<String, dynamic>>[set5(95, velocity: 0.55)]),
      ]),
      day(5, <Map<String, dynamic>>[
        entry(kOldBench, kBenchName, <Map<String, dynamic>>[set5(90, velocity: 0.60)]),
      ]),
      day(7, <Map<String, dynamic>>[
        entry(null, kBenchName, <Map<String, dynamic>>[set5(85, velocity: 0.62)]),
      ]),
    ];

CatalogExercise catalogEntry(String id, String name,
        {ExerciseSource source = ExerciseSource.global}) =>
    CatalogExercise(
      id: id,
      name: name,
      category: 'Strength',
      bodyParts: const <String>['Chest'],
      bodyPart: 'Chest',
      source: source,
    );

List<CatalogExercise> catalogue() => <CatalogExercise>[
      catalogEntry(kBench, kBenchName),
      catalogEntry(kSquat, kSquatName),
    ];

Map<String, String> catalogNames() =>
    <String, String>{for (final CatalogExercise c in catalogue()) c.id: c.name};

String dateLabel(int n) => DateFormat('dd-MM-yyyy').format(daysAgo(n));

Future<void> pumpAnalytics(
  WidgetTester tester, {
  required List<RawWorkoutDoc> history,
  Future<List<CatalogExercise>> Function(String uid)? catalog,
  String? exerciseId,
  String? exerciseName,
}) async {
  tester.view.physicalSize = const Size(430, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<UserContext>.value(
      value: UserContext(actorUid: kAthlete, isCoach: false),
      child: ExerciseDetailsScreen(
        exerciseId: exerciseId,
        exerciseName: exerciseName,
        historyFetcherForUid: (String uid) =>
            ({required DateTime since}) async => RawFetchResult.ok(history),
        catalogLoaderForUid:
            catalog ?? (String uid) async => catalogue(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder get picker => find.byType(DropdownButton<ExerciseHistoryOption>);

ExerciseHistoryOption? pickerValue(WidgetTester tester) =>
    tester.widget<DropdownButton<ExerciseHistoryOption>>(picker).value;

List<String> pickerLabels(WidgetTester tester) => tester
    .widget<DropdownButton<ExerciseHistoryOption>>(picker)
    .items!
    .map((DropdownMenuItem<ExerciseHistoryOption> i) => i.value!.label)
    .toList();

/// Spot counts of the E1RM Trend (first) and rep-target (second) charts.
List<int> e1rmChartSpotCounts(WidgetTester tester) => tester
    .widgetList<LineChart>(find.byType(LineChart))
    .map((LineChart c) => c.data.lineBarsData
        .fold<int>(0, (int n, LineChartBarData b) => n + b.spots.length))
    .toList();

Future<void> savePick(Map<String, Object?> pick) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'analytics_last_exercise:$kAthlete': jsonEncode(pick),
  });
}

Future<Map<String, dynamic>?> savedPick() async {
  final String? raw = (await SharedPreferences.getInstance())
      .getString('analytics_last_exercise:$kAthlete');
  return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('WES2 exerciseId rows', () {
    final List<RawWorkoutDoc> wes2 = <RawWorkoutDoc>[
      day(2, <Map<String, dynamic>>[
        entry(kBench, kBenchName, <Map<String, dynamic>>[set5(100)]),
      ]),
    ];

    test('produce E1RM-derived workouts that keep their id', () {
      final List<Workout> workouts = deriveWorkoutsForExercise(
        docs: wes2,
        targetId: kBench,
        targetName: kBenchName,
        targetLegacyNames: const <String>{},
      );
      expect(workouts, hasLength(1));
      expect(workouts.single.exercises.single.id, kBench,
          reason: 'the id matched from `exerciseId` survives parsing');
      expect(matchingSetsOf(workouts.single).single.weight, 100);
    });

    test('still produce Velocity samples', () {
      final List<VelocitySample> samples = deriveVelocitySamplesForExercise(
        docs: wes2,
        targetId: kBench,
        targetName: kBenchName,
        targetLegacyNames: const <String>{},
      );
      expect(samples.map((VelocitySample s) => s.weight).toList(), <double>[100]);
    });

    testWidgets('fill the E1RM Trend, rep-target chart and Top Sets',
        (WidgetTester tester) async {
      await pumpAnalytics(tester,
          history: wes2, exerciseId: kBench, exerciseName: kBenchName);
      expect(tester.takeException(), isNull);
      expect(e1rmChartSpotCounts(tester), <int>[1, 1],
          reason: 'E1RM Trend and the default 5-rep target each plot the day');
      expect(find.text(dateLabel(2)), findsOneWidget, reason: 'Top Sets row');
    });
  });

  group('Exercise.fromFirestore identity', () {
    Map<String, dynamic> row(Map<String, dynamic> ids) =>
        <String, dynamic>{...ids, 'name': 'X', 'sets': <Object>[]};

    test('reads `id` and WES2 `exerciseId`', () {
      expect(Exercise.fromFirestore(row(<String, dynamic>{'id': 'A'})).id, 'A');
      expect(
          Exercise.fromFirestore(row(<String, dynamic>{'exerciseId': 'B'})).id,
          'B');
      expect(Exercise.fromFirestore(row(<String, dynamic>{})).id, isNull);
    });

    test('a non-blank `id` wins over a conflicting `exerciseId`; blank is no id',
        () {
      expect(
          Exercise.fromFirestore(
                  row(<String, dynamic>{'id': 'A', 'exerciseId': 'B'}))
              .id,
          'A');
      expect(
          Exercise.fromFirestore(
                  row(<String, dynamic>{'id': ' ', 'exerciseId': 'B'}))
              .id,
          'B');
      expect(rawExerciseIdOf(<String, dynamic>{'id': '', 'exerciseId': ''}),
          isNull);
    });
  });

  group('one Bench Press, Barbell identity', () {
    test('mixed canonical / case / obsolete / id-less rows: ONE picker option',
        () {
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
          docs: benchHistory(), catalogNameById: catalogNames());
      final List<ExerciseHistoryOption> bench = options
          .where((ExerciseHistoryOption o) => o.name.startsWith('Bench'))
          .toList();
      expect(bench, hasLength(1));
      final ExerciseHistoryOption b = bench.single;
      expect(b.id, kBench);
      expect(b.label, kBenchName,
          reason: 'no raw id fragment and no "older entries" suffix');
      expect(b.memberIds, <String>{kBench.toLowerCase(), kOldBench.toLowerCase()});
      expect(b.legacyNames, <String>{kBenchName});
      expect(options.map((ExerciseHistoryOption o) => o.label).toList(),
          <String>[kSquatName, kBenchName]..sort());
    });

    test('E1RM / rep-target sets and Velocity all get the unified history', () {
      final ExerciseHistoryOption b = deriveExerciseHistoryOptions(
              docs: benchHistory(), catalogNameById: catalogNames())
          .firstWhere((ExerciseHistoryOption o) => o.id == kBench);
      final List<Workout> workouts = deriveWorkoutsForExercise(
        docs: benchHistory(),
        targetId: b.id,
        targetName: b.name,
        targetLegacyNames: b.legacyNames,
        targetMemberIds: b.memberIds,
      );
      expect(
          workouts
              .expand(matchingSetsOf)
              .map((SetDetails s) => s.weight)
              .toSet(),
          <double>{100, 95, 90, 85});
      final List<VelocitySample> samples = deriveVelocitySamplesForExercise(
        docs: benchHistory(),
        targetId: b.id,
        targetName: b.name,
        targetLegacyNames: b.legacyNames,
        targetMemberIds: b.memberIds,
      );
      expect(samples.map((VelocitySample s) => s.weight).toSet(),
          <double>{100, 95, 90, 85});
      expect(samples.every((VelocitySample s) => s.weight != 140), isTrue,
          reason: 'never another exercise');
    });

    test('the choice itself matches exactly its member rows', () {
      final ExerciseHistoryOption b = deriveExerciseHistoryOptions(
              docs: benchHistory(), catalogNameById: catalogNames())
          .firstWhere((ExerciseHistoryOption o) => o.id == kBench);
      expect(b.matchesEntry(kBench, kBenchName), isTrue);
      expect(b.matchesEntry(kBench.toLowerCase(), kBenchName), isTrue);
      expect(b.matchesEntry(kOldBench, kBenchName), isTrue);
      expect(b.matchesEntry(null, kBenchName), isTrue);
      expect(b.matchesEntry(kSquat, kBenchName), isFalse,
          reason: 'an id is never overridden by a name');
    });

    test('same-day rows under two alias ids: one winning day, every set counts',
        () {
      final ExerciseHistoryOption b = deriveExerciseHistoryOptions(
              docs: benchHistory(), catalogNameById: catalogNames())
          .firstWhere((ExerciseHistoryOption o) => o.id == kBench);
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry(kOldBench, kBenchName, <Map<String, dynamic>>[set5(80)]),
          entry(kBench, kBenchName, <Map<String, dynamic>>[set5(110)]),
        ]),
        day(1, <Map<String, dynamic>>[
          entry(kBench, kBenchName, <Map<String, dynamic>>[set5(60)]),
        ], docId: 'second-workout-same-day'),
      ];
      final List<Workout> workouts = deriveWorkoutsForExercise(
        docs: docs,
        targetId: b.id,
        targetName: b.name,
        targetLegacyNames: b.legacyNames,
        targetMemberIds: b.memberIds,
      );
      expect(workouts, hasLength(1), reason: 'one winning workout per day');
      expect(matchingSetsOf(workouts.single).map((SetDetails s) => s.weight),
          <double>[80, 110],
          reason: 'the second matching entry is not dropped');
    });

    testWidgets(
        'the screen shows ONE Bench choice and E1RM, rep target and Top Sets '
        'cover all of its history', (WidgetTester tester) async {
      await savePick(<String, Object?>{'id': kBench, 'name': kBenchName});
      await pumpAnalytics(tester, history: benchHistory());
      expect(tester.takeException(), isNull);
      expect(pickerLabels(tester), <String>[kSquatName, kBenchName]..sort());
      expect(pickerValue(tester)?.id, kBench);
      expect(e1rmChartSpotCounts(tester), <int>[4, 4]);
      for (final int n in <int>[1, 3, 5, 7]) {
        expect(find.text(dateLabel(n)), findsOneWidget,
            reason: 'Top Sets row for day -$n');
      }
    });
  });

  group('stale saved selections heal to the canonical choice', () {
    testWidgets('a name-only {id: null, name: Bench} pick',
        (WidgetTester tester) async {
      await savePick(<String, Object?>{'id': null, 'name': kBenchName});
      await pumpAnalytics(tester, history: benchHistory());
      expect(tester.takeException(), isNull);
      expect(pickerValue(tester)?.id, kBench);
      expect(pickerValue(tester)?.label, kBenchName);
      expect(pickerLabels(tester).where((String l) => l.startsWith('Bench')),
          <String>[kBenchName],
          reason: 'the stale pick is not added back as an extra row');
      expect(e1rmChartSpotCounts(tester), <int>[4, 4]);
      expect(await savedPick(),
          <String, dynamic>{'id': kBench, 'name': kBenchName},
          reason: 'the healed pick is saved for the next visit');
    });

    testWidgets('an obsolete-id pick', (WidgetTester tester) async {
      await savePick(<String, Object?>{'id': kOldBench, 'name': kBenchName});
      await pumpAnalytics(tester, history: benchHistory());
      expect(tester.takeException(), isNull);
      expect(pickerValue(tester)?.id, kBench);
      expect(pickerLabels(tester).where((String l) => l.startsWith('Bench')),
          <String>[kBenchName]);
      expect(await savedPick(),
          <String, dynamic>{'id': kBench, 'name': kBenchName});
    });

    testWidgets('heals when the catalogue arrives after the history',
        (WidgetTester tester) async {
      await savePick(<String, Object?>{'id': kOldBench, 'name': kBenchName});
      final Completer<List<CatalogExercise>> late =
          Completer<List<CatalogExercise>>();
      await pumpAnalytics(tester,
          history: benchHistory(), catalog: (String uid) => late.future);
      // Without the catalogue there is no evidence to merge the obsolete id.
      expect(pickerValue(tester)?.id, kOldBench);
      late.complete(catalogue());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(pickerValue(tester)?.id, kBench);
      expect(pickerLabels(tester).where((String l) => l.startsWith('Bench')),
          <String>[kBenchName]);
      expect(e1rmChartSpotCounts(tester), <int>[4, 4]);
      expect(await savedPick(),
          <String, dynamic>{'id': kBench, 'name': kBenchName});
    });

    testWidgets('a BB3/WES2 preselection heals but never writes the saved pick',
        (WidgetTester tester) async {
      await pumpAnalytics(tester,
          history: benchHistory(),
          exerciseId: kBench.toLowerCase(),
          exerciseName: kBenchName);
      expect(pickerValue(tester)?.id, kBench);
      expect(await savedPick(), isNull);
    });
  });

  testWidgets('switching E1RM <-> Velocity keeps the same canonical choice',
      (WidgetTester tester) async {
    await savePick(<String, Object?>{'id': null, 'name': kBenchName});
    await pumpAnalytics(tester, history: benchHistory());
    final List<String> before = pickerLabels(tester);
    await tester.tap(find.text('Velocity'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(pickerValue(tester)?.id, kBench);
    expect(pickerLabels(tester), before);
    await tester.tap(find.text('E1RM'));
    await tester.pumpAndSettle();
    expect(pickerValue(tester)?.id, kBench);
    expect(pickerLabels(tester), before);
    expect(e1rmChartSpotCounts(tester), <int>[4, 4]);
  });

  group('never merged on a name alone', () {
    test('two live catalogue exercises with the same label stay separate', () {
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry('rowA', 'Seated Row', <Map<String, dynamic>>[set5(60)]),
          entry('rowB', 'Seated Row', <Map<String, dynamic>>[set5(40)]),
          entry('Seated Row', 'Seated Row', <Map<String, dynamic>>[set5(50)]),
        ]),
      ];
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
          docs: docs,
          catalogNameById: <String, String>{
            'rowA': 'Seated Row',
            'rowB': 'Seated Row'
          });
      final Iterable<String?> ids = options.map((ExerciseHistoryOption o) => o.id);
      expect(ids, containsAll(<String>['rowA', 'rowB', 'Seated Row']),
          reason: 'ambiguous: the name-form id joins neither');
      for (final ExerciseHistoryOption o in options) {
        expect(o.memberIds, <String>{o.id!.toLowerCase()});
      }
    });

    test('a same-named custom exercise blocks absorption into the global one',
        () {
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry(kBench, kBenchName, <Map<String, dynamic>>[set5(100)]),
          entry('myBench', kBenchName, <Map<String, dynamic>>[set5(70)]),
          entry(kOldBench, kBenchName, <Map<String, dynamic>>[set5(90)]),
        ]),
      ];
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
        docs: docs,
        catalogNameById: <String, String>{kBench: kBenchName, 'myBench': kBenchName},
        customIds: <String>{'mybench'},
      );
      expect(options, hasLength(3));
      expect(
          options
              .firstWhere((ExerciseHistoryOption o) => o.id == kBench)
              .memberIds,
          <String>{kBench.toLowerCase()});
    });

    test('an uncatalogued auto-id is never absorbed by its name', () {
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry(kBench, kBenchName, <Map<String, dynamic>>[set5(100)]),
          entry('deletedCustomId123', kBenchName, <Map<String, dynamic>>[set5(70)]),
        ]),
      ];
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
          docs: docs, catalogNameById: <String, String>{kBench: kBenchName});
      expect(options, hasLength(2));
    });
  });
}
