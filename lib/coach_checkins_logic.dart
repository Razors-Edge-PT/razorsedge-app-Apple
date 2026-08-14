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
