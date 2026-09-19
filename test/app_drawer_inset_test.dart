// The home hamburger menu must end ABOVE the phone's own controls.
//
// The drawer is a ListView, so it already scrolled — but its padding was
// `EdgeInsets.zero`, which discards the system inset a ListView would
// otherwise honour. On Android that left Logout underneath the navigation bar
// or gesture area, even at the very end of the scroll: half hidden, and one
// system-gesture away from being hit by accident.
//
// These lay the shipped drawer out under a real Scaffold with the insets and
// sizes a phone actually has, scroll it to the very end, and check where
// Logout comes to rest. Nothing is tapped — Logout signs out — hit-testability
// is checked instead.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/app_drawer.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

const String kSuperAdmin = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';

/// Every item, in the order the drawer has always shown them.
const List<String> kAthleteItems = <String>[
  'Planned Blocks',
  'Block Planner',
  'BB3 Week Planner',
  'Training Preferences',
  'Workout Planner',
  'Exercises',
  'Weigh In',
  'Saved Workouts',
  'Coaching',
  'Coach Mode',
  'Settings',
  'Logout',
];

Future<void> openDrawer(
  WidgetTester tester, {
  Size size = const Size(412, 915),
  double bottomInset = 0,
  double topInset = 24,
  double textScale = 1.0,
  String actorUid = 'athlete-uid',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final GlobalKey<ScaffoldState> scaffold = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
    value: UserContext(actorUid: actorUid, isCoach: false),
    child: MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
          viewPadding: EdgeInsets.only(top: topInset, bottom: bottomInset),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        key: scaffold,
        drawer: const AppDrawer(debugUserEmail: 'athlete@example.test'),
        body: const SizedBox.expand(),
      ),
    ),
  ));
  scaffold.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

Finder drawerScrollable() => find
    .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
    .first;

/// Scrolls the drawer to its very end and returns where Logout rests.
Future<Rect> logoutAtEnd(WidgetTester tester) async {
  final ScrollableState s = tester.state<ScrollableState>(drawerScrollable());
  s.position.jumpTo(s.position.maxScrollExtent);
  await tester.pumpAndSettle();
  return tester.getRect(find.widgetWithText(ListTile, 'Logout'));
}

List<String> itemTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(ListTile),
    ))
    .map((ListTile t) => (t.title! as Text).data!)
    .toList(growable: false);

void main() {
  group('Logout clears the phone\'s own controls', () {
    for (final double inset in <double>[48, 24, 34]) {
      testWidgets('with a ${inset.toInt()}px bottom system inset',
          (WidgetTester tester) async {
        const Size size = Size(412, 915);
        await openDrawer(tester, size: size, bottomInset: inset);
        final Rect logout = await logoutAtEnd(tester);

        expect(logout.bottom, lessThanOrEqualTo(size.height - inset),
            reason: 'Logout must end above the navigation bar / gesture area');
        // Polished, not padded out: the gap above the inset is a margin.
        expect(size.height - inset - logout.bottom, lessThanOrEqualTo(40));
        expect(find.text('Logout').hitTestable(), findsOneWidget);

        // A touch inside the inset area cannot land on Logout.
        final Offset inInset = Offset(logout.center.dx, size.height - inset / 2);
        expect(logout.contains(inInset), isFalse);
      });
    }

    testWidgets('with no inset, the end of the menu is unchanged in spirit',
        (WidgetTester tester) async {
      const Size size = Size(412, 915);
      await openDrawer(tester, size: size);
      final Rect logout = await logoutAtEnd(tester);
      expect(logout.bottom, lessThanOrEqualTo(size.height));
      expect(find.text('Logout').hitTestable(), findsOneWidget);
    });
  });

  group('every item is reachable, however little room there is', () {
    /// Scrolls just far enough that [title] rests entirely above the inset,
    /// and checks it can be seen and hit there. While scrolling, an item may
    /// pass behind a translucent navigation bar — that is ordinary scrolling;
    /// what matters is that it can be brought fully clear of it.
    Future<void> expectAllReachable(WidgetTester tester, double inset,
        Size size) async {
      final ScrollableState s = tester.state<ScrollableState>(drawerScrollable());
      expect(s.position.maxScrollExtent, greaterThan(0),
          reason: 'the menu must scroll when it does not fit');
      final double limit = size.height - inset;
      const double statusBar = 24;
      for (final String title in kAthleteItems) {
        final Finder tile = find.widgetWithText(ListTile, title);
        // Make sure the tile is built (a ListView lays out lazily)...
        await tester.scrollUntilVisible(tile, 120, scrollable: drawerScrollable());
        // ...then rest it just below the status bar, as far as the list can
        // scroll. The offset comes from the viewport's own geometry (the
        // scroll offset that puts the tile's top at the viewport's top), not
        // from screen coordinates. Near the end the list stops short of that,
        // and the bottom padding is what keeps those last items clear.
        final RenderObject ro = tester.renderObject(tile);
        final double reveal =
            RenderAbstractViewport.of(ro).getOffsetToReveal(ro, 0.0).offset;
        s.position.jumpTo(
            (reveal - statusBar).clamp(0.0, s.position.maxScrollExtent));
        await tester.pumpAndSettle();
        final Rect r = tester.getRect(tile);
        expect(r.bottom, lessThanOrEqualTo(limit), reason: '$title clears the inset');
        expect(r.top, greaterThanOrEqualTo(0), reason: '$title is not cut off at the top');
        expect(find.text(title).hitTestable(), findsOneWidget, reason: title);
      }
      final Rect logout = await logoutAtEnd(tester);
      expect(logout.bottom, lessThanOrEqualTo(limit));
    }

    testWidgets('a short phone', (WidgetTester tester) async {
      const Size size = Size(360, 560);
      await openDrawer(tester, size: size, bottomInset: 48);
      await expectAllReachable(tester, 48, size);
    });

    testWidgets('landscape', (WidgetTester tester) async {
      const Size size = Size(915, 412);
      await openDrawer(tester, size: size, bottomInset: 24);
      await expectAllReachable(tester, 24, size);
    });

    testWidgets('large text', (WidgetTester tester) async {
      const Size size = Size(412, 915);
      await openDrawer(tester, size: size, bottomInset: 48, textScale: 2.0);
      await expectAllReachable(tester, 48, size);
    });
  });

  group('the menu itself is unchanged', () {
    testWidgets('same items, same order, same groups, for an athlete',
        (WidgetTester tester) async {
      await openDrawer(tester, size: const Size(412, 3000));
      expect(itemTitles(tester), kAthleteItems);
      for (final String header in <String>['PLANNING', 'COACHING', 'UTILITIES']) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      expect(find.text('Coach Management'), findsNothing);
      expect(find.text('athlete@example.test'), findsOneWidget);
    });

    testWidgets('the super admin still gets Coach Management, in its place',
        (WidgetTester tester) async {
      await openDrawer(tester, size: const Size(412, 3000), actorUid: kSuperAdmin);
      final List<String> expected = List<String>.of(kAthleteItems)
        ..insert(kAthleteItems.indexOf('Settings'), 'Coach Management');
      expect(itemTitles(tester), expected);
    });
  });
}
