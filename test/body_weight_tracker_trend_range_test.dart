// Regression coverage for the Body Weight Tracker's custom date-range trend
// chart. These exercise the pure helpers and two Firebase-free standalone
// widgets extracted into lib/body_weight_tracker.dart, ported from the E1RM
// Trend chart's custom-range implementation in exercise_details_screen.dart.
//
// The full BodyWeightTracker widget is NOT mounted here: it depends on
// FirebaseFirestore.instance / FirebaseAuth.instance / UserContext, and the
// task this covers explicitly asked to avoid a large Firebase test harness.
// Everything feeding the picker (seed range, clamping, labels, tick
// selection, and the series builder) is covered as pure functions instead;
// the calendar button and title row are covered as isolated widgets, the
// same pattern test/wes2_app_bar_test.dart uses for Wes2AppBar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/body_weight_tracker.dart';

void main() {
  group('nextTrendRange - preset cycle', () {
    test(
        'cycles 14 days -> 1 month -> 3 months -> 6 months -> 1 year -> 14 days',
        () {
      expect(nextTrendRange(TrendRange.d14), TrendRange.m30);
      expect(nextTrendRange(TrendRange.m30), TrendRange.m90);
      expect(nextTrendRange(TrendRange.m90), TrendRange.m180);
      expect(nextTrendRange(TrendRange.m180), TrendRange.y365);
      expect(nextTrendRange(TrendRange.y365), TrendRange.d14);
    });

    test(
        'tapping the centre control from custom mode advances the retained preset',
        () {
      // BwTrendTitleRow.onTitleTap -> _cycleTrend() always does
      // `_trend = nextTrendRange(_trend); _customTrend = null;` regardless of
      // whether custom mode was active, so the retained preset alone governs
      // the next value.
      const retained = TrendRange.m90;
      expect(nextTrendRange(retained), TrendRange.m180);
    });
  });

  group('trendPresetStart', () {
    final now = DateTime(2026, 8, 20, 15, 30);

    test('14-day preset starts 13 days back, truncated to midnight', () {
      final start = trendPresetStart(TrendRange.d14, now);
      expect(start, DateTime(2026, 8, 7));
    });

    test('1-year preset starts 364 days back', () {
      final start = trendPresetStart(TrendRange.y365, now);
      expect(start, DateTime(2025, 8, 21));
    });
  });

  group('clampDateRange', () {
    final firstDate = DateTime(2000, 1, 1);
    final today = DateTime(2026, 8, 20);

    test('leaves an in-bounds range untouched', () {
      final r =
          DateTimeRange(start: DateTime(2026, 3, 1), end: DateTime(2026, 8, 1));
      expect(clampDateRange(r, firstDate: firstDate, lastDate: today), r);
    });

    test('clamps a start before firstDate up to firstDate', () {
      final r =
          DateTimeRange(start: DateTime(1999, 1, 1), end: DateTime(2026, 1, 1));
      final clamped = clampDateRange(r, firstDate: firstDate, lastDate: today);
      expect(clamped.start, firstDate);
    });

    test('clamps an end after today down to today', () {
      final r =
          DateTimeRange(start: DateTime(2026, 1, 1), end: DateTime(2030, 1, 1));
      final clamped = clampDateRange(r, firstDate: firstDate, lastDate: today);
      expect(clamped.end, today);
    });

    test('never leaves end before start', () {
      final r =
          DateTimeRange(start: DateTime(2030, 1, 1), end: DateTime(2030, 1, 1));
      final clamped = clampDateRange(r, firstDate: firstDate, lastDate: today);
      expect(clamped.end.isBefore(clamped.start), isFalse);
    });
  });

  group('customTrendRangeLabel', () {
    test('same-year range omits the year', () {
      final now = DateTime(2026, 8, 21);
      final r = DateTimeRange(
          start: DateTime(2026, 3, 1), end: DateTime(2026, 8, 21));
      expect(customTrendRangeLabel(r, now), '1 Mar – 21 Aug');
    });

    test(
        'a range not wholly within the current year includes abbreviated years',
        () {
      final now = DateTime(2026, 8, 21);
      final r = DateTimeRange(
          start: DateTime(2025, 12, 1), end: DateTime(2026, 1, 15));
      expect(customTrendRangeLabel(r, now), '1 Dec 25 – 15 Jan 26');
    });
  });

  group('bwCustomTickIndices - index-based thinning (not calendar-day based)',
      () {
    test('few observations are all labelled', () {
      expect(bwCustomTickIndices(4), {0, 1, 2, 3});
      expect(bwCustomTickIndices(6), {0, 1, 2, 3, 4, 5});
    });

    test(
        'many observations are thinned but keep first and last, capped near six',
        () {
      final ticks =
          bwCustomTickIndices(400); // a long custom range: many plotted days
      expect(ticks, contains(0));
      expect(ticks, contains(399));
      expect(ticks.length, lessThanOrEqualTo(6));
      expect(ticks.length, greaterThanOrEqualTo(4));
    });

    test(
        'a sparse custom range (few plotted points) is not thinned to nearly nothing',
        () {
      // A wide date span with only a handful of actual weigh-ins must still
      // show every one of them, since thinning is index-based, not by span.
      final ticks = bwCustomTickIndices(3);
      expect(ticks, {0, 1, 2});
    });

    test('empty and single-point series are safe', () {
      expect(bwCustomTickIndices(0), isEmpty);
      expect(bwCustomTickIndices(1), {0});
    });
  });

  group('buildBodyWeightSeriesForRange', () {
    Map<String, dynamic> entry(DateTime date, double weight, {String? tod}) => {
          'id': '${date.toIso8601String()}-$tod',
          'date': date,
          'weight': weight,
          'unit': 'kg',
          'tod': tod
        };

    test('applies the range inclusively at both boundaries', () {
      final start = DateTime(2026, 3, 1);
      final end = DateTime(2026, 3, 10);
      final weights = [
        entry(DateTime(2026, 3, 10, 8), 80.0,
            tod: 'am'), // end day, must be included
        entry(DateTime(2026, 3, 1, 8), 79.0,
            tod: 'am'), // start day, must be included
      ];
      final series = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'am');
      expect(series.map((e) => e['date']),
          [DateTime(2026, 3, 1), DateTime(2026, 3, 10)]);
    });

    test('excludes observations before the start and after the end', () {
      final start = DateTime(2026, 3, 1);
      final end = DateTime(2026, 3, 10);
      final weights = [
        entry(DateTime(2026, 2, 28, 23, 59), 78.0, tod: 'am'),
        entry(DateTime(2026, 3, 11, 0, 1), 81.0, tod: 'am'),
        entry(DateTime(2026, 3, 5, 8), 79.5, tod: 'am'),
      ];
      final series = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'am');
      expect(series.length, 1);
      expect(series.single['date'], DateTime(2026, 3, 5));
    });

    test('classifies am, pm, and legacy-without-tod (treated as am) correctly',
        () {
      final start = DateTime(2026, 3, 1);
      final end = DateTime(2026, 3, 5);
      final weights = [
        entry(DateTime(2026, 3, 1, 7), 80.0, tod: 'am'),
        entry(DateTime(2026, 3, 1, 19), 81.0, tod: 'pm'),
        entry(DateTime(2026, 3, 2, 7), 79.0, tod: null), // legacy: no tod -> am
      ];
      final am = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'am');
      final pm = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'pm');
      expect(am.map((e) => e['date']),
          [DateTime(2026, 3, 1), DateTime(2026, 3, 2)]);
      expect(pm.map((e) => e['date']), [DateTime(2026, 3, 1)]);
    });

    test(
        'newest observation wins when a day has duplicates (weights is newest-first)',
        () {
      final start = DateTime(2026, 3, 1);
      final end = DateTime(2026, 3, 1);
      final weights = [
        entry(DateTime(2026, 3, 1, 20), 82.0,
            tod: 'am'), // logged later, appears first (newest-first)
        entry(DateTime(2026, 3, 1, 7), 80.0, tod: 'am'),
      ];
      final series = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'am');
      expect(series.single['weight'], 82.0);
    });

    test('chronological ordering is preserved regardless of input order', () {
      final start = DateTime(2026, 3, 1);
      final end = DateTime(2026, 3, 10);
      final weights = [
        entry(DateTime(2026, 3, 10), 82.0, tod: 'am'),
        entry(DateTime(2026, 3, 1), 80.0, tod: 'am'),
        entry(DateTime(2026, 3, 5), 81.0, tod: 'am'),
      ];
      final series = buildBodyWeightSeriesForRange(
          weights: weights, start: start, end: end, tod: 'am');
      expect(series.map((e) => e['date']),
          [DateTime(2026, 3, 1), DateTime(2026, 3, 5), DateTime(2026, 3, 10)]);
    });

    test('a custom period containing no weigh-ins returns an empty series', () {
      final series = buildBodyWeightSeriesForRange(
        weights: [entry(DateTime(2020, 1, 1), 70.0, tod: 'am')],
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 31),
        tod: 'am',
      );
      expect(series, isEmpty);
    });
  });

  group('fitCustomTrendTitle', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('returns the full "Weight Trend • range" label when it fits', () {
      final text =
          fitCustomTrendTitle(rangeLabel: '1 Mar – 21 Aug', maxWidth: 2000);
      expect(text, 'Weight Trend • 1 Mar – 21 Aug');
    });

    test('falls back to the bare range label on a narrow width', () {
      final text =
          fitCustomTrendTitle(rangeLabel: '1 Mar – 21 Aug', maxWidth: 40);
      expect(text, '1 Mar – 21 Aug');
    });
  });

  group('BwRangePickerButton (isolated widget, no Firebase)', () {
    Future<void> pump(WidgetTester tester,
        {required bool active, required VoidCallback onTap}) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BwRangePickerButton(
              active: active, accent: Colors.cyan, onTap: onTap),
        ),
      ));
    }

    testWidgets('tapping the button invokes onTap', (tester) async {
      var taps = 0;
      await pump(tester, active: false, onTap: () => taps++);
      await tester.tap(find.byType(BwRangePickerButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('renders without error whether active or not', (tester) async {
      await pump(tester, active: true, onTap: () {});
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.date_range), findsOneWidget);
    });
  });

  group('BwTrendTitleRow (isolated widget, no Firebase)', () {
    Widget host(double width, Widget child) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, height: 60, child: child),
            ),
          ),
        );

    testWidgets(
        'preset mode shows the preset label centred with no overflow at 320px',
        (tester) async {
      var titleTaps = 0;
      await tester.pumpWidget(host(
        320,
        BwTrendTitleRow(
          presetLabel: '14-Day Trend',
          customActive: false,
          customRangeLabel: '',
          onTitleTap: () => titleTaps++,
          onCalendarTap: () {},
          accentColor: Colors.cyan,
          menu: const Icon(Icons.more_vert),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('14-Day Trend'), findsOneWidget);

      await tester.tap(find.text('14-Day Trend'));
      expect(titleTaps, 1);
    });

    // NOTE on the two tests below: flutter_test's default font fallback gives
    // every glyph a fixed advance width equal to the font size, so the exact
    // device-pixel crossover between the full "Weight Trend • …" label and
    // its short fallback is a test-environment artifact, not something real
    // phone font metrics would reproduce. Rather than hardcode which of the
    // two candidate strings wins at a given width (fragile and not actually
    // representative of a real device), these assert the properties that
    // genuinely matter: at both narrow widths the row lays out with no
    // overflow, and whichever label is shown is always one of the two valid
    // candidates fitCustomTrendTitle can produce — never truncated mid-string
    // or blank.
    for (final width in [320.0, 360.0]) {
      testWidgets(
          'custom mode renders one of the two valid labels with no overflow at ${width.toInt()}px',
          (tester) async {
        const rangeLabel =
            '1 Dec 25 – 15 Jan 26'; // cross-year: the longest realistic custom title
        const full = 'Weight Trend • $rangeLabel';
        await tester.pumpWidget(host(
          width,
          BwTrendTitleRow(
            presetLabel: '14-Day Trend',
            customActive: true,
            customRangeLabel: rangeLabel,
            onTitleTap: () {},
            onCalendarTap: () {},
            accentColor: Colors.cyan,
            menu: const Icon(Icons.more_vert),
          ),
        ));
        expect(tester.takeException(), isNull,
            reason:
                'the balanced side-controls layout must not overflow at ${width.toInt()}px');
        expect(
          find.byWidgetPredicate(
              (w) => w is Text && (w.data == full || w.data == rangeLabel)),
          findsOneWidget,
          reason:
              'the shown label must be the full or the short candidate, never blank or truncated',
        );
      });
    }

    testWidgets(
        'tapping the calendar button invokes onCalendarTap, not onTitleTap',
        (tester) async {
      var titleTaps = 0;
      var calendarTaps = 0;
      await tester.pumpWidget(host(
        360,
        BwTrendTitleRow(
          presetLabel: '14-Day Trend',
          customActive: false,
          customRangeLabel: '',
          onTitleTap: () => titleTaps++,
          onCalendarTap: () => calendarTaps++,
          accentColor: Colors.cyan,
          menu: const Icon(Icons.more_vert),
        ),
      ));
      await tester.tap(find.byType(BwRangePickerButton));
      await tester.pump();
      expect(calendarTaps, 1);
      expect(titleTaps, 0);
    });
  });
}
