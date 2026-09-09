import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_checkin_copy_action.dart';
import 'package:localtest222/coach_checkins_logic.dart';

/// Tests the REAL [CheckInCopyAction] that the Weekly Review's Copy button
/// drives — the scoped replacement for the old
/// "callable → setState → clipboard → full-screen _load()" flow.
///
/// The contract under test:
///   • the clipboard receives EXACTLY the server's frozen finalText, never the
///     draft that happened to be on screen (coachPrepareCheckInCopy recomputes
///     the text at copy time from live bodyweight + in-transaction milestone
///     state, so the two can legitimately differ);
///   • everything the card needs afterwards comes back in the response, so no
///     screen-wide reload is required;
///   • a double tap cannot start a second finalisation.

void main() {
  late List<Map<String, String>> calls;
  late List<String> clipboard;

  setUp(() {
    calls = [];
    clipboard = [];
  });

  CheckInCopyAction actionReturning(
    Map<String, dynamic> response, {
    Future<void> Function()? gate,
    bool clipboardThrows = false,
  }) {
    return CheckInCopyAction(
      invoke: ({required athleteUid, required checkpointKey}) async {
        calls.add({'athleteUid': athleteUid, 'checkpointKey': checkpointKey});
        if (gate != null) await gate();
        return response;
      },
      writeClipboard: (text) async {
        if (clipboardThrows) throw StateError('clipboard unavailable');
        clipboard.add(text);
      },
    );
  }

  test('clipboard receives the server finalText, not the visible draft', () async {
    // The card was showing the generation-time draft; the server re-composed
    // the message at copy time. The frozen text is what must be copied.
    const visibleDraft = 'Great week Ann — nice work on the squat.';
    const serverFinal = 'Great week Ann — nice work on the squat. '
        'Bodyweight is coming down too.';
    expect(visibleDraft, isNot(serverFinal));

    final action = actionReturning({
      'text': serverFinal,
      'coverageStart': '2026-09-03',
      'coverageEnd': '2026-09-07',
    });

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.status, CheckInCopyStatus.copied);
    expect(clipboard, [serverFinal]);
    expect(outcome.text, serverFinal);
    // The text put on the clipboard and the text frozen on the report are one
    // and the same string.
    expect(outcome.reportPatch['finalText'], clipboard.single);
  });

  test('returns every field the card needs to render the copied state', () async {
    final action = actionReturning({
      'text': 'msg',
      'coverageStart': '2026-09-03',
      'coverageEnd': '2026-09-07',
    });

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.reportPatch, {
      'status': CheckInStatus.copied,
      'finalText': 'msg',
      'coverageStart': '2026-09-03',
      'coverageEnd': '2026-09-07',
    });
    expect(outcome.coverageEnd, '2026-09-07');
    expect(outcome.finalised, isTrue);
  });

  test('an idempotent server re-copy is reported as alreadyCopied', () async {
    final action = actionReturning({
      'text': 'frozen earlier',
      'coverageStart': '2026-09-03',
      'coverageEnd': '2026-09-07',
      'alreadyCopied': true,
    });

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.alreadyCopied, isTrue);
    expect(outcome.status, CheckInCopyStatus.copied);
    expect(clipboard, ['frozen earlier']);
  });

  test('a second tap while one copy is in flight does not finalise twice',
      () async {
    final gate = Completer<void>();
    final action = actionReturning(
      {'text': 'msg', 'coverageStart': '2026-09-03', 'coverageEnd': '2026-09-07'},
      gate: () => gate.future,
    );

    final first =
        action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');
    expect(action.isBusy('athlete1'), isTrue);

    // Same frame, before any rebuild could disable the button.
    final second =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');
    expect(second.status, CheckInCopyStatus.duplicateIgnored);
    expect(second.finalised, isFalse);

    gate.complete();
    final firstOutcome = await first;

    expect(firstOutcome.status, CheckInCopyStatus.copied);
    expect(calls, hasLength(1)); // exactly one finalisation request
    expect(clipboard, ['msg']);
    expect(action.isBusy('athlete1'), isFalse);
  });

  test('the in-flight guard is per athlete and clears afterwards', () async {
    final action = actionReturning({'text': 'msg', 'coverageEnd': '2026-09-07'});

    await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');
    await action.run(athleteUid: 'athlete2', checkpointKey: '2026-09-07');
    // A later, deliberate re-copy of the same athlete is still allowed.
    await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(calls.map((c) => c['athleteUid']).toList(),
        ['athlete1', 'athlete2', 'athlete1']);
  });

  test('a callable failure copies nothing and reports the real error',
      () async {
    final error = StateError('failed-precondition');
    final action = CheckInCopyAction(
      invoke: ({required athleteUid, required checkpointKey}) async =>
          throw error,
      writeClipboard: (text) async => clipboard.add(text),
    );

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.status, CheckInCopyStatus.failed);
    expect(outcome.finalised, isFalse);
    expect(outcome.reportPatch, isEmpty);
    expect(clipboard, isEmpty); // nothing was claimed to be copied
    expect(outcome.error, same(error));
    expect(action.isBusy('athlete1'), isFalse);
  });

  test('a clipboard failure is truthful: the check-in is still recorded',
      () async {
    final action = actionReturning(
      {'text': 'msg', 'coverageStart': '2026-09-03', 'coverageEnd': '2026-09-07'},
      clipboardThrows: true,
    );

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.status, CheckInCopyStatus.clipboardFailed);
    // The server-side state machine ran — the card must show Copied and the
    // coach must not be told the copy failed.
    expect(outcome.finalised, isTrue);
    expect(outcome.reportPatch['status'], CheckInStatus.copied);
    expect(outcome.text, 'msg'); // handed back for manual copy
  });

  test('the card is updated the moment the authoritative answer arrives, '
      'before the clipboard write', () async {
    final order = <String>[];
    final action = CheckInCopyAction(
      invoke: ({required athleteUid, required checkpointKey}) async =>
          {'text': 'msg', 'coverageEnd': '2026-09-07'},
      writeClipboard: (text) async => order.add('clipboard'),
    );

    await action.run(
      athleteUid: 'athlete1',
      checkpointKey: '2026-09-07',
      onFinalised: (_) => order.add('card'),
    );

    expect(order, ['card', 'clipboard']);
  });

  test('a missing text field degrades to an empty message, not a crash',
      () async {
    final action = actionReturning({'coverageEnd': '2026-09-07'});

    final outcome =
        await action.run(athleteUid: 'athlete1', checkpointKey: '2026-09-07');

    expect(outcome.status, CheckInCopyStatus.copied);
    expect(outcome.text, '');
    expect(clipboard, ['']);
  });
}
