// Aurelian voice commands on the real Analytics screen (ExerciseDetailsScreen)
// for the SELECTED athlete, and the bridge scope's readiness rule.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/analytics_history_loader.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';
import 'package:localtest222/exercise_details_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kCoach = 'coachUid';
const String kAthlete = 'athleteUid';

RawWorkoutDoc day(int daysAgo, String id, String name, double weight, double velocity) => RawWorkoutDoc(
      id: 'd$daysAgo$id',
      date: DateTime.now().subtract(Duration(days: daysAgo)),
      exercises: <Map<String, dynamic>>[
        <String, dynamic>{
          'exerciseId': id,
          'name': name,
          'sets': <Map<String, dynamic>>[
            <String, dynamic>{'weight': weight, 'reps': 5, 'rir': 2.0, 'velocity': velocity},
          ],
        },
      ],
    );

List<RawWorkoutDoc> athleteHistory() => <RawWorkoutDoc>[
      day(2, 'AmfUWbF1DH3I7qPAdh5k', 'Bench Press, Barbell', 100, 0.4),
      day(4, 'heeBViVINHO6tUScSd6y', 'Back Squat, Barbell', 140, 0.5),
      day(6, 'row_a', 'Seated Cable Row', 60, 0.6),
      day(8, 'row_b', 'Cable Row, Seated', 55, 0.6),
    ];

Future<List<String>> pumpAnalytics(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final List<String> fetchedFor = <String>[];
  final UserContext uc = UserContext(actorUid: kCoach, isCoach: true)..actingAsUid = kAthlete;
  await tester.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child: ExerciseDetailsScreen(
        historyFetcherForUid: (String uid) {
          fetchedFor.add(uid);
          return ({required DateTime since}) async =>
              RawFetchResult.ok(uid == kAthlete ? athleteHistory() : const <RawWorkoutDoc>[]);
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return fetchedFor;
}

Future<AurelianResult> say(WidgetTester tester, AurelianCommand command) async {
  AurelianResult? result;
  unawaited(AurelianCommandBus.instance.dispatch(command).then((AurelianResult r) => result = r));
  for (int i = 0; i < 50 && result == null; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
  return result!;
}

String? selectedLabel(WidgetTester tester) => tester
    .widget<DropdownButton<ExerciseHistoryOption>>(find.byType(DropdownButton<ExerciseHistoryOption>))
    .value
    ?.label;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AurelianCommandBus.instance.debugReset();
  });
  tearDown(AurelianCommandBus.instance.debugReset);

  testWidgets('select picks the exercise through the dropdown\'s own path, for the selected athlete',
      (WidgetTester tester) async {
    final List<String> fetchedFor = await pumpAnalytics(tester);
    expect(fetchedFor, <String>[kAthlete], reason: "the selected athlete's history, never the coach's");

    final AurelianResult r = await say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'bench press barbell'));
    expect(r.message, 'Analytics: Bench Press, Barbell');
    expect(selectedLabel(tester), 'Bench Press, Barbell');
    // An explicit pick is remembered for this athlete, as a dropdown pick is.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((String k) => prefs.get(k).toString().contains('AmfUWbF1DH3I7qPAdh5k')), isTrue);

    final AurelianResult squat = await say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'Back Squat, Barbell'));
    expect(squat.isOk, isTrue);
    expect(selectedLabel(tester), 'Back Squat, Barbell');
  });

  testWidgets('ambiguous and unknown names are reported, never guessed', (WidgetTester tester) async {
    await pumpAnalytics(tester);
    final AurelianResult which = await say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'row cable seated'));
    expect(which.status, AurelianStatus.ambiguous);
    expect(which.candidates, unorderedEquals(<String>['Seated Cable Row', 'Cable Row, Seated']));
    expect(which.context, 'analytics');
    final AurelianResult chosen = await say(tester,
        const AurelianCommand(AurelianCommandKind.selectExercise, name: 'row cable seated', choice: 'Cable Row, Seated'));
    expect(chosen.isOk, isTrue);
    expect(selectedLabel(tester), 'Cable Row, Seated');
    final AurelianResult none = await say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'deadlift'));
    expect(none.status, AurelianStatus.notFound);
  });

  testWidgets('show E1RM / show velocity switch the main-chart metric', (WidgetTester tester) async {
    await pumpAnalytics(tester);
    await say(tester, const AurelianCommand(AurelianCommandKind.selectExercise, name: 'bench press barbell'));
    final AurelianResult v = await say(tester, const AurelianCommand(AurelianCommandKind.analyticsMetric, metric: AurelianMetric.velocity));
    expect(v.message, 'Showing the velocity trend');
    expect(find.textContaining('E1RM Trend'), findsNothing);
    final AurelianResult e = await say(tester, const AurelianCommand(AurelianCommandKind.analyticsMetric, metric: AurelianMetric.e1rm));
    expect(e.message, 'Showing the E1RM trend');
    expect(find.textContaining('E1RM Trend'), findsWidgets);
  });

  testWidgets('"open analytics" while Analytics is open just says so', (WidgetTester tester) async {
    await pumpAnalytics(tester);
    final AurelianResult r = await say(tester, const AurelianCommand(AurelianCommandKind.openAnalytics));
    expect(r.message, 'Analytics is open');
  });

  testWidgets('a screen alone never makes the bridge ready: only the gated root scope does', (WidgetTester tester) async {
    await pumpAnalytics(tester);
    expect(AurelianCommandBus.instance.hasScope(AurelianScopeKind.analytics), isTrue);
    expect(AurelianCommandBus.instance.ready, isFalse,
        reason: 'without AurelianBridgeScope (inside MembershipGate) native keeps commands queued');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(AurelianCommandBus.instance.hasScope(AurelianScopeKind.analytics), isFalse, reason: 'unregistered on dispose');
  });
}
