import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_checkins_logic.dart';
import 'package:localtest222/periodization_model_utils.dart';

void main() {
  // Calendar reference (2026): Aug 3 Mon, Aug 6 Thu, Aug 10 Mon, Aug 13 Thu.

  group('checkpoint math', () {
    test('checkpointOnOrBefore finds the latest Mon/Thu', () {
      expect(CoachCheckinsLogic.checkpointOnOrBefore(DateTime(2026, 8, 12)),
          '2026-08-10'); // Wed → Mon
      expect(CoachCheckinsLogic.checkpointOnOrBefore(DateTime(2026, 8, 13)),
          '2026-08-13'); // Thu → itself
      expect(CoachCheckinsLogic.checkpointOnOrBefore(DateTime(2026, 8, 16)),
          '2026-08-13'); // Sun → Thu
    });

    test('previous checkpoint alternates Mon ↔ Thu', () {
      expect(CoachCheckinsLogic.previousCheckpointKey('2026-08-10'), '2026-08-06');
      expect(CoachCheckinsLogic.previousCheckpointKey('2026-08-13'), '2026-08-10');
      expect(CoachCheckinsLogic.previousSameWeekdayKey('2026-08-10'), '2026-08-03');
    });
  });

  group('effective coverage (mirrors functions/coach/coverage.js)', () {
    test('previous Thursday copied → Monday covers Thu→Mon', () {
      final c = CoachCheckinsLogic.effectiveCoverage('2026-08-10',
          previousWasCopied: true);
      expect((c.start, c.end), ('2026-08-06', '2026-08-10'));
    });

    test('previous Thursday NOT copied → Monday covers Mon→Mon', () {
      final c = CoachCheckinsLogic.effectiveCoverage('2026-08-10',
          previousWasCopied: false);
      expect((c.start, c.end), ('2026-08-03', '2026-08-10'));
    });

    test('Monday copied → Thursday covers Mon→Thu; not copied → Thu→Thu', () {
      expect(
          CoachCheckinsLogic.effectiveCoverage('2026-08-13',
              previousWasCopied: true).start,
          '2026-08-10');
      expect(
          CoachCheckinsLogic.effectiveCoverage('2026-08-13',
              previousWasCopied: false).start,
          '2026-08-06');
    });

    test('finalised-coverage clamp prevents overlapping windows', () {
      final c = CoachCheckinsLogic.effectiveCoverage('2026-08-10',
          previousWasCopied: false, lastFinalizedCoverageEnd: '2026-08-06');
      expect(c.start, '2026-08-06');
    });

    test('prior copy-state change recalculates an uncopied draft', () {
      var c = CoachCheckinsLogic.effectiveCoverage('2026-08-13',
          previousWasCopied: false);
      expect(c.start, '2026-08-06');
      c = CoachCheckinsLogic.effectiveCoverage('2026-08-13',
          previousWasCopied: true);
      expect(c.start, '2026-08-10');
    });
  });

  group('state machine guards', () {
    test('draft mutable while nothing newer finalised', () {
      expect(
          CoachCheckinsLogic.canMutate('2026-08-10', {
            '2026-08-10': CheckInStatus.draft,
            '2026-08-13': CheckInStatus.draft,
          }),
          isTrue);
    });

    test('older draft locked once a newer checkpoint is finalised', () {
      expect(
          CoachCheckinsLogic.canMutate('2026-08-10', {
            '2026-08-10': CheckInStatus.draft,
            '2026-08-13': CheckInStatus.copied,
          }),
          isFalse);
      expect(
          CoachCheckinsLogic.canMutate('2026-08-10', {
            '2026-08-10': CheckInStatus.copied,
            '2026-08-13': CheckInStatus.skipped,
          }),
          isFalse);
    });
  });

  group('authoritative checkpoint identity (coach timezone, not device)', () {
    test('server watermark key wins regardless of the device clock/timezone', () {
      // Coach timezone = Pacific/Auckland: the scheduler stamped Monday
      // 2026-08-10 as lastCheckpointKey. A device in e.g. America/Los_Angeles
      // still shows Sunday 2026-08-09 locally — the resolver must ignore that.
      const serverKey = '2026-08-10';
      final deviceStillSunday = DateTime(2026, 8, 9, 22, 30); // device-local
      expect(
        CoachCheckinsLogic.resolveCurrentCheckpointKey(
          serverLastCheckpointKey: serverKey,
          deviceNow: deviceStillSunday,
        ),
        serverKey,
      );

      // Reverse skew: a device already on Tuesday must not jump ahead of the
      // coach-timezone checkpoint either.
      final deviceAlreadyTuesday = DateTime(2026, 8, 11, 1, 0);
      expect(
        CoachCheckinsLogic.resolveCurrentCheckpointKey(
          serverLastCheckpointKey: serverKey,
          deviceNow: deviceAlreadyTuesday,
        ),
        serverKey,
      );
    });

    test('device fallback is used only when no server checkpoint exists yet', () {
      expect(
        CoachCheckinsLogic.resolveCurrentCheckpointKey(
          serverLastCheckpointKey: null,
          deviceNow: DateTime(2026, 8, 12),
        ),
        '2026-08-10',
      );
      // Malformed/non-checkpoint server values are rejected too.
      expect(
        CoachCheckinsLogic.resolveCurrentCheckpointKey(
          serverLastCheckpointKey: '2026-08-11', // a Tuesday — not a checkpoint
          deviceNow: DateTime(2026, 8, 12),
        ),
        '2026-08-10',
      );
      expect(
        CoachCheckinsLogic.resolveCurrentCheckpointKey(
          serverLastCheckpointKey: 'garbage',
          deviceNow: DateTime(2026, 8, 12),
        ),
        '2026-08-10',
      );
    });
  });

  group('copy UX: visible text is the frozen finalText once copied', () {
    test('copied report shows finalText — the exact string the server returned', () {
      expect(
        CoachCheckinsLogic.visibleMessageText(
          status: CheckInStatus.copied,
          finalText: 'Hey bro, final message 👍',
          previousWasCopied: false,
          draftIfPrevCopied: 'stale preview A',
          draftIfPrevNotCopied: 'stale preview B',
        ),
        'Hey bro, final message 👍',
      );
    });

    test('draft report shows the preview matching the live coverage state', () {
      expect(
        CoachCheckinsLogic.visibleMessageText(
          status: CheckInStatus.draft,
          finalText: null,
          previousWasCopied: true,
          draftIfPrevCopied: 'short-window draft',
          draftIfPrevNotCopied: 'long-window draft',
        ),
        'short-window draft',
      );
      expect(
        CoachCheckinsLogic.visibleMessageText(
          status: CheckInStatus.draft,
          finalText: null,
          previousWasCopied: false,
          draftIfPrevCopied: 'short-window draft',
          draftIfPrevNotCopied: 'long-window draft',
        ),
        'long-window draft',
      );
    });
  });

  group('weigh-in staleness', () {
    test('<3 days ok, 3 due, 4+ overdue, never overdue', () {
      expect(CoachCheckinsLogic.weighInStatus('2026-08-12', '2026-08-14'), 'ok');
      expect(CoachCheckinsLogic.weighInStatus('2026-08-11', '2026-08-14'), 'due');
      expect(
          CoachCheckinsLogic.weighInStatus('2026-08-10', '2026-08-14'), 'overdue');
      expect(CoachCheckinsLogic.weighInStatus(null, '2026-08-14'), 'overdue');
    });
  });

  group('E1RM parity pin (Dart PMU ↔ functions/coach/e1rm.js)', () {
    // These constants are asserted identically by the backend test suite
    // (functions/test/coach_pb_engine.test.js). If either side's formula
    // changes without the other, one of the two suites fails.
    test('Brzycki region matches backend constants (rir = 0)', () {
      expect(PeriodizationModelUtils.calculateE1RM(100, 5, 0), closeTo(112.5, 1e-9));
      expect(PeriodizationModelUtils.calculateE1RM(100, 1, 0), closeTo(100, 1e-9));
      expect(PeriodizationModelUtils.calculateE1RM(100, 10, 0),
          closeTo(100 * 36 / 27, 1e-9));
      expect(PeriodizationModelUtils.calculateE1RM(100, 25, 0), closeTo(300, 1e-9));
    });

    test('Epley region matches backend constants (rir = 0)', () {
      expect(PeriodizationModelUtils.calculateE1RM(100, 26, 0),
          closeTo(186.58, 1e-9));
    });
  });
}
