import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_date_utils.dart';

void main() {
  group('Monday–Sunday snapping', () {
    test('a mid-week range snaps outward to whole weeks', () {
      // Wed 23 Sep 2026 → Tue 6 Oct 2026
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 23), DateTime(2026, 10, 6));
      expect(r.start, DateTime(2026, 9, 21)); // Monday
      expect(r.end, DateTime(2026, 10, 11)); // Sunday
      expect(r.start.weekday, DateTime.monday);
      expect(r.end.weekday, DateTime.sunday);
      expect(r.isWholeWeeks, isTrue);
      expect(r.weeks, 3);
    });

    test('a Monday start and Sunday end are unchanged', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 21), DateTime(2026, 10, 18));
      expect(r.start, DateTime(2026, 9, 21));
      expect(r.end, DateTime(2026, 10, 18));
      expect(r.weeks, 4);
    });

    test('a single day becomes one full week', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 24), DateTime(2026, 9, 24));
      expect(r.weeks, 1);
      expect(Bp2DateUtils.weekSummary(r.weeks), '1 week');
    });

    test('reversed input is swapped, not rejected', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 10, 6), DateTime(2026, 9, 23));
      expect(r.start, DateTime(2026, 9, 21));
      expect(r.end, DateTime(2026, 10, 11));
    });

    test('time-of-day is discarded (date-only values)', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 21, 23, 59), DateTime(2026, 9, 27, 0, 1));
      expect(r.start, DateTime(2026, 9, 21));
      expect(r.end, DateTime(2026, 9, 27));
      expect(r.weeks, 1);
    });
  });

  group('inclusive week count', () {
    test('across a month boundary', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 28), DateTime(2026, 10, 4));
      expect(r.inclusiveDays, 7);
      expect(r.weeks, 1);
    });

    test('across a year boundary', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 12, 28), DateTime(2027, 1, 10));
      expect(r.start, DateTime(2026, 12, 28));
      expect(r.end, DateTime(2027, 1, 10));
      expect(r.weeks, 2);
      expect(Bp2DateUtils.weekSummary(r.weeks), '2 weeks');
    });

    test('across NZ DST start (27 Sep 2026) and end (5 Apr 2026)', () {
      // DST begins in NZ on the last Sunday of September.
      final spring = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 21), DateTime(2026, 10, 4));
      expect(spring.inclusiveDays, 14);
      expect(spring.weeks, 2);
      // DST ends on the first Sunday of April.
      final autumn = Bp2DateUtils.normalizeRange(
          DateTime(2026, 3, 30), DateTime(2026, 4, 12));
      expect(autumn.inclusiveDays, 14);
      expect(autumn.weeks, 2);
    });

    test('every normalized range has an integer week count', () {
      for (var d = 0; d < 60; d++) {
        final start = DateTime(2026, 1, 1 + d);
        final r = Bp2DateUtils.normalizeRange(
            start, start.add(const Duration(days: 17)));
        expect(r.inclusiveDays % 7, 0, reason: 'start $start');
        expect(r.weeks, r.inclusiveDays ~/ 7);
      }
    });
  });

  group('defaults and naming', () {
    test('default range starts on this week\'s Monday', () {
      final r = Bp2DateUtils.defaultRange(DateTime(2026, 9, 24), weeks: 4);
      expect(r.start, DateTime(2026, 9, 21));
      expect(r.end, DateTime(2026, 10, 18));
      expect(r.weeks, 4);
    });

    test('auto name uses unambiguous d MMM yyyy dates', () {
      final r = Bp2DateUtils.normalizeRange(
          DateTime(2026, 9, 21), DateTime(2026, 10, 18));
      expect(Bp2DateUtils.autoBlockName('richard', r),
          'richard — 21 Sep 2026 to 18 Oct 2026');
    });
  });
}
