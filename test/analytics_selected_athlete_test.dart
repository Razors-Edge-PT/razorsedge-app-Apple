// Analytics for the SELECTED athlete (coach / admin acting as an athlete), and
// the exercise picker's identity rules: one choice per actual exercise.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/analytics_history_loader.dart';
import 'package:localtest222/exercise_details_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kCoach = 'coachUid';
const String kAthlete = 'athleteUid';
const String kOther = 'otherAthleteUid';
const String kLat = '1XOIXxeLFhgmgjZS9Cyq';
const String kSquat = 'heeBViVINHO6tUScSd6y';

Map<String, dynamic> entry(
        Object? id, String name, List<Map<String, dynamic>> sets,
        {String idField = 'exerciseId'}) =>
    <String, dynamic>{if (id != null) idField: id, 'name': name, 'sets': sets};

Map<String, dynamic> vset(num weight, int reps, double velocity) =>
    <String, dynamic>{'weight': weight, 'reps': reps, 'velocity': velocity};

RawWorkoutDoc day(int daysAgo, List<Map<String, dynamic>> exercises) =>
    RawWorkoutDoc(
      id: 'd$daysAgo',
      date: DateTime.now().subtract(Duration(days: daysAgo)),
      exercises: exercises,
    );

/// Mixed legacy/current records of ONE exercise (current id, the same id
/// lower-cased as stored by an older client, and legacy entries with no id).
List<RawWorkoutDoc> latHistory() => <RawWorkoutDoc>[
      day(3, <Map<String, dynamic>>[
        entry(kLat, 'Lat Pull Down, Supinated',
            <Map<String, dynamic>>[vset(100, 5, 0.50)]),
      ]),
      day(5, <Map<String, dynamic>>[
        entry(kLat.toLowerCase(), 'Lat Pull Down, Supinated',
            <Map<String, dynamic>>[vset(90, 5, 0.55)]),
      ]),
      day(7, <Map<String, dynamic>>[
        entry(null, 'Lat Pull Down, Supinated',
            <Map<String, dynamic>>[vset(80, 5, 0.60)]),
        entry(kLat, 'Lat Pull Down, Supinated',
            <Map<String, dynamic>>[vset(85, 5, 0.58)],
            idField: 'id'),
      ]),
    ];

List<RawWorkoutDoc> squatHistory() => <RawWorkoutDoc>[
      day(2, <Map<String, dynamic>>[
        entry(kSquat, 'Back Squat, Barbell',
            <Map<String, dynamic>>[vset(140, 3, 0.4)]),
      ]),
    ];

class AnalyticsProbe {
  final List<String> fetchedFor = <String>[];
}

