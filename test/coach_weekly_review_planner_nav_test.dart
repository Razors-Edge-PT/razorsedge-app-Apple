import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_weekly_review_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

/// Tests the REAL [openAthleteWeekPlanner] used by every Weekly Review card.
///
/// It must reuse the EXISTING Coach Mode mechanism — set
/// [UserContext.actingAsUid] to the card's athlete via `switchAthlete`, then
/// push the one BB3WeekPlanner screen — rather than inventing a second
/// planner. The push itself is injected here so the Firebase-backed planner
/// screen does not have to be mounted.

const _coachUid = 'coach_signed_in_uid';
const _athleteUid = 'athlete_on_the_card_uid';

/// Records `switchAthlete` and applies just its identity effect.
///
/// The production implementation additionally kicks off cached-block-meta
/// hydration and a Firestore-backed background refresh (with its own retry
/// timers) — none of which is what this file is testing, and none of which can
/// run in a widget test. What matters here is WHICH uid the Weekly Review hands
/// to Coach Mode, and that the planner is pushed with that same context.
class _SpyUserContext extends UserContext {
  _SpyUserContext() : super(actorUid: _coachUid, isCoach: true);

  final List<String> switched = [];

  @override
  void switchAthlete(String newUid) {
    if (newUid == actingAsUid) return;
    switched.add(newUid);
    actingAsUid = newUid;
    notifyListeners();
  }
}

void main() {
  Future<_SpyUserContext> pumpTrigger(
    WidgetTester tester, {
    required String athleteUid,
    required List<UserContext> pushedWith,
    bool provideContext = true,
  }) async {
    final userContext = _SpyUserContext();
    Widget trigger = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => openAthleteWeekPlanner(
              context,
              athleteUid: athleteUid,
              athleteName: 'Ann Athlete',
              pushPlanner: (ctx, uc) async => pushedWith.add(uc),
            ),
            child: const Text('Planner'),
          ),
        ),
      ),
    );
    if (provideContext) {
      trigger = ChangeNotifierProvider<UserContext>.value(
        value: userContext,
        child: trigger,
      );
    }
    await tester.pumpWidget(MaterialApp(home: trigger));
    return userContext;
  }

  testWidgets('switches to the CARD athlete, never the signed-in coach',
      (tester) async {
    final pushedWith = <UserContext>[];
    final userContext = await pumpTrigger(tester,
        athleteUid: _athleteUid, pushedWith: pushedWith);

    expect(userContext.actingAsUid, _coachUid); // coach is acting as self
    expect(userContext.isActingAsSelf, isTrue);

    await tester.tap(find.text('Planner'));
    await tester.pump();

    expect(userContext.switched, [_athleteUid]);
    expect(userContext.actingAsUid, _athleteUid);
    expect(userContext.actingAsUid, isNot(_coachUid));
    // The signed-in identity is untouched — this is a view switch, not a
    // change of who the coach is.
    expect(userContext.actorUid, _coachUid);
  });

  testWidgets('pushes the planner with that same UserContext', (tester) async {
    final pushedWith = <UserContext>[];
    final userContext = await pumpTrigger(tester,
        athleteUid: _athleteUid, pushedWith: pushedWith);

    await tester.tap(find.text('Planner'));
    await tester.pump();

    // One planner opened, driven by the context now acting as the athlete —
    // this is what BB3WeekPlanner reads for its uid and its current week.
    expect(pushedWith, hasLength(1));
    expect(identical(pushedWith.single, userContext), isTrue);
    expect(pushedWith.single.actingAsUid, _athleteUid);
  });

  testWidgets('an empty athlete uid is reported, not crashed', (tester) async {
    final pushedWith = <UserContext>[];
    final userContext =
        await pumpTrigger(tester, athleteUid: '  ', pushedWith: pushedWith);

    await tester.tap(find.text('Planner'));
    await tester.pump();

    expect(pushedWith, isEmpty);
    expect(userContext.switched, isEmpty);
    expect(userContext.actingAsUid, _coachUid); // nothing was changed
    expect(
      find.textContaining('Can\'t open the week planner for Ann Athlete'),
      findsOneWidget,
    );
  });

  testWidgets('a missing UserContext is reported, not crashed', (tester) async {
    final pushedWith = <UserContext>[];
    await pumpTrigger(tester,
        athleteUid: _athleteUid,
        pushedWith: pushedWith,
        provideContext: false);

    await tester.tap(find.text('Planner'));
    await tester.pump();

    expect(pushedWith, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('training context isn\'t available'),
      findsOneWidget,
    );
  });

  testWidgets('returning from the planner leaves the caller untouched',
      (tester) async {
    // The Weekly Review must not be rebuilt from scratch when the planner
    // pops: openAthleteWeekPlanner awaits the push and does nothing after it.
    final pushedWith = <UserContext>[];
    var callerBuilds = 0;
    final userContext = _SpyUserContext();

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<UserContext>.value(
        value: userContext,
        child: Builder(builder: (context) {
          callerBuilds++;
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => openAthleteWeekPlanner(
                  context,
                  athleteUid: _athleteUid,
                  pushPlanner: (ctx, uc) async {
                    pushedWith.add(uc);
                    // Simulate the planner opening and the coach pressing Back.
                    await Future<void>.microtask(() {});
                  },
                ),
                child: const Text('Planner'),
              ),
            ),
          );
        }),
      ),
    ));
    final buildsBefore = callerBuilds;

    await tester.tap(find.text('Planner'));
    await tester.pump();
    await tester.pump();

    expect(pushedWith, hasLength(1));
    // switchAthlete notifies listeners, but this caller does not listen, so
    // returning triggers no reload of the screen that pushed the planner.
    expect(callerBuilds, buildsBefore);
    expect(find.text('Planner'), findsOneWidget);
  });
}
