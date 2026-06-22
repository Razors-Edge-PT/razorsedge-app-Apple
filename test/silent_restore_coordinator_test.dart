import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/silent_restore_coordinator.dart';

/// Tests for the concurrency-critical cold-start silent-restore behaviour.
///
/// These drive the REAL utilities that `_AppRootState` delegates to
/// (`SharedRestoreAttempt`, `raceRestore`, `runAbandonAwareRestore`) — the same
/// code paths production uses — so the four required scenarios are exercised
/// without Firebase singletons.
void main() {
  group('SharedRestoreAttempt — two null events, one restore running', () {
    test('concurrent callers share ONE attempt and the later caller receives '
        'the SAME success (never a false null)', () async {
      final attempt = SharedRestoreAttempt<String>();
      var starts = 0;
      final exchange = Completer<String?>();

      Future<String?> start() {
        starts++;
        return exchange.future;
      }

      // Two cold-start null events both ask to restore while it is running.
      final f1 = attempt.run(start);
      final f2 = attempt.run(start);

      expect(starts, 1, reason: 'only the first caller starts the attempt');
      expect(identical(f1, f2), isTrue, reason: 'later caller shares the future');
      expect(attempt.isRunning, isTrue);

      exchange.complete('user-A');

      expect(await f1, 'user-A');
      expect(await f2, 'user-A',
          reason: 'a concurrent caller must NOT get null (false failure)');

      await Future<void>.delayed(Duration.zero); // let whenComplete run
      expect(attempt.isRunning, isFalse,
          reason: 'handle cleared only after genuine settle');
    });

    test('a fresh attempt starts only after the previous one settled', () async {
      final attempt = SharedRestoreAttempt<String>();
      var starts = 0;
      final first = Completer<String?>();

      final f1 = attempt.run(() {
        starts++;
        return first.future;
      });
      first.complete(null); // first attempt fails
      await f1;
      await Future<void>.delayed(Duration.zero);

      final f2 = attempt.run(() {
        starts++;
        return Future<String?>.value('user-B');
      });
      expect(starts, 2, reason: 'second attempt starts after first settled');
      expect(identical(f1, f2), isFalse);
      expect(await f2, 'user-B');
    });

    test('invalidate() drops the shared handle so a new attempt starts', () async {
      final attempt = SharedRestoreAttempt<String>();
      final inflight = Completer<String?>();
      final f1 = attempt.run(() => inflight.future);

      attempt.invalidate(); // e.g. explicit logout
      expect(attempt.isRunning, isFalse);

      var starts = 0;
      final f2 = attempt.run(() {
        starts++;
        return Future<String?>.value('fresh');
      });
      expect(starts, 1);
      expect(identical(f1, f2), isFalse);
      inflight.complete('stale'); // the abandoned in-flight still settles
      expect(await f2, 'fresh');
    });
  });

  group('raceRestore — native fails while shared google succeeds', () {
    test('native null + google user → google user wins', () async {
      var googleWon = false;
      final result = await raceRestore<String>(
        native: Future<String?>.value(null),
        google: Future<String?>.value('google-user'),
        budget: const Duration(seconds: 10),
        onGoogleWon: () => googleWon = true,
      );
      expect(result, 'google-user');
      expect(googleWon, isTrue);
    });

    test('shared google lane delivers the user to BOTH concurrent races',
        () async {
      final attempt = SharedRestoreAttempt<String>();
      final exchange = Completer<String?>();
      Future<String?> google() => attempt.run(() => exchange.future);

      final r1 = raceRestore<String>(
        native: Future<String?>.value(null),
        google: google(),
        budget: const Duration(seconds: 10),
      );
      final r2 = raceRestore<String>(
        native: Future<String?>.value(null),
        google: google(),
        budget: const Duration(seconds: 10),
      );

      exchange.complete('shared-user');
      expect(await r1, 'shared-user');
      expect(await r2, 'shared-user');
    });

    test('first valid native wins even if google never settles', () async {
      var nativeWon = false;
      final result = await raceRestore<String>(
        native: Future<String?>.value('native-user'),
        google: Completer<String?>().future, // never completes
        budget: const Duration(seconds: 10),
        onNativeWon: () => nativeWon = true,
      );
      expect(result, 'native-user');
      expect(nativeWon, isTrue);
    });

    test('both lanes failing completes null via lane settlement', () async {
      final result = await raceRestore<String>(
        native: Future<String?>.value(null),
        google: Future<String?>.value(null),
        budget: const Duration(seconds: 10),
      );
      expect(result, isNull);
    });

    test('native-only lane failure completes null', () async {
      final result = await raceRestore<String>(
        native: Future<String?>.value(null),
        budget: const Duration(seconds: 10),
      );
      expect(result, isNull);
    });
  });

  group('raceRestore — credential completion AFTER the failure budget', () {
    test('a late google success after the budget elapsed still wins '
        '(never routes to Login while google is pending)', () async {
      final google = Completer<String?>();
      final f = raceRestore<String>(
        native: Future<String?>.value(null), // native fails fast
        google: google.future, // still pending across the budget
        budget: const Duration(milliseconds: 20),
      );

      // Let the budget elapse while the credential exchange is still running.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // The native credential completes LATE, after the budget.
      google.complete('late-user');

      // If the budget had wrongly completed null, this would be null.
      expect(await f, 'late-user');
    });

    test('budget DOES complete null once the google lane has settled failure',
        () async {
      final google = Completer<String?>();
      final f = raceRestore<String>(
        native: Future<String?>.value(null),
        google: google.future,
        budget: const Duration(milliseconds: 20),
      );
      // Google settles as a failure before the budget fires.
      google.complete(null);
      expect(await f, isNull);
    });
  });

  group('runAbandonAwareRestore — explicit logout during restoration', () {
    test('logout landing DURING the exchange signs out the late completion and '
        'reports failure (never silently signs back in)', () async {
      var signOutCalls = 0;
      // (1) pre=false, (3) preCred=false, (5) post=true.
      final responses = <bool>[false, false, true];
      var i = 0;
      var exchanged = false;

      final result = await runAbandonAwareRestore<String, String>(
        isExplicitLogout: () async => responses[i++],
        acquire: () async => 'credential',
        exchange: (c) async {
          exchanged = true;
          return 'late-user';
        },
        signOutLateCompletion: () async => signOutCalls++,
      );

      expect(exchanged, isTrue, reason: 'genuine exchange ran to completion');
      expect(result, isNull, reason: 'abandoned → reported failure');
      expect(signOutCalls, 1, reason: 'late completion signed back out');
    });

    test('logout BEFORE the credential exchange → exchange never starts',
        () async {
      var exchangeCalls = 0;
      final responses = <bool>[false, true]; // (1) false, (3) true
      var i = 0;

      final result = await runAbandonAwareRestore<String, String>(
        isExplicitLogout: () async => responses[i++],
        acquire: () async => 'credential',
        exchange: (c) async {
          exchangeCalls++;
          return 'user';
        },
        signOutLateCompletion: () async {},
      );

      expect(result, isNull);
      expect(exchangeCalls, 0);
    });

    test('logout BEFORE starting → acquire never runs', () async {
      var acquireCalls = 0;
      final result = await runAbandonAwareRestore<String, String>(
        isExplicitLogout: () async => true, // (1) true
        acquire: () async {
          acquireCalls++;
          return 'credential';
        },
        exchange: (c) async => 'user',
        signOutLateCompletion: () async {},
      );
      expect(result, isNull);
      expect(acquireCalls, 0);
    });

    test('clean restore (no logout) returns the user and never signs out',
        () async {
      var signOutCalls = 0;
      final result = await runAbandonAwareRestore<String, String>(
        isExplicitLogout: () async => false,
        acquire: () async => 'credential',
        exchange: (c) async => 'user-OK',
        signOutLateCompletion: () async => signOutCalls++,
      );
      expect(result, 'user-OK');
      expect(signOutCalls, 0);
    });

    test('no cached account (acquire null) → exchange skipped, returns null',
        () async {
      var exchangeCalls = 0;
      final result = await runAbandonAwareRestore<String, String>(
        isExplicitLogout: () async => false,
        acquire: () async => null,
        exchange: (c) async {
          exchangeCalls++;
          return 'user';
        },
        signOutLateCompletion: () async {},
      );
      expect(result, isNull);
      expect(exchangeCalls, 0);
    });
  });
}
