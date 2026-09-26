import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/Block_Planner.dart';
import 'package:localtest222/app_drawer.dart';
import 'package:localtest222/block_planner_2/bp2_screen.dart';
import 'package:localtest222/planned_blocks_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

import 'bp2_test_support.dart';

/// A recorded planner navigation.
class _Nav {
  final PlannedBlocksDestination destination;
  final String athleteUid;
  final String? blockId;
  _Nav(this.destination, this.athleteUid, this.blockId);
}

void main() {
  const athlete = 'athlete-uid';
  const coach = 'coach-uid';
  const custom = 'Bench Nationals 2026 9 weeks';

  /// Coach signed in, athlete selected.
  UserContext coachViewingAthlete() =>
      UserContext(actorUid: coach, isCoach: true)..actingAsUid = athlete;

  Future<Harness> seeded() async {
    final h = Harness();
    await h.seedUser(athlete, username: 'NZBenchPress');
    await h.seedBlock(athlete, 'bench',
        isActive: true,
        name: custom,
        start: DateTime(2026, 8, 17),
        end: DateTime(2026, 11, 2),
        extra: {'createdAt': Timestamp.fromDate(DateTime(2026, 8, 1))});
    await h.seedBlock(athlete, 'upcoming',
        isActive: false,
        name: 'Upcoming block',
        start: DateTime(2026, 11, 2),
        end: DateTime(2026, 11, 29),
        extra: {'createdAt': Timestamp.fromDate(DateTime(2026, 8, 2))});
    await h.seedBlock(coach, 'coach-own',
        isActive: true,
        name: 'Coach own block',
        extra: {'createdAt': Timestamp.fromDate(DateTime(2026, 8, 3))});
    return h;
  }

  Future<void> pumpList(
    WidgetTester tester,
    Harness h, {
    required PlannedBlocksDestination destination,
    PlannedBlockRouteFactory? routeFactory,
    RouteFactory? onGenerateRoute,
    UserContext? uc,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc ?? coachViewingAthlete(),
      child: MaterialApp(
        onGenerateRoute: onGenerateRoute,
        home: PlannedBlocksScreen(
          destination: destination,
          routeFactory: routeFactory,
          firestore: h.db,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Records the navigation and shows a trivial page with a back button.
  PlannedBlockRouteFactory recorder(List<_Nav> log) => ({
        required PlannedBlocksDestination destination,
        required UserContext userContext,
        required String athleteUid,
        String? blockId,
        String? blockName,
      }) {
        log.add(_Nav(destination, athleteUid, blockId));
        return MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Planner stub')),
          ),
        );
      };

  group('Planned Blocks 2 screen (shared implementation)', () {
    testWidgets('shows the selected athlete\'s blocks under the shared title',
        (tester) async {
      final h = await seeded();
      await pumpList(tester, h,
          destination: PlannedBlocksDestination.blockPlanner2,
          routeFactory: recorder([]));
      expect(find.text('Planned Blocks'), findsOneWidget);
      expect(
          tester
              .widget<PlannedBlocksScreen>(find.byType(PlannedBlocksScreen))
              .destination,
          PlannedBlocksDestination.blockPlanner2);
      expect(find.text(custom), findsOneWidget);
      expect(find.text('Upcoming block'), findsOneWidget);
      expect(find.text('Coach own block'), findsNothing);
      expect(find.text('New Block'), findsOneWidget);
    });

    testWidgets(
        'tapping a block opens Block Planner 2 with that exact block '
        'and the selected athlete uid', (tester) async {
      final h = await seeded();
      final log = <_Nav>[];
      await pumpList(tester, h,
          destination: PlannedBlocksDestination.blockPlanner2,
          routeFactory: recorder(log));
      await tester.tap(find.text('Upcoming block'));
      await tester.pumpAndSettle();
      expect(log.single.destination, PlannedBlocksDestination.blockPlanner2);
      expect(log.single.blockId, 'upcoming', reason: 'not the active block');
      expect(log.single.athleteUid, athlete, reason: 'not the coach uid');
    });

    testWidgets('New Block creates through Block Planner 2 without a block id',
        (tester) async {
      final h = await seeded();
      final log = <_Nav>[];
      await pumpList(tester, h,
          destination: PlannedBlocksDestination.blockPlanner2,
          routeFactory: recorder(log));
      await tester.tap(find.text('New Block'));
      await tester.pumpAndSettle();
      expect(log.single.destination, PlannedBlocksDestination.blockPlanner2);
      expect(log.single.blockId, isNull);
      expect(log.single.athleteUid, athlete);
    });

    testWidgets('end to end: open block in BP2, rename, back → list refreshed',
        (tester) async {
      final h = await seeded();
      Route<void> bp2Route({
        required PlannedBlocksDestination destination,
        required UserContext userContext,
        required String athleteUid,
        String? blockId,
        String? blockName,
      }) =>
          Bp2Screen.route(
            userContext: userContext,
            args: Bp2RouteArgs(athleteUid: athleteUid, blockId: blockId),
            controller: h.controller,
          );
      await pumpList(tester, h,
          destination: PlannedBlocksDestination.blockPlanner2,
          routeFactory: bp2Route);

      await tester.tap(find.text(custom));
      await tester.pumpAndSettle();
      expect(find.text('Block Planner 2'), findsOneWidget);
      expect(h.controller.uid, athlete);
      expect(h.controller.block!.id, 'bench');
      expect(find.widgetWithText(TextField, custom), findsOneWidget);
      expect(find.text('17 Aug 2026 – 1 Nov 2026'), findsOneWidget);
      expect(find.text('11 weeks'), findsOneWidget);
      expect(find.text('26 weeks'), findsNothing);

      await tester.enterText(
          find.byKey(const ValueKey('bp2-name')), 'Bench Nationals 2026');
      await tester.pump();
      await tester.tap(find.byType(BackButton)); // exit autosave
      await tester.pumpAndSettle();

      expect(find.text('Planned Blocks'), findsOneWidget);
      expect(find.text('Bench Nationals 2026'), findsOneWidget,
          reason: 'card shows the saved name on return');
      expect(find.text(custom), findsNothing);
      final doc = (await h.block(athlete, 'bench'))!;
      expect(doc['name'], 'Bench Nationals 2026');
      expect((doc['endDate'] as Timestamp).toDate(), DateTime(2026, 11, 2),
          reason: 'stored dates untouched by a rename');
    });
  });

  group('original Planned Blocks behaviour is preserved', () {
    testWidgets('title, and block taps go to the original planner',
        (tester) async {
      final h = await seeded();
      final log = <_Nav>[];
      await pumpList(tester, h,
          destination: PlannedBlocksDestination.blockPlanner,
          routeFactory: recorder(log));
      expect(find.text('Planned Blocks'), findsOneWidget);
      expect(
          tester
              .widget<PlannedBlocksScreen>(find.byType(PlannedBlocksScreen))
              .destination,
          PlannedBlocksDestination.blockPlanner);
      await tester.tap(find.text(custom));
      await tester.pumpAndSettle();
      expect(log.single.destination, PlannedBlocksDestination.blockPlanner);
      expect(log.single.blockId, 'bench');
    });

    testWidgets(
        'default constructor is the original mode; New Block still '
        'pushes the /block_builder route', (tester) async {
      final h = await seeded();
      final pushed = <RouteSettings>[];
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
        value: coachViewingAthlete(),
        child: MaterialApp(
          onGenerateRoute: (settings) {
            pushed.add(settings);
            return MaterialPageRoute<void>(
                settings: settings, builder: (_) => const Scaffold());
          },
          home: PlannedBlocksScreen(firestore: h.db),
        ),
      ));
      await tester.pumpAndSettle();
      expect(const PlannedBlocksScreen().destination,
          PlannedBlocksDestination.blockPlanner);
      await tester.tap(find.text('New Block'));
      await tester.pumpAndSettle();
      expect(pushed.single.name, '/block_builder');
      expect(pushed.single.arguments, {'newBlock': true});
    });

    test(
        'default routes: original → Block_Planner with the legacy map '
        'arguments; Block Planner 2 → typed args', () {
      final uc = coachViewingAthlete();
      final original = defaultPlannedBlockRoute(
        destination: PlannedBlocksDestination.blockPlanner,
        userContext: uc,
        athleteUid: athlete,
        blockId: 'bench',
        blockName: custom,
      ) as MaterialPageRoute<void>;
      expect(original.settings.name, isNull);
      expect(original.settings.arguments,
          {'blockId': 'bench', 'blockName': custom});
      expect(
          plannerScreenFor(PlannedBlocksDestination.blockPlanner,
              athleteUid: athlete, blockId: 'bench'),
          isA<Block_Planner>());

      final bp2 = defaultPlannedBlockRoute(
        destination: PlannedBlocksDestination.blockPlanner2,
        userContext: uc,
        athleteUid: athlete,
        blockId: 'upcoming',
      ) as MaterialPageRoute<void>;
      expect(bp2.settings.name, Bp2Screen.routeName);
      expect(bp2.settings.arguments,
          const Bp2RouteArgs(athleteUid: athlete, blockId: 'upcoming'));
      final screen = plannerScreenFor(PlannedBlocksDestination.blockPlanner2,
          athleteUid: athlete, blockId: 'upcoming') as Bp2Screen;
      expect(screen.blockId, 'upcoming');
      expect(screen.athleteUid, athlete);
    });
  });

  group('Home Quick Access entry point', () {
    // HomeScreen2 needs live Firebase to mount, so the card row itself is
    // asserted at source level; the behaviour behind the card is a real
    // widget test below.
    String quickAccessSource() {
      final src = File('lib/home_screen_2.dart').readAsStringSync();
      final start = src.indexOf('\u2500\u2500 Quick Access');
      return src.substring(start, src.indexOf('\u2500\u2500 Calendar', start));
    }

    test(
        'exactly one planner entry, labelled Block Planner 2, with Settings '
        'next and no blank card left behind', () {
      final qa = quickAccessSource();
      final labels = RegExp(r"label: '([^']*)'")
          .allMatches(qa)
          .map((m) => m.group(1)!.replaceAll(r'\n', ' '))
          .toList();

      // One planner entry, named exactly "Block Planner 2".
      final planner =
          labels.where((l) => l.contains('Planner 2') || l.contains('Planned'));
      expect(planner, ['Block Planner 2']);
      expect(labels.where((l) => l == 'Planned Blocks'), isEmpty);
      expect(labels.where((l) => l == 'Planned Blocks 2'), isEmpty);

      // Settings follows it; Week Planner keeps the slot under the planner.
      final i = labels.indexOf('Block Planner 2');
      expect(labels[i + 1], 'Week Planner');
      expect(labels[i + 2], 'Settings');

      // No empty card position was introduced. The only blank slot is the
      // pre-existing one that pads the final column, after Settings.
      final blanks =
          RegExp(r'SizedBox\(\s*width: kFeatureCardWidth,\s*'
                  r'height: HomeScreen2\.kQuickAccessCardHeight\)')
              .allMatches(qa)
              .toList();
      expect(blanks.length, 1, reason: 'no new blank card position');
      expect(blanks.single.start, greaterThan(qa.indexOf("label: 'Settings'")));

      // The card opens block selection, never an editor draft directly.
      expect(qa, contains('PlannedBlocksDestination.blockPlanner2'));
      expect(qa.contains('Bp2Screen'), isFalse);
      expect(qa.contains('PlannedBlocksScreen('), isFalse);
    });

    testWidgets(
        'the entry opens the block-selection screen in Block Planner 2 '
        'mode, not an editor draft', (tester) async {
      final h = await seeded();
      final uc = coachViewingAthlete();
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // The exact call the Quick Access card makes.
      await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
        value: uc,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openPlannedBlocks(
                    context, PlannedBlocksDestination.blockPlanner2,
                    firestore: h.db),
                child: const Text('Block Planner 2'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Block Planner 2'));
      await tester.pumpAndSettle();

      final screen =
          tester.widget<PlannedBlocksScreen>(find.byType(PlannedBlocksScreen));
      expect(screen.destination, PlannedBlocksDestination.blockPlanner2);
      expect(find.byType(Bp2Screen), findsNothing,
          reason: 'selection first, never straight into the editor');
      expect(find.text('Planned Blocks'), findsOneWidget,
          reason: 'the selector keeps its normal page title');
    });

    testWidgets(
        'drawer keeps the original Block Planner entry and no longer '
        'has a direct Block Planner 2 entry', (tester) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final scaffold = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
        value: UserContext(actorUid: athlete, isCoach: false),
        child: MaterialApp(
          home: Scaffold(
            key: scaffold,
            drawer: const AppDrawer(debugUserEmail: 'athlete@example.test'),
            body: const SizedBox.expand(),
          ),
        ),
      ));
      scaffold.currentState!.openDrawer();
      await tester.pumpAndSettle();
      final tile = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Block Planner'));
      expect((tile.leading as Icon).icon, Icons.extension);
      expect(find.text('Block Planner 2'), findsNothing);
    });
  });
}
