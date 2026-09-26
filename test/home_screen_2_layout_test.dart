// Home (HomeScreen2) layout and calendar gestures.
//
// HomeScreen2 builds its own Firebase-backed controller and app bar, so these
// tests assemble the page's column from the page's OWN contract values
// (HomeScreen2.k…), its real Quick Access card and a plain AppBar of the same
// height (HomeV2AppBar is kToolbarHeight). A source check pins the page to
// those values so the harness cannot drift from it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/home_screen_2.dart';
import 'package:table_calendar/table_calendar.dart';

const Key kFeedKey = ValueKey<String>('feed-start');

class HomeHarness {
  late ScrollController host;
  final List<DateTime> selected = <DateTime>[];
  final List<DateTime> pages = <DateTime>[];
}

Future<HomeHarness> pumpHome(
  WidgetTester tester, {
  Size surface = const Size(393, 852),
  EdgeInsets safeArea = const EdgeInsets.only(top: 47, bottom: 34),
  bool cue = false,
  bool coach = false,
  AvailableGestures gestures = HomeScreen2.kCalendarGestures,
  DateTime? focusedDay,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding =
      FakeViewPadding(top: safeArea.top, bottom: safeArea.bottom);
  addTearDown(tester.view.reset);
  final HomeHarness h = HomeHarness()..host = ScrollController();
  addTearDown(h.host.dispose);

  Widget card(String label) => HomeQuickAccessCard(
        icon: Icons.fitness_center,
        label: label,
        onTap: () {},
      );
  Widget column(String top, String bottom, {bool withCue = false}) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (withCue) ...<Widget>[
            const Text('Tap here first', style: TextStyle(fontSize: 10)),
            const SizedBox(height: 2),
          ],
          card(top),
          const SizedBox(height: 8),
          card(bottom),
        ],
      );

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 16),
        child: SingleChildScrollView(
          controller: h.host,
          padding: HomeScreen2.kPagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                key: const ValueKey<String>('quick-access'),
                height: cue
                    ? HomeScreen2.kQuickAccessCueHeight
                    : HomeScreen2.kQuickAccessHeight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      column('Workout\nPlanner', 'Profile', withCue: cue),
                      column('Block\nPlanner 2', 'Week\nPlanner'),
                      column(
                          'Settings', coach ? 'Coach\nDashboard' : 'Analytics'),
                      Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                        card(coach ? 'Analytics' : 'Coaching'),
                        const SizedBox(height: 8),
                        const SizedBox(
                            width: 150,
                            height: HomeScreen2.kQuickAccessCardHeight),
                      ]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 3),
              TableCalendar<int>(
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2100, 12, 31),
                focusedDay: focusedDay ?? DateTime.utc(2026, 5, 15),
                availableCalendarFormats: const <CalendarFormat, String>{
                  CalendarFormat.month: 'Month',
                },
                headerStyle: HomeScreen2.kCalendarHeaderStyle,
                availableGestures: gestures,
                onDaySelected: (DateTime d, DateTime _) => h.selected.add(d),
                onPageChanged: (DateTime f) => h.pages.add(f),
              ),
              const SizedBox(height: 8),
              // The Feed/Leaderboard section's first row, then enough feed to
              // make the page scroll.
              Container(key: kFeedKey, height: 48, color: Colors.blueGrey),
              const SizedBox(height: 1200),
            ],
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return h;
}

/// A day cell of May 2026 (the focused month), by its visible number.
Finder day(int n) => find
    .descendant(of: find.byType(TableCalendar<int>), matching: find.text('$n'))
    .first;

