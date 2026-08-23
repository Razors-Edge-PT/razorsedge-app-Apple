import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/exercise_details_screen.dart';

/// Unit tests for the Exercise Details analytics axis helpers.
///
/// Covers the validation cases from the analytics-graph work: dynamic Y
/// scaling (no forced 100 kg ceiling), nice grid intervals, degenerate data,
/// and X-axis label thinning. X positions themselves stay index-based, so
/// nothing here depends on elapsed calendar time.

int _tickCount(ChartAxisScale s) => ((s.maxY - s.minY) / s.interval).round();

void _expectSane(ChartAxisScale s, List<double> data) {
  expect(s.maxY, greaterThan(s.minY),
      reason: 'minY == maxY collapses the chart');
  for (final v in data) {
    expect(v, greaterThanOrEqualTo(s.minY),
        reason: 'axis must contain the data');
    expect(v, lessThanOrEqualTo(s.maxY), reason: 'axis must contain the data');
  }
  expect(_tickCount(s), inInclusiveRange(2, 8),
      reason: 'grid should stay in a readable band');
  expect(ChartAxisScale.steps, contains(s.interval),
      reason: 'interval must come from the nice-number ladder');
}

void main() {
  group('ChartAxisScale - visible-range scaling', () {
    test('CASE A: a small smooth +1 kg trend is not flattened', () {
      const data = [54.0, 54.2, 54.6, 55.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      // The old logic produced 0-100; the 1 kg trend must now fill the height.
      expect(s.maxY - s.minY, lessThanOrEqualTo(4.0));
      final usedFraction = (55.0 - 54.0) / (s.maxY - s.minY);
      expect(usedFraction, greaterThan(0.3),
          reason: 'the 1 kg change should occupy a real share of the chart');
      expect(s.decimals, greaterThanOrEqualTo(1),
          reason: 'sub-kilo intervals must keep their decimals');
    });

    test('CASE B: sub-100 kg data no longer stretches towards 100', () {
      const data = [48.0, 50.0, 54.0, 58.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.maxY, lessThan(70.0));
      expect(s.minY, greaterThan(35.0));
    });

    test('CASE C: large values get a proportionally larger axis', () {
      const data = [110.0, 125.0, 140.0, 150.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.maxY - s.minY, greaterThan(30.0));
      expect(s.interval, greaterThanOrEqualTo(5.0));
    });

    test('CASE D: identical values still get a readable window', () {
      const data = [55.0, 55.0, 55.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.minY, lessThan(55.0));
      expect(s.maxY, greaterThan(55.0));
    });

    test('a single point behaves like identical values', () {
      const data = [82.5];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.maxY - s.minY, greaterThan(0.5));
    });

    test('no points falls back to a valid empty axis', () {
      final s = ChartAxisScale.fromValues(const <double>[]);
      expect(s, same(ChartAxisScale.empty));
      expect(s.maxY, greaterThan(s.minY));
      expect(s.interval, greaterThan(0));
    });

    test('an extremely small spread does not collapse', () {
      const data = [54.00, 54.02];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.decimals, greaterThanOrEqualTo(1));
    });

    test('values differing by less than 1 kg keep decimal labels', () {
      const data = [54.0, 54.3, 54.6, 55.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.interval, lessThan(1.0));
      expect(s.format(s.minY), contains('.'));
    });

    test('a very large spread stays on coarse nice steps', () {
      const data = [20.0, 300.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.interval, greaterThanOrEqualTo(50.0));
      expect(s.decimals, 0);
    });

    test('never drops below zero for non-negative data', () {
      const data = [0.5, 1.0];
      final s = ChartAxisScale.fromValues(data);

      _expectSane(s, data);
      expect(s.minY, greaterThanOrEqualTo(0.0));
    });

    test('CASE H: axis spans every visible rep-target series', () {
      final seriesA = [60.0, 62.0, 64.0];
      final seriesB = [48.0, 49.0];
      final seriesC = [70.0, 71.5];

      final all = <double>[...seriesA, ...seriesB, ...seriesC];
      final combined = ChartAxisScale.fromValues(all);
      final firstOnly = ChartAxisScale.fromValues(seriesA);

      _expectSane(combined, all);
      expect(combined.minY, lessThanOrEqualTo(48.0));
      expect(combined.maxY, greaterThanOrEqualTo(71.5));
      // Proves the axis is not taken from the first line alone.
      expect(firstOnly.minY, greaterThan(combined.minY));
    });
  });

  group('ChartAxisScale - label formatting', () {
    test('whole-number intervals drop the decimal point', () {
      const s = ChartAxisScale(minY: 100, maxY: 160, interval: 10, decimals: 0);
      expect(s.format(120), '120');
    });

    test('half-kilo intervals keep one decimal', () {
      const s =
          ChartAxisScale(minY: 53.5, maxY: 55.5, interval: 0.5, decimals: 1);
      expect(s.format(54), '54.0');
      expect(s.format(53.5), '53.5');
    });

    test('quarter-kilo intervals keep two decimals', () {
      expect(ChartAxisScale.decimalsFor(0.25), 2);
      expect(ChartAxisScale.decimalsFor(0.5), 1);
      expect(ChartAxisScale.decimalsFor(1), 0);
      expect(ChartAxisScale.decimalsFor(10), 0);
      // 2.5 steps land on .5 values, so they need a decimal too.
      expect(ChartAxisScale.decimalsFor(2.5), 1);
    });

    test('negative zero never renders with a minus sign', () {
      const s = ChartAxisScale(minY: 0, maxY: 5, interval: 1, decimals: 1);
      expect(s.format(-0.0), '0.0');
    });
  });

  group('X-axis ticks', () {
    test('few observations are all labelled', () {
      expect(computeXTickIndices(4), {0, 1, 2, 3});
      expect(computeXTickIndices(6), {0, 1, 2, 3, 4, 5});
    });

    test('many observations are thinned but keep first and last', () {
      final ticks = computeXTickIndices(40);
      expect(ticks, contains(0));
      expect(ticks, contains(39));
      expect(ticks.length, lessThanOrEqualTo(6));
      expect(ticks.length, greaterThanOrEqualTo(4));
    });

    test('empty and single-point series are safe', () {
      expect(computeXTickIndices(0), isEmpty);
      expect(computeXTickIndices(1), {0});
    });
  });

  group('X-axis labels', () {
    test('CASE E: uneven calendar gaps still produce one label per point', () {
      final dates = [
        DateTime(2026, 3, 1),
        DateTime(2026, 4, 1),
        DateTime(2026, 4, 2),
      ];
      final ticks = computeXTickIndices(dates.length);
      final labels = buildXAxisLabels(dates, ticks);

      // One label per observation, and every observation is ticked: the
      // horizontal positions are indices 0,1,2 regardless of the 31-day gap.
      expect(labels.length, 3);
      expect(ticks, {0, 1, 2});
      expect(labels.toSet().length, 3);
      expect(labels.first, '1 Mar');
    });

    test('long ranges use a coarse format', () {
      final dates = [
        for (int i = 0; i < 24; i++)
          DateTime(2025, 1 + (i ~/ 2), 1 + (i % 2) * 10)
      ];
      final labels = buildXAxisLabels(dates, computeXTickIndices(dates.length));
      expect(labels.first, matches(RegExp(r'^[A-Z][a-z]{2}')));
    });

    test('duplicate-looking ticks are refined until distinguishable', () {
      // Wide span (so the coarse "MMM yy" format is chosen first) with most
      // observations packed into a single month.
      final dates = <DateTime>[
        DateTime(2025, 1, 5),
        for (int d = 20; d <= 29; d++) DateTime(2026, 5, d),
      ];
      final ticks = computeXTickIndices(dates.length);
      final labels = buildXAxisLabels(dates, ticks);

      final shown = [for (final i in ticks) labels[i]];
      expect(shown.toSet().length, shown.length,
          reason: 'several ticks all reading "May 26" must be refined');
    });

    test('no dates yields no labels', () {
      expect(buildXAxisLabels(const [], const {}), isEmpty);
    });
  });

  group('ChartWindow', () {
    test('CASE F: only observations inside the range are included', () {
      final window = ChartWindow(
        DateTime(2026, 2, 1),
        DateTime(2026, 5, 15, 23, 59, 59, 999),
      );

      expect(window.contains(DateTime(2026, 1, 31, 23, 59)), isFalse);
      expect(window.contains(DateTime(2026, 2, 1)), isTrue);
      expect(window.contains(DateTime(2026, 3, 20, 18, 30)), isTrue);
      expect(window.contains(DateTime(2026, 5, 15, 20, 0)), isTrue);
      expect(window.contains(DateTime(2026, 5, 16)), isFalse);
    });
  });
}
