// The Sex / Gender selector's choices (lib/sex_options.dart): the user sees
// Male / Female / Yes. in onboarding and Settings alike, while the stored
// values stay M / F / N. "Robot" is never offered.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/sex_options.dart';

/// The selector as both screens build it: items from [kSexOptionLabels].
class _Selector extends StatefulWidget {
  const _Selector({required this.stored, required this.onSaved});

  final String? stored;
  final ValueChanged<String?> onSaved;

  @override
  State<_Selector> createState() => _SelectorState();
}

class _SelectorState extends State<_Selector> {
  late String? _sex = widget.stored;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: _sex,
      items: <DropdownMenuItem<String>>[
        for (final MapEntry<String, String> option in kSexOptionLabels.entries)
          DropdownMenuItem<String>(
              value: option.key, child: Text(option.value)),
      ],
      onChanged: (String? v) {
        setState(() => _sex = v);
        widget.onSaved(v);
      },
    );
  }
}

void main() {
  test('the choices are exactly Male, Female, Yes. over M, F, N', () {
    expect(kSexOptionLabels.keys.toList(), <String>['M', 'F', 'N']);
    expect(
        kSexOptionLabels.values.toList(), <String>['Male', 'Female', 'Yes.']);
    expect(kSexOptionLabels['N'], 'Yes.', reason: 'with its full stop');
    expect(
        kSexOptionLabels.values
            .any((String l) => l.toLowerCase().contains('robot')),
        isFalse);
  });

  testWidgets('a stored N shows as "Yes."; the open list is Male, Female, Yes.',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _Selector(stored: 'N', onSaved: (_) {}))));
    expect(find.text('Yes.'), findsOneWidget);
    expect(find.text('Robot'), findsNothing);

    await tester.tap(find.text('Yes.'));
    await tester.pumpAndSettle();
    expect(find.text('Male'), findsWidgets);
    expect(find.text('Female'), findsWidgets);
    expect(find.text('Yes.'), findsWidgets);
    expect(find.text('Robot'), findsNothing);
    final Iterable<String?> shown = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data)
        .toSet();
    expect(shown, <String?>{'Male', 'Female', 'Yes.'});
  });

  testWidgets('choosing "Yes." still saves N; Male and Female save M and F',
      (WidgetTester tester) async {
    final List<String?> saved = <String?>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _Selector(stored: 'M', onSaved: saved.add))));
    Future<void> choose(String shown, String label) async {
      await tester.tap(find.text(shown));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('Male', 'Yes.');
    await choose('Yes.', 'Female');
    await choose('Female', 'Male');
    expect(saved, <String?>['N', 'F', 'M']);
  });

  group('screens', () {
    final String settings = File('lib/user_settings.dart').readAsStringSync();
    final String onboarding =
        File('lib/create_new_account_screen.dart').readAsStringSync();

    test('Settings and onboarding both build their items from the shared map',
        () {
      for (final String src in <String>[settings, onboarding]) {
        expect(src, contains("import 'sex_options.dart';"));
        expect('kSexOptionLabels.entries'.allMatches(src).length, 1);
        // No private copy of the labels left to drift.
        expect(src, isNot(contains("Text('Male'")));
        expect(src, isNot(contains("Text('Female'")));
        expect(src, isNot(contains("Text('Yes.'")));
      }
    });

    test('Settings still loads and saves the stored value untouched', () {
      expect(settings, contains("_sex = (d['sex'] as String?) ?? 'N';"));
      expect(settings, contains("'sex': sex,"));
    });

    test('no screen offers the word Robot', () {
      final Iterable<File> sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'));
      final RegExp robot = RegExp(r'\brobot\b', caseSensitive: false);
      for (final File f in sources) {
        expect(robot.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
      }
    });
  });
}
