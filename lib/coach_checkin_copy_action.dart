// Scoped Copy / finalisation action for the Coach Weekly Review.
//
// WHY THE CLIPBOARD WRITE CANNOT BE OPTIMISTIC
// --------------------------------------------
// coachPrepareCheckInCopy does not simply return the draft the card is
// showing. Inside its transaction it re-fetches live bodyweight, re-decides
// the milestone from transactional praise/goal-phase state, and clamps the
// coverage window against lastFinalizedCoverageEnd — then composes the text
// with buildDraftText. The frozen finalText can therefore legitimately
// differ from the draft preview on screen. Writing the visible text to the
// clipboard before the callable returned would be exactly the "coach copied
// draft A, server persisted draft B" bug, so the clipboard write happens
// after the callable returns. That is the ONLY ordering that guarantees
// clipboard text == report.finalText.
//
// WHAT THIS CLASS DOES REMOVE
// ---------------------------
// The other half of the old flow: the global screen reload. The callable's
// response already carries everything the card needs (text, coverageStart,
// coverageEnd), so this returns a patch the screen applies to that ONE
// athlete instead of refetching the roster, the coach context and every
// report. It also owns the per-athlete in-flight guard, so a double tap
// cannot start a second finalisation.

import 'coach_checkins_logic.dart';

/// Calls `coachPrepareCheckInCopy` and returns its decoded payload.
typedef CheckInCopyInvoker = Future<Map<String, dynamic>> Function({
  required String athleteUid,
  required String checkpointKey,
});

/// Writes [text] to the system clipboard. Throws if the write fails.
typedef CheckInClipboardWriter = Future<void> Function(String text);

enum CheckInCopyStatus {
  /// Server finalised the check-in AND the clipboard write succeeded.
  copied,

  /// Server finalised the check-in, but the clipboard write failed. The copy
  /// itself is recorded — never report this as "copy failed".
  clipboardFailed,

  /// A copy for this athlete was already in flight; this tap did nothing.
  duplicateIgnored,

  /// The callable failed. Nothing was finalised and nothing was copied.
  failed,
}

class CheckInCopyOutcome {
  const CheckInCopyOutcome({
    required this.status,
    this.text = '',
    this.reportPatch = const {},
    this.coverageEnd,
    this.alreadyCopied = false,
    this.error,
  });

  final CheckInCopyStatus status;

  /// The server-frozen finalText. Identical to what was put on the clipboard.
  final String text;

  /// Fields to merge into the athlete's local report map.
  final Map<String, dynamic> reportPatch;

  /// The finalised coverage end — also the athlete settings' new
  /// `lastFinalizedCoverageEnd`, which the server wrote in the same
  /// transaction.
  final String? coverageEnd;

  /// The report was already `copied`; the server returned the existing
  /// frozen text unchanged (idempotent re-copy).
  final bool alreadyCopied;

  final Object? error;

  /// True when the server-side state machine ran to completion, whatever the
  /// clipboard did afterwards.
  bool get finalised =>
      status == CheckInCopyStatus.copied ||
      status == CheckInCopyStatus.clipboardFailed;
}

class CheckInCopyAction {
  CheckInCopyAction({required this.invoke, required this.writeClipboard});

  final CheckInCopyInvoker invoke;
  final CheckInClipboardWriter writeClipboard;

  final Set<String> _inFlight = <String>{};

  /// True while this athlete's copy is awaiting the server. Drives the small
  /// per-card pending state — never a screen-wide loading state.
  bool isBusy(String athleteUid) => _inFlight.contains(athleteUid);

  /// Runs one copy.
  ///
  /// [onFinalised] fires the moment the authoritative response is in, before
  /// the clipboard write, so the card can flip to Copied immediately.
  Future<CheckInCopyOutcome> run({
    required String athleteUid,
    required String checkpointKey,
    void Function(CheckInCopyOutcome outcome)? onFinalised,
  }) async {
    // Synchronous guard: a second tap in the same frame — before any rebuild
    // could disable the button — must not start a second finalisation.
    if (_inFlight.contains(athleteUid)) {
      return const CheckInCopyOutcome(
          status: CheckInCopyStatus.duplicateIgnored);
    }
    _inFlight.add(athleteUid);
    try {
      final Map<String, dynamic> data = await invoke(
        athleteUid: athleteUid,
        checkpointKey: checkpointKey,
      );

      final text = (data['text'] as String?) ?? '';
      final coverageStart = data['coverageStart'] as String?;
      final coverageEnd = data['coverageEnd'] as String?;

      final patch = <String, dynamic>{
        'status': CheckInStatus.copied,
        'finalText': text,
        if (coverageStart != null) 'coverageStart': coverageStart,
        if (coverageEnd != null) 'coverageEnd': coverageEnd,
      };

      final finalised = CheckInCopyOutcome(
        status: CheckInCopyStatus.copied,
        text: text,
        reportPatch: patch,
        coverageEnd: coverageEnd,
        alreadyCopied: data['alreadyCopied'] == true,
      );
      onFinalised?.call(finalised);

      try {
        await writeClipboard(text);
      } catch (e) {
        return CheckInCopyOutcome(
          status: CheckInCopyStatus.clipboardFailed,
          text: text,
          reportPatch: patch,
          coverageEnd: coverageEnd,
          alreadyCopied: finalised.alreadyCopied,
          error: e,
        );
      }
      return finalised;
    } catch (e) {
      return CheckInCopyOutcome(status: CheckInCopyStatus.failed, error: e);
    } finally {
      _inFlight.remove(athleteUid);
    }
  }
}
