// Coverage for the GoodLift signup form's validation rules and DOB handling.
//
// These pin the rules that CreateNewAccountScreen delegates to, including the
// PERSISTED date-of-birth format (dd-mm-yyyy), which must not change.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup_validation.dart';

void main() {
  group('username', () {
    test('required', () {
      expect(validateUsername(null), 'Choose a username.');
      expect(validateUsername(''), 'Choose a username.');
      expect(validateUsername('   '), 'Choose a username.');
    });

    test('3–22 character rule is preserved', () {
      expect(validateUsername('ab'), 'Use 3–22 characters.');
      expect(validateUsername('abc'), isNull);
      expect(validateUsername('a' * 22), isNull);
      expect(validateUsername('a' * 23), 'Use 3–22 characters.');
    });

    test('no-spaces rule is preserved and reported specifically', () {
      expect(validateUsername('john doe'), "Usernames can't contain spaces.");
      // A spaced value that is also the wrong length still names the space,
      // which is the actionable problem.
      expect(validateUsername('a b'), "Usernames can't contain spaces.");
    });

    test('availability only errors on a definite "taken"', () {
      expect(usernameAvailabilityError(false),
          "That username's already taken — try another.");
      expect(usernameAvailabilityError(true), isNull);
      // null = check has not run or failed; never blocks on its own.
      expect(usernameAvailabilityError(null), isNull);
    });
  });

  group('full name', () {
    test('required, and nothing more', () {
      expect(validateFullName(''), 'Enter your name.');
      expect(validateFullName('   '), 'Enter your name.');
      // Deliberately no first/last-name rule.
      expect(validateFullName('Cher'), isNull);
      expect(validateFullName('Te Rangi'), isNull);
      expect(validateFullName("O'Brien-Smith"), isNull);
    });
  });

  group('email', () {
    test('required', () {
      expect(validateEmail(''), 'Enter your email.');
      expect(validateEmail(null), 'Enter your email.');
    });

    test('format', () {
      const bad = "That doesn't look like a valid email address.";
      expect(validateEmail('nope'), bad);
      expect(validateEmail('nope@'), bad);
      expect(validateEmail('nope@example'), bad);
      expect(validateEmail('@example.com'), bad);
    });

    test('accepts what the original regex accepted', () {
      expect(validateEmail('a@b.co'), isNull);
      expect(validateEmail('first.last+tag@example.co.nz'), isNull);
      expect(validateEmail('  trimmed@example.com  '), isNull);
    });
  });

  group('password', () {
    test('required', () {
      expect(validatePassword(''), 'Enter a password.');
    });

    test('minimum length rule is preserved at 6', () {
      expect(validatePassword('12345'), 'Password needs at least 6 characters.');
      expect(validatePassword('123456'), isNull);
      expect(kPasswordMinLength, 6);
    });
  });

  group('confirm password', () {
    test('must match', () {
      expect(validateConfirmPassword('abc123', 'abc124'),
          "Those passwords don't match yet.");
      expect(validateConfirmPassword('abc123', 'abc123'), isNull);
    });

    test('empty confirm asks for re-entry rather than "no match"', () {
      expect(validateConfirmPassword('', 'abc123'), 'Re-enter your password.');
    });

    test('changing the password invalidates a previously matching confirm', () {
      const confirm = 'abc123';
      expect(validateConfirmPassword(confirm, 'abc123'), isNull);
      // User edits the password field afterwards:
      expect(validateConfirmPassword(confirm, 'abc1234'),
          "Those passwords don't match yet.");
    });
  });

  group('sex', () {
    test('required — it gates the demographics-complete check downstream', () {
      expect(validateSex(null), 'Select an option.');
      expect(validateSex(''), 'Select an option.');
    });

    test('existing option values are unchanged and all accepted', () {
      for (final v in ['M', 'F', 'N']) {
        expect(validateSex(v), isNull, reason: 'option $v');
      }
    });
  });

  group('date of birth', () {
    final now = DateTime(2026, 8, 25);

    test('required', () {
      expect(validateDob(null, now: now), 'Select your date of birth.');
    });

    test('future dates keep the playful message', () {
      expect(validateDob(DateTime(2026, 8, 26), now: now),
          'No time travelers yet 😉');
      expect(validateDob(DateTime(2030, 1, 1), now: now),
          'No time travelers yet 😉');
    });

    test('today is allowed (boundary)', () {
      expect(validateDob(DateTime(2026, 8, 25), now: now), isNull);
    });

    test('implausibly old dates keep the playful message', () {
      expect(validateDob(DateTime(1800, 1, 1), now: now),
          'I call BS! you are not that old.');
      expect(validateDob(DateTime(1899, 12, 31), now: now),
          'I call BS! you are not that old.');
      // Just outside the 120-year window.
      expect(validateDob(DateTime(1906, 8, 24), now: now),
          'I call BS! you are not that old.');
    });

    test('the 120-year boundary itself is accepted', () {
      expect(validateDob(DateTime(1906, 8, 25), now: now), isNull);
      expect(kMaxPlausibleAgeYears, 120);
    });

    test('ordinary dates pass', () {
      expect(validateDob(DateTime(1991, 8, 25), now: now), isNull);
      expect(validateDob(DateTime(1970, 2, 28), now: now), isNull);
    });
  });

  group('DOB storage format (must not change)', () {
    test('stores dd-mm-yyyy, zero-padded', () {
      expect(formatDobForStorage(DateTime(1991, 8, 25)), '25-08-1991');
      expect(formatDobForStorage(DateTime(2001, 1, 2)), '02-01-2001');
      expect(formatDobForStorage(DateTime(1999, 12, 31)), '31-12-1999');
    });

    test('matches what the original _normalizeDob produced', () {
      // _normalizeDob('25-08-1991') returned '25-08-1991'.
      expect(formatDobForStorage(DateTime(1991, 8, 25)), '25-08-1991');
      // Round-trips through the stored form unchanged.
      final stored = formatDobForStorage(DateTime(1991, 8, 25));
      expect(formatDobForStorage(parseStoredDob(stored)!), stored);
    });
  });

  group('DOB display format', () {
    test('is unambiguous, e.g. 25 Aug 1991', () {
      expect(formatDobForDisplay(DateTime(1991, 8, 25)), '25 Aug 1991');
      expect(formatDobForDisplay(DateTime(2000, 1, 1)), '1 Jan 2000');
      expect(formatDobForDisplay(DateTime(1985, 12, 9)), '9 Dec 1985');
    });

    test('a day/month ambiguity cannot be misread', () {
      // 03-04 would be ambiguous; the named month resolves it.
      expect(formatDobForDisplay(DateTime(1990, 4, 3)), '3 Apr 1990');
    });

    test('every month renders', () {
      for (int m = 1; m <= 12; m++) {
        final out = formatDobForDisplay(DateTime(1990, m, 15));
        expect(out.startsWith('15 '), isTrue);
        expect(out.endsWith(' 1990'), isTrue);
      }
    });
  });

  group('parsing stored DOB', () {
    test('reads the persisted dd-mm-yyyy form', () {
      expect(parseStoredDob('25-08-1991'), DateTime(1991, 8, 25));
    });

    test('tolerates the legacy ISO form', () {
      expect(parseStoredDob('1991-08-25'), DateTime(1991, 8, 25));
    });

    test('rejects impossible dates such as 31 February', () {
      expect(parseStoredDob('31-02-1990'), isNull);
      expect(parseStoredDob('30-02-1990'), isNull);
      expect(parseStoredDob('32-01-1990'), isNull);
      expect(parseStoredDob('01-13-1990'), isNull);
    });

    test('accepts a real leap day and rejects a fake one', () {
      expect(parseStoredDob('29-02-2000'), DateTime(2000, 2, 29));
      expect(parseStoredDob('29-02-1900'), isNull); // 1900 was not a leap year
    });

    test('rejects junk', () {
      expect(parseStoredDob(null), isNull);
      expect(parseStoredDob(''), isNull);
      expect(parseStoredDob('not a date'), isNull);
      expect(parseStoredDob('1-2-1990'), isNull); // unpadded is not the format
    });
  });

  group('the picker cannot produce an invalid calendar date', () {
    test('every date the wheel can yield validates as a real date', () {
      // The wheel only ever emits real DateTimes, so the round-trip through
      // storage must always survive. Spot-check month ends across a leap year.
      for (final d in [
        DateTime(2000, 2, 29),
        DateTime(2001, 2, 28),
        DateTime(1999, 4, 30),
        DateTime(1999, 12, 31),
      ]) {
        final stored = formatDobForStorage(d);
        expect(parseStoredDob(stored), d, reason: stored);
      }
    });
  });
}
