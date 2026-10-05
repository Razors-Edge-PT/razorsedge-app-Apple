import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_widgets/wes2_greeting.dart';

const String _king = 'Welcome king';
const String _queen = 'Welcome queen';
const String _sovereign = 'Welcome sovereign';
const String _plain = 'Welcome';

/// A `users/{uid}` document as the WES2 header fetches it. A null argument
/// leaves that field out of the document altogether.
Map<String, dynamic> _userDoc({Object? sex, Object? gender}) => <String, dynamic>{
      'username': 'athlete',
      if (sex != null) 'sex': sex,
      if (gender != null) 'profile': <String, dynamic>{'gender': gender},
    };

/// functions/showcase/re_points.js `scoringSexOf`, mirrored for the matrix.
/// The source itself is pinned in the 'scoring' group below.
String _scoringSexOf(Object? raw) =>
    raw is String && raw.trim().toUpperCase() == 'F' ? 'female' : 'male';

void main() {
  group('WES2 greeting matrix (sex | gender | greeting | points)', () {
    const List<List<String?>> matrix = <List<String?>>[
      <String?>['M', null, _king, 'male'],
      <String?>['F', null, _queen, 'female'],
      <String?>['N', null, _sovereign, 'male'],
      <String?>['M', 'female', _queen, 'male'],
      <String?>['F', 'male', _king, 'female'],
      <String?>['M', 'prefer not to say', _sovereign, 'male'],
      <String?>['F', 'prefer not to say', _sovereign, 'female'],
      <String?>['N', 'male', _sovereign, 'male'],
      <String?>['N', 'female', _sovereign, 'male'],
    ];

    for (final List<String?> row in matrix) {
      final String? sex = row[0];
      final String? gender = row[1];
      test('sex=$sex gender=${gender ?? 'absent'} → ${row[2]}, ${row[3]} points', () {
        expect(wes2GreetingFor(sex: sex, gender: gender), row[2]);
        expect(wes2GreetingForUserDoc(_userDoc(sex: sex, gender: gender)), row[2]);
        // Points follow sex alone, whatever the gender says.
        expect(_scoringSexOf(sex), row[3]);
      });
    }
  });

  group('WES2 greeting resolver', () {
    test('an explicit non-male/female sex → sovereign, whatever the gender', () {
      for (final String sex in <String>['N', 'n', ' N ', 'Yes', 'Yes.', 'Robot', 'other', 'X']) {
        for (final String? gender in <String?>[null, '', 'male', 'female', 'Woman']) {
          expect(wes2GreetingFor(sex: sex, gender: gender), _sovereign,
              reason: 'sex=$sex gender=$gender');
        }
      }
    });

    test('an explicit non-male/female gender → sovereign, whatever the sex', () {
      for (final String gender in <String>[
        'prefer not to say',
        'Prefer not to say',
        'prefer not to answer',
        'rather not say',
        'non-binary',
        'Nonbinary',
        'nb',
        'genderqueer',
        'agender',
        'gender neutral',
        'neutral',
        'two-spirit',
        'other',
        'Other',
        'custom',
        'Yes.',
        'Robot',
        'N',
        'males',
        'king',
        'queen',
      ]) {
        for (final String? sex in <String?>[null, '', 'M', 'F', 'N']) {
          expect(wes2GreetingFor(sex: sex, gender: gender), _sovereign,
              reason: 'sex=$sex gender=$gender');
        }
      }
    });

    test('male/female gender, its aliases, case and whitespace', () {
      for (final String g in <String>['male', 'Male', ' MALE ', 'man', 'Man', 'boy', 'm', 'M']) {
        expect(wes2GreetingFor(gender: g), _king, reason: g);
        expect(wes2GreetingFor(sex: 'F', gender: g), _king, reason: 'F+$g');
      }
      for (final String g in <String>['female', 'Female', ' FEMALE ', 'woman', 'girl', 'f', 'F']) {
        expect(wes2GreetingFor(gender: g), _queen, reason: g);
        expect(wes2GreetingFor(sex: 'M', gender: g), _queen, reason: 'M+$g');
      }
    });

    test('sex M/F is used when gender is not a selection', () {
      for (final Object? gender in <Object?>[null, '', '   ', 7, <String>[]]) {
        for (final String sex in <String>['M', 'm', ' M ', 'male', 'Male']) {
          expect(wes2GreetingFor(sex: sex, gender: gender), _king, reason: '$sex/$gender');
        }
        for (final String sex in <String>['F', 'f', ' f ', 'female', 'FEMALE']) {
          expect(wes2GreetingFor(sex: sex, gender: gender), _queen, reason: '$sex/$gender');
        }
      }
    });

    test('missing sex with an explicit male/female gender', () {
      for (final Object? sex in <Object?>[null, '', '  ']) {
        expect(wes2GreetingFor(sex: sex, gender: 'male'), _king);
        expect(wes2GreetingFor(sex: sex, gender: 'female'), _queen);
      }
    });

    test('neither field supplies a selection → plain Welcome', () {
      expect(wes2GreetingFor(), _plain);
      for (final Object? sex in <Object?>[null, '', '   ']) {
        for (final Object? gender in <Object?>[null, '', '   ']) {
          expect(wes2GreetingFor(sex: sex, gender: gender), _plain);
        }
      }
    });

    test('malformed values are not selections and never throw', () {
      final List<Object?> malformed = <Object?>[
        1,
        2.5,
        true,
        <String>['M'],
        <String, dynamic>{'value': 'F'},
        Object(),
      ];
      for (final Object? a in malformed) {
        for (final Object? b in malformed) {
          expect(wes2GreetingFor(sex: a, gender: b), _plain);
        }
        expect(wes2GreetingFor(sex: a, gender: 'female'), _queen);
        expect(wes2GreetingFor(sex: 'M', gender: a), _king);
        expect(wes2GreetingFor(sex: 'N', gender: a), _sovereign);
      }
    });

    test('existing capitalisation is unchanged', () {
      expect(kWes2GreetingKing, 'Welcome king');
      expect(kWes2GreetingQueen, 'Welcome queen');
      expect(kWes2GreetingSovereign, 'Welcome sovereign');
      expect(kWes2GreetingDefault, 'Welcome');
    });
  });

  group('WES2 greeting from the fetched user document', () {
    test('reads sex and profile.gender from the one document', () {
      expect(wes2GreetingForUserDoc(_userDoc(sex: 'M')), _king);
      expect(wes2GreetingForUserDoc(_userDoc(sex: 'F')), _queen);
      expect(wes2GreetingForUserDoc(_userDoc(sex: 'N')), _sovereign);
      expect(wes2GreetingForUserDoc(_userDoc(sex: 'M', gender: 'female')), _queen);
      expect(wes2GreetingForUserDoc(_userDoc(gender: 'male')), _king);
      expect(wes2GreetingForUserDoc(_userDoc(gender: 'Prefer not to say')), _sovereign);
    });

    test('empty and malformed documents → plain Welcome, no throw', () {
      expect(wes2GreetingForUserDoc(<String, dynamic>{}), _plain);
      expect(wes2GreetingForUserDoc(<String, dynamic>{'profile': null}), _plain);
      expect(wes2GreetingForUserDoc(<String, dynamic>{'profile': 'male'}), _plain);
      expect(wes2GreetingForUserDoc(<String, dynamic>{'profile': <String>['male']}), _plain);
      expect(wes2GreetingForUserDoc(<String, dynamic>{'sex': 3, 'profile': <String, dynamic>{}}),
          _plain);
      expect(
          wes2GreetingForUserDoc(<String, dynamic>{
            'sex': null,
            'profile': <String, dynamic>{'gender': 12},
          }),
          _plain);
      // A profile map that is not Map<String, dynamic> is still read.
      expect(
          wes2GreetingForUserDoc(<String, dynamic>{
            'sex': 'M',
            'profile': <Object?, Object?>{'gender': 'female'},
          }),
          _queen);
    });
  });

  group('WES2 header wiring', () {
    final String screen = File('lib/WES2_screen.dart').readAsStringSync();
    final int start = screen.indexOf('Future<void> _fetchAthleteUsername(');
    final String fetch = screen.substring(start, screen.indexOf('void initState()', start));

    test('the header resolves the greeting from the whole fetched user doc', () {
      expect(start, greaterThan(0));
      expect(fetch, contains('final data = doc.data() ?? {};'));
      expect(fetch, contains('wes2GreetingForUserDoc(data)'));
      expect(fetch, contains('_athleteGreeting = greeting;'));
      // The only greeting entry point used anywhere in the screen.
      expect('wes2Greeting'.allMatches(screen).length, 1);
    });

    test('still one user-document read, no listener or write', () {
      expect('.get()'.allMatches(fetch).length, 1);
      expect(fetch, isNot(contains('.snapshots(')));
      expect(fetch, isNot(contains('.set(')));
      expect(fetch, isNot(contains('.update(')));
    });
  });

  group('scoring still reads sex only', () {
    test('scoringSexOf is unchanged: F → female, everything else → male', () {
      final String src = File('functions/showcase/re_points.js').readAsStringSync();
      expect(
          src,
          contains("return typeof raw === 'string' && raw.trim().toUpperCase() === 'F' "
              '? Sex.FEMALE : Sex.MALE;'));
      for (final Object? sex in <Object?>['M', 'N', 'Yes.', 'Robot', '', null, 3]) {
        expect(_scoringSexOf(sex), 'male', reason: '$sex');
      }
      for (final String sex in <String>['F', 'f', ' F ']) {
        expect(_scoringSexOf(sex), 'female', reason: sex);
      }
    });

    test('no scoring or leaderboard source mentions gender', () {
      for (final String dir in <String>['functions/showcase', 'functions/leaderboard']) {
        final Iterable<File> sources = Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.js'));
        expect(sources, isNotEmpty, reason: dir);
        for (final File f in sources) {
          expect(f.readAsStringSync().toLowerCase(), isNot(contains('gender')), reason: f.path);
        }
      }
    });
  });

  testWidgets('the greeting is shown verbatim as a single Text', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Text(wes2GreetingFor(sex: 'N'))),
    ));
    expect(find.text('Welcome sovereign'), findsOneWidget);
  });
}
