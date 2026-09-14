// Pure client-side logic for the coach bi-weekly check-in feature.
//
// Mirrors the checkpoint/coverage rules implemented server-side in
// functions/coach/coverage.js so the Weekly Review screen can display the
// currently-effective coverage window and pick the right stored draft
// preview without any network round-trip. The server remains authoritative:
// the final message text is always produced by the coachPrepareCheckInCopy
// callable at copy time.
//
// No Firebase imports — unit-testable with plain `flutter test`.

/// Report workflow states (mirror of the server values).
class CheckInStatus {
  static const draft = 'draft';
  static const copied = 'copied';
  static const skipped = 'skipped';
  static const expired = 'expired';
}

class CoachCheckinsLogic {
  CoachCheckinsLogic._();

  static const List<int> _checkpointWeekdays = [DateTime.monday, DateTime.thursday];

  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime parseKey(String key) {
    final p = key.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  static String addDaysKey(String key, int days) =>
      dateKey(parseKey(key).add(Duration(days: days)));

  static int diffDaysKey(String a, String b) =>
      parseKey(b).difference(parseKey(a)).inDays;

  /// Latest Monday/Thursday checkpoint on or before [date] (device-local).
  static String checkpointOnOrBefore(DateTime date) {
    var d = DateTime(date.year, date.month, date.day);
    while (!_checkpointWeekdays.contains(d.weekday)) {
      d = d.subtract(const Duration(days: 1));
    }
    return dateKey(d);
  }

  /// The checkpoint immediately before the given checkpoint (Mon ↔ Thu).
  static String previousCheckpointKey(String checkpointKey) {
    final wd = parseKey(checkpointKey).weekday;
    if (wd == DateTime.monday) return addDaysKey(checkpointKey, -4);
    if (wd == DateTime.thursday) return addDaysKey(checkpointKey, -3);
    throw ArgumentError('not a checkpoint key: $checkpointKey');
  }

  static String previousSameWeekdayKey(String checkpointKey) =>
      addDaysKey(checkpointKey, -7);

  /// Effective coverage window [start, end) of a draft, given whether the
  /// immediately preceding checkpoint's message was actually copied and the
  /// coverage end of the most recent finalised-copied checkpoint (clamp).
  static ({String start, String end}) effectiveCoverage(
    String checkpointKey, {
    required bool previousWasCopied,
    String? lastFinalizedCoverageEnd,
  }) {
    var start = previousWasCopied
        ? previousCheckpointKey(checkpointKey)
        : previousSameWeekdayKey(checkpointKey);
    final clamp = lastFinalizedCoverageEnd;
    if (clamp != null && diffDaysKey(start, clamp) > 0) start = clamp;
    if (diffDaysKey(start, checkpointKey) < 0) start = checkpointKey;
    return (start: start, end: checkpointKey);
  }

  /// A draft may be copied / a copy undone only while no NEWER checkpoint has
  /// been finalised (copied or skipped). [statusByKey] maps checkpointKey →
  /// status for the recent reports of the same athlete.
  static bool canMutate(String checkpointKey, Map<String, String> statusByKey) {
    for (final e in statusByKey.entries) {
      if (e.key.compareTo(checkpointKey) <= 0) continue;
      if (e.value == CheckInStatus.copied || e.value == CheckInStatus.skipped) {
        return false;
      }
    }
    return true;
  }

  /// Weigh-in staleness from the most recent weigh-in date (calendar days):
  /// `ok` (<3), `due` (3) or `overdue` (4+ or never).
  static String weighInStatus(String? lastWeighInKey, String todayKey) {
    if (lastWeighInKey == null) return 'overdue';
    final days = diffDaysKey(lastWeighInKey, todayKey);
    if (days >= 4) return 'overdue';
    if (days >= 3) return 'due';
    return 'ok';
  }

  /// Chooses the stored draft preview matching the live coverage state.
  static String pickDraftPreview({
    required bool previousWasCopied,
    required String? draftIfPrevCopied,
    required String? draftIfPrevNotCopied,
  }) {
    final text = previousWasCopied ? draftIfPrevCopied : draftIfPrevNotCopied;
    return text ?? '';
  }

  static final RegExp _dateKeyRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// The checkpoint identity shown by the Weekly Review screen.
  ///
  /// The COACH'S CONFIGURED TIMEZONE is authoritative: the scheduler stamps
  /// coachCheckIns/{coachUid}.lastCheckpointKey using that timezone, and this
  /// resolver always prefers it, so the device timezone can never change
  /// which report is shown or fetched. The device-derived fallback is used
  /// only before the very first server checkpoint exists (no reports exist
  /// yet either, so it can only affect an empty-state label).
  static String resolveCurrentCheckpointKey({
    required String? serverLastCheckpointKey,
    required DateTime deviceNow,
  }) {
    final server = serverLastCheckpointKey;
    if (server != null && _dateKeyRe.hasMatch(server)) {
      final wd = parseKey(server).weekday;
      if (_checkpointWeekdays.contains(wd)) return server;
    }
    return checkpointOnOrBefore(deviceNow);
  }

  // ── Current-week adherence (Monday → Sunday) ─────────────────────────────
  //
  // The server is authoritative: `report['currentWeekAdherence']` carries the
  // fixed calendar week, its target and its per-day facts. These helpers only
  // RENDER that payload, and degrade safely when it is absent (historical or
  // copied reports generated before the field existed).

  static const List<String> weekdayLabels = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static bool isDateKey(Object? v) => v is String && _dateKeyRe.hasMatch(v);

  /// `10 Sep 2026`.
  static String shortDate(String dateKey) {
    final d = parseKey(dateKey);
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  /// An INCLUSIVE day range, compact: `7–13 Sep`, `28 Sep – 4 Oct`,
  /// `29 Dec 2026 – 4 Jan 2027`.
  static String dayRangeLabel(String firstKey, String lastKey) {
    final a = parseKey(firstKey);
    final b = parseKey(lastKey);
    if (a.year != b.year) return '${shortDate(firstKey)} – ${shortDate(lastKey)}';
    if (a.month != b.month) {
      return '${a.day} ${_months[a.month - 1]} – ${b.day} ${_months[b.month - 1]}';
    }
    if (a.day == b.day) return '${a.day} ${_months[a.month - 1]}';
    return '${a.day}–${b.day} ${_months[a.month - 1]}';
  }

  /// The attendance line for the report's training week:
  /// `Training week: 7–13 Sep · 3/4 training days completed`.
  ///
  /// The numerator is DISTINCT calendar days with a completed workout (two
  /// sessions on one date count once), so it says "training days". A
  /// Thursday report's week is only counted through its cutoff and says
  /// "so far". An unknown target is stated, never shown as 0.
  /// Returns null when the report has no usable payload.
  static String? attendanceLabel(Map<String, dynamic>? adherence) {
    if (adherence == null || !isDateKey(adherence['weekStart'])) return null;
    final start = adherence['weekStart'] as String;
    final range = dayRangeLabel(start, addDaysKey(start, 6));
    final completed = _asInt(adherence['completedCount']) ?? 0;
    final planned = (adherence['plannedKnown'] == true)
        ? _asInt(adherence['plannedCount'])
        : null;
    final soFar = adherence['period'] == 'currentWeek' ? ' so far' : '';
    final days = completed == 1 && planned == null ? 'day' : 'days';
    if (planned == null) {
      return 'Training week: $range · $completed training $days completed$soFar'
          ' · target unknown';
    }
    return 'Training week: $range · $completed/$planned training days completed$soFar';
  }

  /// The rolling CHECK-IN window line — a different period from the training
  /// week: `Check-in window: 31 Aug – 6 Sep · 2 training days`. [coverage]
  /// is `[start, end)`.
  static String coverageWindowLabel(
      ({String start, String end}) coverage, int trainingDays) {
    final days = '$trainingDays training day${trainingDays == 1 ? '' : 's'}';
    if (diffDaysKey(coverage.start, coverage.end) <= 0) {
      return 'Check-in window: no days · $days';
    }
    final range =
        dayRangeLabel(coverage.start, addDaysKey(coverage.end, -1));
    return 'Check-in window: $range · $days';
  }

  // ── Weigh-in status + latest entry ───────────────────────────────────────

  static String weighInStatusLabel(String status) {
    switch (status) {
      case 'due':
        return 'Weigh-in due';
      case 'overdue':
        return 'Weigh-in overdue';
      default:
        return 'Weigh-in up to date';
    }
  }

  /// `73.2kg`, `73kg`, `160lb`, or null when the recorded weight is unusable
  /// (never `0kg`).
  static String? recordedWeightLabel(Map<String, dynamic>? entry) {
    final w = entry?['weight'];
    if (w is! num || !w.isFinite || w <= 0) return null;
    final unitRaw = entry?['unit'];
    final unit = unitRaw is String && unitRaw.trim().isNotEmpty
        ? unitRaw.trim().toLowerCase()
        : 'kg';
    final r = (w * 100).round() / 100;
    final text = r == r.roundToDouble()
        ? r.toStringAsFixed(0)
        : r.toString();
    return '$text$unit';
  }

  /// The detail beside the weigh-in pill, from ONE latest recorded entry:
  /// `Last: 10 Sep 2026 · 73.2kg`.
  ///
  /// [entry] is the server's latest-entry map (`dateKey`, `weight`, `unit`)
  /// or null; [historyKnown] says whether that answer is authoritative (a
  /// successful live read, or a report snapshot that recorded it). Only an
  /// authoritative null reads "No weigh-ins recorded" — a load error never
  /// does.
  static String weighInDetailLabel({
    required Map<String, dynamic>? entry,
    required String? lastWeighInKey,
    required bool historyKnown,
  }) {
    final key = isDateKey(entry?['dateKey'])
        ? entry!['dateKey'] as String
        : (isDateKey(lastWeighInKey) ? lastWeighInKey : null);
    if (key == null) {
      return historyKnown ? 'No weigh-ins recorded' : 'Last weigh-in unavailable';
    }
    final weight = recordedWeightLabel(entry);
    return weight == null
        ? 'Last: ${shortDate(key)}'
        : 'Last: ${shortDate(key)} · $weight';
  }

  /// The compact Monday–Sunday strip, as two rows (`Mon — · Tue — · Wed — ·
  /// Thu ✓5` / `Fri — · Sat — · Sun —`).
  ///
  /// `✓N` is N distinct exercises with at least one valid completed set that
  /// calendar day; `—` is no valid training; `…` is a day after the report's
  /// cutoff (not yet counted). Returns an empty list when the
  /// report carries no adherence payload, so the card simply omits the strip.
  static List<String> weekStripRows(Map<String, dynamic>? adherence) {
    final cells = weekStripCells(adherence);
    if (cells.isEmpty) return const [];
    return [cells.take(4).join(' · '), cells.skip(4).join(' · ')];
  }

  /// One `Mon —` / `Thu ✓5` label per weekday, Monday first. Always seven
  /// entries, or empty when there is nothing authoritative to render.
  static List<String> weekStripCells(Map<String, dynamic>? adherence) {
    if (adherence == null) return const [];
    final raw = adherence['days'];
    if (raw is! List || raw.isEmpty) return const [];

    // Index by the server's weekday label so a short, reordered or partial
    // days[] can never shift the strip.
    final byWeekday = <String, Map<String, dynamic>>{};
    for (final d in raw) {
      if (d is Map) {
        final wd = d['weekday'];
        if (wd is String) byWeekday[wd] = Map<String, dynamic>.from(d);
      }
    }
    if (byWeekday.isEmpty) return const [];

    return [
      for (final wd in weekdayLabels) '$wd ${_dayMark(byWeekday[wd])}',
    ];
  }

  static String _dayMark(Map<String, dynamic>? day) {
    // After a Thursday report's cutoff: not yet happened, never a miss.
    if (day != null && day['counted'] == false) return '…';
    if (day == null || day['trained'] != true) return '—';
    final n = _asInt(day['exerciseCount']) ?? 0;
    return '✓$n';
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  /// The message text the card must display. When a report is copied this is
  /// the server-frozen finalText — the exact string the callable returned and
  /// the client put on the clipboard — otherwise the live draft preview.
  static String visibleMessageText({
    required String? status,
    required String? finalText,
    required bool previousWasCopied,
    required String? draftIfPrevCopied,
    required String? draftIfPrevNotCopied,
  }) {
    if (status == CheckInStatus.copied) return finalText ?? '';
    return pickDraftPreview(
      previousWasCopied: previousWasCopied,
      draftIfPrevCopied: draftIfPrevCopied,
      draftIfPrevNotCopied: draftIfPrevNotCopied,
    );
  }
}

/// Per coach⇄athlete coaching service tier, stored as `coachingService` on
/// coachCheckIns/{coachUid}/athletes/{athleteUid}. The stable ids below are
/// the ONLY values firestore.rules accepts. A missing or unknown value is the
/// "Unassigned" compatibility state — it is not a selectable tier.
///
/// Every tier gets the same metrics, cards, schedule and actions; the tier
/// only groups the recap. It grants no access.
class CoachingService {
  CoachingService._();

  static const String field = 'coachingService';

  static const String inPerson = 'inPerson';
  static const String fullOnline = 'fullOnline';
  static const String eightWeek = 'eightWeek';
  static const String prospective = 'prospective';

  /// Selectable tiers, in recap order.
  static const List<String> ordered = [inPerson, fullOnline, eightWeek, prospective];

  static const String unassignedLabel = 'Unassigned';

  static String label(String id) {
    switch (id) {
      case inPerson:
        return 'In-Person';
      case fullOnline:
        return 'Full online service';
      case eightWeek:
        return '8-week program';
      case prospective:
        return 'Prospective';
    }
    return unassignedLabel;
  }

  /// The stored tier, or null (Unassigned) for missing/legacy/unknown values.
  static String? normalize(Object? raw) =>
      raw is String && ordered.contains(raw) ? raw : null;

  /// The settings patch for selecting [id]. Throws for anything that is not a
  /// selectable tier, so the client can never write a value the rules reject.
  static Map<String, dynamic> patchFor(String id) {
    if (!ordered.contains(id)) {
      throw ArgumentError.value(id, 'coachingService', 'not a coaching service tier');
    }
    return {field: id};
  }
}

/// One visible group of the recap list.
class RecapGroup<T> {
  const RecapGroup({required this.service, required this.label, required this.items});

  /// The tier id, or null for the Unassigned group.
  final String? service;
  final String label;
  final List<T> items;
}

class CoachRecapOrdering {
  CoachRecapOrdering._();

  /// Groups [items] by coaching service in the fixed tier order, then an
  /// "Unassigned" group last; alphabetical (case-insensitive) by [nameOf]
  /// inside each group, with the uid as a deterministic tie-break. Empty
  /// groups are omitted. Pure: call it on the already-filtered list.
  static List<RecapGroup<T>> group<T>(
    Iterable<T> items, {
    required String Function(T) nameOf,
    required String Function(T) uidOf,
    required Object? Function(T) serviceOf,
  }) {
    final buckets = <String?, List<T>>{};
    for (final item in items) {
      buckets.putIfAbsent(CoachingService.normalize(serviceOf(item)), () => []).add(item);
    }
    int compare(T a, T b) {
      final byName = nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
      if (byName != 0) return byName;
      return uidOf(a).compareTo(uidOf(b));
    }

    return [
      for (final id in [...CoachingService.ordered, null])
        if (buckets[id] != null && buckets[id]!.isNotEmpty)
          RecapGroup<T>(
            service: id,
            label: id == null ? CoachingService.unassignedLabel : CoachingService.label(id),
            items: buckets[id]!..sort(compare),
          ),
    ];
  }
}