void main() {
  group('calendar gestures', () {
    testWidgets(
        'a vertical drag begun on a calendar day scrolls the Home page, both ways',
        (WidgetTester tester) async {
      final HomeHarness h = await pumpHome(tester);
      expect(h.host.offset, 0);
      await tester.drag(day(14), const Offset(0, -300));
      await tester.pumpAndSettle();
      final double down = h.host.offset;
      expect(down, greaterThan(100),
          reason: 'the page scrolled toward the feed');
      await tester.drag(day(21), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(h.host.offset, lessThan(down), reason: 'and back toward the top');
      expect(h.selected, isEmpty, reason: 'a drag is not a tap');
      expect(h.pages, isEmpty, reason: 'nor a month change');
    });

    testWidgets('a vertical drag on the calendar header also scrolls the page',
        (WidgetTester tester) async {
      final HomeHarness h = await pumpHome(tester);
      await tester.drag(find.text('May 2026'), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(h.host.offset, greaterThan(100));
    });

    testWidgets(
        'regression contrast: with every gesture enabled the calendar swallows it',
        (WidgetTester tester) async {
      final HomeHarness h =
          await pumpHome(tester, gestures: AvailableGestures.all);
      await tester.drag(day(14), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(h.host.offset, 0, reason: 'the original bug this change fixes');
    });

    testWidgets(
        'a horizontal swipe still changes month and does not scroll the page',
        (WidgetTester tester) async {
      final HomeHarness h = await pumpHome(tester);
      await tester.drag(day(14), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(h.pages, isNotEmpty);
      expect(h.pages.last.month, 6);
      expect(find.text('June 2026'), findsOneWidget);
      expect(h.host.offset, 0);
      await tester.drag(day(14), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(h.pages.last.month, 5);
    });

    testWidgets('tapping a date opens exactly that date',
        (WidgetTester tester) async {
      final HomeHarness h = await pumpHome(tester);
      await tester.tap(day(14));
      await tester.pumpAndSettle();
      expect(h.selected, hasLength(1));
      expect(h.selected.single.year, 2026);
      expect(h.selected.single.month, 5);
      expect(h.selected.single.day, 14);
      expect(h.host.offset, 0);
    });
  });

  group('layout', () {
    // Real device viewports (logical px, insets) × month shape × Home state.
    const List<(String, Size, EdgeInsets)> phones =
        <(String, Size, EdgeInsets)>[
      (
        'iPhone 15 393×852',
        Size(393, 852),
        EdgeInsets.only(top: 59, bottom: 34)
      ),
      ('Pixel 7 412×915', Size(412, 915), EdgeInsets.only(top: 24, bottom: 24)),
    ];
    final Map<String, DateTime> months = <String, DateTime>{
      '6-week month (May 2026)': DateTime.utc(2026, 5, 15),
      '5-week month (June 2026)': DateTime.utc(2026, 6, 15),
    };
    for (final (String name, Size size, EdgeInsets insets) in phones) {
      for (final MapEntry<String, DateTime> m in months.entries) {
        for (final bool cue in <bool>[false, true]) {
          for (final bool coach in <bool>[false, true]) {
            final String state =
                '${cue ? 'first-time cue' : 'normal'}, ${coach ? 'coach' : 'non-coach'}';
            testWidgets(
                '$name, ${m.key}, $state: feed start position, no overflow',
                (WidgetTester tester) async {
              await pumpHome(tester,
                  surface: size,
                  safeArea: insets,
                  cue: cue,
                  coach: coach,
                  focusedDay: m.value);
              expect(tester.takeException(), isNull);
              final double feedTop = tester.getTopLeft(find.byKey(kFeedKey)).dy;
              final double visibleBottom =
                  size.height - insets.bottom - 16; // + SafeArea minimum
              final double shown = visibleBottom - feedTop;
              // ignore: avoid_print
              print(
                  'LAYOUT $name | ${m.key} | $state | feed top y=${feedTop.toStringAsFixed(0)} | visible px of section: ${shown.toStringAsFixed(0)}');
              if (!cue) {
                expect(feedTop, lessThan(visibleBottom),
                    reason:
                        'the Feed/Leaderboard section begins onscreen without scrolling');
              }
            });
          }
        }
      }
    }

    testWidgets(
        'small phone (360×640, cue): nothing overflows or clips; the page scrolls instead',
        (WidgetTester tester) async {
      await pumpHome(tester,
          surface: const Size(360, 640),
          safeArea: const EdgeInsets.only(top: 24),
          cue: true,
          coach: true);
      expect(tester.takeException(), isNull);
      final Rect qa =
          tester.getRect(find.byKey(const ValueKey<String>('quick-access')));
      for (final Element card in find.byType(HomeQuickAccessCard).evaluate()) {
        final Rect r = tester.getRect(find.byWidget(card.widget));
        if (r.left >= 360) continue; // horizontally scrolled out of view
        expect(r.bottom, lessThanOrEqualTo(qa.bottom),
            reason: 'no card clipped by the strip');
      }
      final Rect header = tester.getRect(find.text('May 2026'));
      expect(header.top, greaterThan(qa.bottom),
          reason: 'calendar controls clear of Quick Access');
    });

    testWidgets(
        'the strip reserves exactly the two cards + gap (+ cue label) with room to spare',
        (WidgetTester tester) async {
      for (final bool cue in <bool>[false, true]) {
        await pumpHome(tester, cue: cue);
        final Rect qa =
            tester.getRect(find.byKey(const ValueKey<String>('quick-access')));
        final double tallest = find
            .byType(Column)
            .evaluate()
            .map((Element e) => tester.getRect(find.byWidget(e.widget)))
            .where((Rect r) =>
                r.top >= qa.top - 0.5 &&
                r.bottom <= qa.bottom + 40 &&
                r.height < qa.height + 40 &&
                r.width <= 160)
            .fold<double>(0, (double m, Rect r) => r.bottom > m ? r.bottom : m);
        expect(tallest, lessThanOrEqualTo(qa.bottom), reason: 'cue=$cue');
        expect(qa.bottom - tallest, lessThanOrEqualTo(14),
            reason: 'no wasted height (cue=$cue)');
      }
    });
  });

  group('the Quick Access card at 120px', () {
    for (final double scale in <double>[1.0, 1.3]) {
      testWidgets(
          'three-line and two-line labels fit, icon clear of text (text scale $scale)',
          (WidgetTester tester) async {
        int taps = 0;
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Row(children: <Widget>[
                HomeQuickAccessCard(
                    icon: Icons.monitor_weight,
                    label: 'Body\nWeight\nTracker',
                    onTap: () => taps++),
                HomeQuickAccessCard(
                  icon: Icons.fitness_center,
                  label: 'Enter\nWorkout',
                  onTap: () {},
                  iconWidget: const SizedBox(
                      width: 52,
                      height: 56,
                      child: Icon(Icons.fitness_center, size: 44)),
                ),
                HomeQuickAccessCard(
                    icon: Icons.dashboard,
                    label: 'Coach\nDashboard',
                    onTap: () {}),
              ]),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final Element e in find.byType(HomeQuickAccessCard).evaluate()) {
          final Rect card = tester.getRect(find.byWidget(e.widget));
          expect(card.height, HomeScreen2.kQuickAccessCardHeight);
          final Finder text = find.descendant(
              of: find.byWidget(e.widget), matching: find.byType(Text));
          final Rect label = tester.getRect(text.last);
          expect(label.bottom, lessThanOrEqualTo(card.bottom),
              reason: 'label inside the card');
          expect(label.top, greaterThanOrEqualTo(card.top));
        }
        // The three-line label keeps clear of its 44px icon (it starts at x+44).
        final Rect weightIcon =
            tester.getRect(find.byIcon(Icons.monitor_weight));
        final Rect weightLabel =
            tester.getRect(find.text('Body\nWeight\nTracker'));
        expect(weightLabel.left, greaterThanOrEqualTo(weightIcon.right - 0.5));
        // Taps still land.
        await tester.tap(find.text('Body\nWeight\nTracker'));
        expect(taps, 1);
      });
    }
  });

  test('the page itself uses exactly these contract values', () {
    final String src = File('lib/home_screen_2.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(HomeScreen2.kQuickAccessCardHeight, 120);
    expect(HomeScreen2.kQuickAccessHeight, 260);
    expect(HomeScreen2.kQuickAccessCueHeight, 276);
    expect(HomeScreen2.kPagePadding, const EdgeInsets.fromLTRB(16, 14, 16, 16));
    expect(HomeScreen2.kCalendarHeaderStyle.headerPadding,
        const EdgeInsets.only(top: 4, bottom: 8));
    expect(HomeScreen2.kCalendarGestures, AvailableGestures.horizontalSwipe);
    expect(src.contains('availableGestures: HomeScreen2.kCalendarGestures'),
        isTrue);
    expect(
        src.contains('headerStyle: HomeScreen2.kCalendarHeaderStyle'), isTrue);
    expect(src.contains('padding: HomeScreen2.kPagePadding'), isTrue);
    expect(src.contains('? HomeScreen2.kQuickAccessCueHeight'), isTrue);
    expect(src.contains(': HomeScreen2.kQuickAccessHeight'), isTrue);
    expect(src.contains('height: HomeScreen2.kQuickAccessCardHeight'), isTrue);
    expect(RegExp(r'height:\s*130\b').hasMatch(src), isFalse,
        reason: 'no stale 130px card/spacer');
    // No new vertical scroll view: the page scroll + the horizontal strip.
    expect('SingleChildScrollView('.allMatches(src).length, 2);
    expect(src.contains('scrollDirection: Axis.horizontal'), isTrue);
  });
}