Future<AnalyticsProbe> pumpAnalytics(
  WidgetTester tester,
  UserContext uc, {
  required Map<String, List<RawWorkoutDoc>> historyByUid,
}) async {
  tester.view.physicalSize = const Size(430, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final AnalyticsProbe probe = AnalyticsProbe();
  await tester.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child: ExerciseDetailsScreen(
        historyFetcherForUid: (String uid) {
          probe.fetchedFor.add(uid);
          return ({required DateTime since}) async =>
              RawFetchResult.ok(historyByUid[uid] ?? const <RawWorkoutDoc>[]);
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return probe;
}

Finder get picker => find.byType(DropdownButton<ExerciseHistoryOption>);

Future<List<String>> openPickerLabels(WidgetTester tester) async {
  await tester.tap(picker);
  await tester.pumpAndSettle();
  final List<String> labels = tester
      .widgetList<DropdownMenuItem<ExerciseHistoryOption>>(
          find.byType(DropdownMenuItem<ExerciseHistoryOption>))
      .map((DropdownMenuItem<ExerciseHistoryOption> i) => i.value!.label)
      .toSet()
      .toList();
  return labels;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('selected athlete', () {
    testWidgets(
        'a coach opening Analytics for a selected athlete (no saved pick) renders without error',
        (WidgetTester tester) async {
      final UserContext uc = UserContext(actorUid: kCoach, isCoach: true)
        ..actingAsUid = kAthlete;
      final AnalyticsProbe p = await pumpAnalytics(tester, uc,
          historyByUid: <String, List<RawWorkoutDoc>>{
            kAthlete: latHistory(),
            kCoach: squatHistory(),
          });
      expect(tester.takeException(), isNull,
          reason: 'the build used to throw (sorting a const list)');
      expect(p.fetchedFor, <String>[kAthlete],
          reason:
              "the SELECTED athlete's history, never the signed-in coach's");
      expect(picker, findsOneWidget);
      final List<String> labels = await openPickerLabels(tester);
      expect(labels, contains('Lat Pull Down, Supinated'));
      expect(labels, isNot(contains('Back Squat, Barbell')),
          reason: "never the coach's own data");
    });

    testWidgets('an admin selecting an athlete behaves the same',
        (WidgetTester tester) async {
      final UserContext uc =
          UserContext(actorUid: 'yoVAqScwLMQLAgNHh8v9IK49fBw2', isCoach: true)
            ..actingAsUid = kAthlete;
      final AnalyticsProbe p = await pumpAnalytics(tester, uc,
          historyByUid: <String, List<RawWorkoutDoc>>{kAthlete: latHistory()});
      expect(tester.takeException(), isNull);
      expect(p.fetchedFor, <String>[kAthlete]);
    });

    testWidgets('self view still works (with and without a saved pick)',
        (WidgetTester tester) async {
      final UserContext uc = UserContext(actorUid: kAthlete, isCoach: false);
      await pumpAnalytics(tester, uc,
          historyByUid: <String, List<RawWorkoutDoc>>{kAthlete: latHistory()});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); // close it: a fresh visit
      SharedPreferences.setMockInitialValues(<String, Object>{
        'analytics_last_exercise:$kAthlete': jsonEncode(
            <String, String>{'id': kLat, 'name': 'Lat Pull Down, Supinated'}),
      });
      await pumpAnalytics(
          tester, UserContext(actorUid: kAthlete, isCoach: false),
          historyByUid: <String, List<RawWorkoutDoc>>{kAthlete: latHistory()});
      expect(tester.takeException(), isNull);
      expect(
          tester
              .widget<DropdownButton<ExerciseHistoryOption>>(picker)
              .value
              ?.id,
          kLat);
    });

    testWidgets(
        "switching athletes loads the new athlete's data and never their predecessor's pick",
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'analytics_last_exercise:$kAthlete': jsonEncode(
            <String, String>{'id': kLat, 'name': 'Lat Pull Down, Supinated'}),
      });
      final UserContext uc = UserContext(actorUid: kCoach, isCoach: true)
        ..actingAsUid = kAthlete;
      final AnalyticsProbe p = await pumpAnalytics(tester, uc,
          historyByUid: <String, List<RawWorkoutDoc>>{
            kAthlete: latHistory(),
            kOther: squatHistory(),
          });
      expect(
          tester
              .widget<DropdownButton<ExerciseHistoryOption>>(picker)
              .value
              ?.id,
          kLat);

      uc.switchAthlete(kOther);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(p.fetchedFor, <String>[kAthlete, kOther]);
      expect(tester.widget<DropdownButton<ExerciseHistoryOption>>(picker).value,
          isNull,
          reason: "the previous athlete's saved exercise is not carried over");
      final List<String> labels = await openPickerLabels(tester);
      expect(labels, <String>['Back Squat, Barbell']);
      // And the first athlete's saved pick was not overwritten by the switch.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString('analytics_last_exercise:$kAthlete'), contains(kLat));
      expect(prefs.getString('analytics_last_exercise:$kOther'), isNull);
    });
  });

  group('picker: one choice per actual exercise', () {
    testWidgets(
        'mixed current / lower-cased / legacy records show ONE Lat Pull Down',
        (WidgetTester tester) async {
      final UserContext uc = UserContext(actorUid: kCoach, isCoach: true)
        ..actingAsUid = kAthlete;
      await pumpAnalytics(tester, uc,
          historyByUid: <String, List<RawWorkoutDoc>>{kAthlete: latHistory()});
      final List<String> labels = await openPickerLabels(tester);
      expect(labels.where((String l) => l.startsWith('Lat Pull Down')).toList(),
          <String>['Lat Pull Down, Supinated']);
    });

    test(
        'the merged choice includes every historical velocity set of that exercise',
        () {
      final List<ExerciseHistoryOption> options =
          deriveExerciseHistoryOptions(docs: latHistory());
      expect(options, hasLength(1));
      final ExerciseHistoryOption lat = options.single;
      expect(lat.id, kLat);
      expect(lat.legacyNames, <String>{'Lat Pull Down, Supinated'});
      final List<VelocitySample> samples = deriveVelocitySamplesForExercise(
        docs: latHistory(),
        targetId: lat.id,
        targetName: lat.name,
        targetLegacyNames: lat.legacyNames,
      );
      expect(samples.map((VelocitySample s) => s.weight).toSet(),
          <double>{100, 90, 80, 85},
          reason:
              'current id, lower-cased id, `id` field and legacy name-only sets');
    });

    test(
        'distinct ids that share a name stay distinct, labelled; ambiguous legacy stays separate',
        () {
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry('globalRowId1', 'Seated Row',
              <Map<String, dynamic>>[vset(60, 8, 0.5)]),
          entry('customRowId2', 'Seated Row',
              <Map<String, dynamic>>[vset(40, 8, 0.7)]),
          entry(null, 'Seated Row', <Map<String, dynamic>>[vset(50, 8, 0.6)]),
        ]),
      ];
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
          docs: docs, customIds: <String>{'customrowid2'});
      expect(
          options.map((ExerciseHistoryOption o) => o.label).toList(), <String>[
        'Seated Row (custom)',
        'Seated Row (ID glob)',
        'Seated Row (older entries)'
      ]);
      final ExerciseHistoryOption global = options
          .firstWhere((ExerciseHistoryOption o) => o.id == 'globalRowId1');
      expect(global.legacyNames, isEmpty,
          reason: 'not demonstrably the same exercise');
      final List<VelocitySample> onlyGlobal = deriveVelocitySamplesForExercise(
          docs: docs,
          targetId: global.id,
          targetName: global.name,
          targetLegacyNames: global.legacyNames);
      expect(onlyGlobal.map((VelocitySample s) => s.weight).toList(),
          <double>[60]);
      final ExerciseHistoryOption legacy =
          options.firstWhere((ExerciseHistoryOption o) => o.id == null);
      final List<VelocitySample> onlyLegacy = deriveVelocitySamplesForExercise(
          docs: docs, targetId: legacy.id, targetName: legacy.name);
      expect(onlyLegacy.map((VelocitySample s) => s.weight).toList(),
          <double>[50]);
    });

    test(
        'a renamed exercise keeps its older legacy entries under the current name',
        () {
      final List<RawWorkoutDoc> docs = <RawWorkoutDoc>[
        day(1, <Map<String, dynamic>>[
          entry('pulldownId', 'Lat Pulldown (old)',
              <Map<String, dynamic>>[vset(70, 6, 0.6)])
        ]),
        day(2, <Map<String, dynamic>>[
          entry(null, 'Lat Pulldown (old)',
              <Map<String, dynamic>>[vset(65, 6, 0.62)])
        ]),
      ];
      final List<ExerciseHistoryOption> options = deriveExerciseHistoryOptions(
          docs: docs,
          catalogNameById: <String, String>{
            'pulldownId': 'Lat Pull Down, Wide Arm'
          });
      expect(options.map((ExerciseHistoryOption o) => o.label).toList(),
          <String>['Lat Pull Down, Wide Arm']);
      final ExerciseHistoryOption o = options.single;
      final List<VelocitySample> samples = deriveVelocitySamplesForExercise(
          docs: docs,
          targetId: o.id,
          targetName: o.name,
          targetLegacyNames: o.legacyNames);
      expect(samples.map((VelocitySample s) => s.weight).toSet(),
          <double>{70, 65});
    });

    test(
        'velocity reps / weight grouping still filters within the merged history',
        () {
      final ExerciseHistoryOption lat =
          deriveExerciseHistoryOptions(docs: latHistory()).single;
      final List<VelocitySample> samples = deriveVelocitySamplesForExercise(
          docs: latHistory(),
          targetId: lat.id,
          targetName: lat.name,
          targetLegacyNames: lat.legacyNames);
      final List<VelocitySample> at90x5 = samples
          .where((VelocitySample s) => s.reps == 5 && s.weight == 90)
          .toList();
      expect(at90x5, hasLength(1));
      expect(at90x5.single.velocity, 0.55);
    });
  });
}
