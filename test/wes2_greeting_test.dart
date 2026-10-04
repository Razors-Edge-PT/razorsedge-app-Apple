import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_widgets/wes2_greeting.dart';

void main() {
  group('WES2 greeting from profile.gender', () {
    test('male and its existing aliases → king', () {
      for (final String g in <String>['male', 'Male', ' MALE ', 'man', 'Man', 'boy']) {
        expect(wes2GreetingForGender(g), 'Welcome king', reason: g);
      }
    });

    test('female and its existing aliases → queen', () {
      for (final String g in <String>['female', 'Female', ' FEMALE ', 'woman', 'girl']) {
        expect(wes2GreetingForGender(g), 'Welcome queen', reason: g);
      }
    });

    test('non-binary, neutral, custom and other selections → sovereign', () {
      for (final String g in <String>[
        'non-binary',
        'Nonbinary',
        'nb',
        'genderqueer',
        'agender',
        'gender neutral',
        'two-spirit',
        'other',
        'Other',
        'custom',
        'X',
        'N',
      ]) {
        expect(wes2GreetingForGender(g), 'Welcome sovereign', reason: g);
      }
    });

    test('unknown / legacy values are never assumed to be king or queen', () {
      for (final String g in <String>['m', 'f', 'M', 'F', 'males', 'femme', 'king', 'queen']) {
        expect(wes2GreetingForGender(g), 'Welcome sovereign', reason: g);
      }
    });

    test('null, missing, blank, non-string or "prefer not to say" → plain Welcome', () {
      expect(wes2GreetingForGender(null), 'Welcome');
      expect(wes2GreetingForGender(''), 'Welcome');
      expect(wes2GreetingForGender('   '), 'Welcome');
      expect(wes2GreetingForGender(1), 'Welcome');
      expect(wes2GreetingForGender(<String, dynamic>{}), 'Welcome');
      expect(wes2GreetingForGender('Prefer not to say'), 'Welcome');
    });

    test('existing capitalisation is unchanged', () {
      expect(kWes2GreetingKing, 'Welcome king');
      expect(kWes2GreetingQueen, 'Welcome queen');
      expect(kWes2GreetingSovereign, 'Welcome sovereign');
      expect(kWes2GreetingDefault, 'Welcome');
    });
  });

  testWidgets('the greeting is shown verbatim as a single Text', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Text(wes2GreetingForGender('non-binary'))),
    ));
    expect(find.text('Welcome sovereign'), findsOneWidget);
  });
}
