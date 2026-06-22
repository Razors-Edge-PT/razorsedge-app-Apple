import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';

/// Exercises the REAL [Wes2SetRow] production widget. This is the exact
/// mechanism `Wes2Screen._exitToHome` relies on: dropping focus
/// (FocusManager.primaryFocus.unfocus) must fire the field's focus-loss
/// listener, which invokes onFieldUnfocused exactly once with the latest text,
/// while dismissing the keyboard. These tests assert that contract per field.
void main() {
  /// Records every onFieldUnfocused callback the production widget emits.
  late List<({Wes2FieldKey key, String text})> unfocusCalls;

  Future<void> pumpRow(
    WidgetTester tester, {
    bool showVelocity = false,
  }) async {
    unfocusCalls = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wes2SetRow(
            set: const Wes2SetState(setIndex: 0),
            showVelocity: showVelocity,
            onFieldChanged: (_, __) {},
            onFieldUnfocused: (key, text) =>
                unfocusCalls.add((key: key, text: text)),
          ),
        ),
      ),
    );
  }

  // Field order in normal mode: weight(0), reps(1), rir(2), velocity(3).
  Finder fieldAt(int i) => find.byType(TextField).at(i);

  // Mirrors production _exitToHome: drop the primary focus.
  Future<void> dropFocus(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  testWidgets('Weight: focus + type + unfocus fires callback once with value',
      (tester) async {
    await pumpRow(tester);
    await tester.enterText(fieldAt(0), '102.5');
    expect(tester.testTextInput.isVisible, isTrue);

    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.weight);
    expect(unfocusCalls.single.text, '102.5');
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Reps: focus + type + unfocus fires callback once with value',
      (tester) async {
    await pumpRow(tester);
    await tester.enterText(fieldAt(1), '5');
    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.reps);
    expect(unfocusCalls.single.text, '5');
  });

  testWidgets('RIR: focus + type + unfocus fires callback once with value',
      (tester) async {
    await pumpRow(tester);
    await tester.enterText(fieldAt(2), '2');
    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.rir);
    expect(unfocusCalls.single.text, '2');
  });

  testWidgets('Velocity: focus + type + unfocus fires callback once with value',
      (tester) async {
    await pumpRow(tester, showVelocity: true);
    await tester.enterText(fieldAt(3), '0.45');
    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.velocity);
    expect(unfocusCalls.single.text, '0.45');
  });

  testWidgets('Latest valid typed value reaches the callback', (tester) async {
    await pumpRow(tester);
    await tester.enterText(fieldAt(0), '100');
    await tester.enterText(fieldAt(0), '102'); // edited before exit
    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.text, '102');
  });

  testWidgets('Cleared field reaches the callback as blank', (tester) async {
    await pumpRow(tester);
    await tester.enterText(fieldAt(0), '100');
    await tester.enterText(fieldAt(0), ''); // clear before exit
    await dropFocus(tester);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.weight);
    expect(unfocusCalls.single.text, ''); // blank → production saves null
  });

  testWidgets('No focused field generates no save callback', (tester) async {
    await pumpRow(tester);
    // Never focus any field.
    await dropFocus(tester);
    expect(unfocusCalls, isEmpty);
  });
}
