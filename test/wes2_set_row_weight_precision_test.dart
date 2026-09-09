import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';

/// Display-precision cover for the WES2 set row's exercise-WEIGHT field.
///
/// Before this fix `_fmtWeight` was
///   v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)
/// so a legitimately configured candidate such as 16.25 kg (primary 2.5 +
/// secondary 1.25) rendered as "16.3". The stored double was always correct —
/// only the visible text lost precision. The formatter now preserves up to 3
/// decimals and strips trailing zeros, matching the existing velocity style.
///
/// These render the real [Wes2SetRow] widget rather than poking a private
/// helper, and separately pin that RIR and E1RM formatting are untouched.

Widget _harness(Wes2SetState set, {String? uid, DateTime? date}) {
  return MaterialApp(
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wes2SetRow(
            set: set,
            showVelocity: false,
            entryMode: Wes2ExerciseEntryMode.normal,
            onFieldChanged: (_, __) {},
            onFieldUnfocused: (_, __) {},
            onNoteTap: () {},
            onVideoTap: () {},
            uid: uid,
            selectedDate: date,
          ),
        ],
      ),
    ),
  );
}

Wes2SetState _withWeightHint(double v) => Wes2SetState(
      setIndex: 0,
      weight: Wes2FieldState<double>(
        hintValue: v,
        hintOrigin: FieldOrigin.modelHint,
      ),
    );

Wes2SetState _withWeightActual(double v) => Wes2SetState(
      setIndex: 0,
      weight: Wes2FieldState<double>(
        actualValue: v,
        origin: FieldOrigin.typed,
      ),
    );

void main() {
  group('weight hint precision', () {
    final cases = <double, String>{
      16.0: '16',
      16.5: '16.5',
      16.25: '16.25',
      16.125: '16.125',
      245.0: '245',
      247.5: '247.5',
      268.75: '268.75',
      100.5: '100.5',
    };

    cases.forEach((value, expected) {
      testWidgets('hint $value renders "$expected"', (tester) async {
        await tester.pumpWidget(_harness(_withWeightHint(value)));
        await tester.pump();

        expect(find.text(expected), findsOneWidget);
        // The lossy one-decimal rounding must be gone.
        if (expected == '16.25') {
          expect(find.text('16.3'), findsNothing);
        }
      });
    });

    testWidgets('float artefact 16.249999999999996 renders "16.25"',
        (tester) async {
      await tester.pumpWidget(_harness(_withWeightHint(16.249999999999996)));
      await tester.pump();

      expect(find.text('16.25'), findsOneWidget);
      expect(find.text('16.3'), findsNothing);
      expect(find.text('16.25000'), findsNothing);
    });
  });

  group('weight actual precision', () {
    testWidgets('actual 16.25 renders "16.25" in the field', (tester) async {
      await tester.pumpWidget(_harness(_withWeightActual(16.25)));
      await tester.pump();

      expect(find.text('16.25'), findsOneWidget);
      expect(find.text('16.3'), findsNothing);
    });

    testWidgets('actual 16.0 renders "16" (no trailing ".0")', (tester) async {
      await tester.pumpWidget(_harness(_withWeightActual(16.0)));
      await tester.pump();

      expect(find.text('16'), findsOneWidget);
      expect(find.text('16.0'), findsNothing);
    });

    testWidgets('actual 247.5 renders "247.5"', (tester) async {
      await tester.pumpWidget(_harness(_withWeightActual(247.5)));
      await tester.pump();
      expect(find.text('247.5'), findsOneWidget);
    });
  });

  testWidgets(
      'moving from a 16.25 hint to an explicit 16.25 actual keeps the text',
      (tester) async {
    // Start: hint only. Field shows the hint placeholder "16.25".
    await tester.pumpWidget(_harness(_withWeightHint(16.25)));
    await tester.pump();
    expect(find.text('16.25'), findsOneWidget);

    // Same row rebuilt with 16.25 now an actual (didUpdateWidget → _sync).
    await tester.pumpWidget(_harness(_withWeightActual(16.25)));
    await tester.pump();

    expect(find.text('16.25'), findsOneWidget);
    expect(find.text('16.3'), findsNothing);
  });

  group('unrelated formatters are untouched', () {
    testWidgets('RIR hint 2.0 still renders "2.0" (one decimal)',
        (tester) async {
      await tester.pumpWidget(_harness(const Wes2SetState(
        setIndex: 0,
        rir: Wes2FieldState<double>(
          hintValue: 2.0,
          hintOrigin: FieldOrigin.modelHint,
        ),
      )));
      await tester.pump();

      expect(find.text('2.0'), findsOneWidget);
      // Proof the weight rule (which would give "2") did not leak into RIR.
      expect(find.text('2'), findsNothing);
    });

    testWidgets('RIR hint 2.5 still renders "2.5"', (tester) async {
      await tester.pumpWidget(_harness(const Wes2SetState(
        setIndex: 0,
        rir: Wes2FieldState<double>(
          hintValue: 2.5,
          hintOrigin: FieldOrigin.modelHint,
        ),
      )));
      await tester.pump();
      expect(find.text('2.5'), findsOneWidget);
    });

    testWidgets('E1RM still renders with one decimal ("144.0")', (tester) async {
      // weight 100 × reps 10 @ RIR 2 → Brzycki E1RM = 100 * 36 / 25 = 144.0.
      await tester.pumpWidget(_harness(const Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(actualValue: 100.0, origin: FieldOrigin.typed),
        reps: Wes2FieldState<int>(actualValue: 10, origin: FieldOrigin.typed),
        rir: Wes2FieldState<double>(actualValue: 2.0, origin: FieldOrigin.typed),
      )));
      await tester.pump();

      expect(find.text('144.0'), findsOneWidget);
      // If E1RM had adopted the weight rule it would read "144".
      expect(find.text('144'), findsNothing);
    });
  });
}
