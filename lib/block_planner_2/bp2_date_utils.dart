/// Pure, timezone-safe date helpers for Block Planner 2.
///
/// Every value is a LOCAL date-only `DateTime` (midnight, `isUtc == false`).
/// Arithmetic is done on calendar days (via `DateTime(y, m, d + n)`), never on
/// `Duration`s, so DST transitions can never shift a boundary by an hour.
library;

import 'package:intl/intl.dart';

class Bp2DateUtils {
  Bp2DateUtils._();

  /// Strips the time component, returning local midnight of the same day.
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Adds [days] calendar days (DST-safe).
  static DateTime addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  /// Monday on or before [d].
  static DateTime mondayOnOrBefore(DateTime d) {
    final day = dateOnly(d);
    return addDays(day, -(day.weekday - DateTime.monday));
  }

  /// Sunday on or after [d].
  static DateTime sundayOnOrAfter(DateTime d) {
    final day = dateOnly(d);
    return addDays(day, DateTime.sunday - day.weekday);
  }

  /// Inclusive calendar-day count between two date-only values.
  static int inclusiveDays(DateTime start, DateTime end) {
    final s = dateOnly(start);
    final e = dateOnly(end);
    // Use UTC construction for the difference so a DST change inside the
    // range cannot produce a fractional day.
    final su = DateTime.utc(s.year, s.month, s.day);
    final eu = DateTime.utc(e.year, e.month, e.day);
    return eu.difference(su).inDays + 1;
  }

  /// Snaps an arbitrary range outward to whole Monday–Sunday weeks.
  static Bp2DateRange normalizeRange(DateTime start, DateTime end) {
    var s = dateOnly(start);
    var e = dateOnly(end);
    if (e.isBefore(s)) {
      final t = s;
      s = e;
      e = t;
    }
    return Bp2DateRange(mondayOnOrBefore(s), sundayOnOrAfter(e));
  }

  /// Default range for a brand-new block: this week's Monday through the
  /// Sunday that closes a [weeks]-week block.
  static Bp2DateRange defaultRange(DateTime today, {required int weeks}) {
    final monday = mondayOnOrBefore(today);
    final w = weeks < 1 ? 1 : weeks;
    return Bp2DateRange(monday, addDays(monday, w * 7 - 1));
  }

  static final DateFormat _fmt = DateFormat('d MMM yyyy');

  /// Unambiguous short date, e.g. `21 Sep 2026`.
  static String formatDate(DateTime d) => _fmt.format(dateOnly(d));

  static String weekSummary(int weeks) =>
      weeks == 1 ? '1 week' : '$weeks weeks';

  /// `richard — 21 Sep 2026 to 18 Oct 2026`
  static String autoBlockName(String athleteLabel, Bp2DateRange range) =>
      '$athleteLabel — ${formatDate(range.start)} to ${formatDate(range.end)}';
}

/// A normalized Monday–Sunday range (local, date-only).
class Bp2DateRange {
  final DateTime start;
  final DateTime end;

  const Bp2DateRange(this.start, this.end);

  int get inclusiveDays => Bp2DateUtils.inclusiveDays(start, end);

  /// Always an integer for a normalized range.
  int get weeks => inclusiveDays ~/ 7;

  bool get isWholeWeeks =>
      start.weekday == DateTime.monday &&
      end.weekday == DateTime.sunday &&
      inclusiveDays % 7 == 0;

  @override
  bool operator ==(Object other) =>
      other is Bp2DateRange &&
      other.start.year == start.year &&
      other.start.month == start.month &&
      other.start.day == start.day &&
      other.end.year == end.year &&
      other.end.month == end.month &&
      other.end.day == end.day;

  @override
  int get hashCode => Object.hash(
      start.year, start.month, start.day, end.year, end.month, end.day);

  @override
  String toString() =>
      'Bp2DateRange(${Bp2DateUtils.formatDate(start)} → ${Bp2DateUtils.formatDate(end)})';
}
