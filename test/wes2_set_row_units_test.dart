// The WES2 set row in an exercise's unit. The model — and everything the row
// reports — stays canonical KILOGRAMS; only the weight field shows and accepts
// pounds, converting once at this boundary.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/units/weight_unit.dart';

void main() {
  late List<({Wes2FieldKey key, String text})> changed;
  late List<({Wes2FieldKey key, String text})> unfocused;

  Future<void> pumpRow(
    WidgetTester tester, {
    required Wes2SetState set,
    ExerciseWeightUnit unit = ExerciseWeightUnit.kg,
  }) async {
    changed = [];
    unfocused = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: <Widget>[
          Wes2SetColumnHeaders(showVelocity: false, weightUnit: unit),
          Wes2SetRow(
            set: set,
            showVelocity: false,
            weightUnit: unit,
            onFieldChanged: (k, t) => changed.add((key: k, text: t)),
            onFieldUnfocused: (k, t) => unfocused.add((key: k, text: t)),
          ),
        ]),
      ),
    ));
  }

  Finder weightField() => find.byType(TextField).at(0);
  String weightText(WidgetTester t) =>
      t.widget<TextField>(weightField()).controller!.text;

  Future<void> dropFocus(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  final double kg225lb = 225 * kKgPerLb;

  testWidgets('kg (default) behaves exactly as before', (tester) async {
    await pumpRow(tester,
        set: const Wes2SetState(
            setIndex: 0, weight: Wes2FieldState<double>(actualValue: 102.5)));
    expect(find.text('Weight'), findsOneWidget);
    expect(weightText(tester), '102.5');
    await tester.enterText(weightField(), '105');
    await dropFocus(tester);
    expect(changed.last.text, '105');
    expect(unfocused.single.text, '105');
  });

  testWidgets('lb shows the stored kg in pounds and labels the column',
      (tester) async {
    await pumpRow(tester,
        unit: ExerciseWeightUnit.lb,
        set: Wes2SetState(
            setIndex: 0, weight: Wes2FieldState<double>(actualValue: kg225lb)));
    expect(find.text('Weight (lb)'), findsOneWidget);
    expect(weightText(tester), '225',
        reason: '225 lb round-trips without drift');
  });

  testWidgets('pounds typed are reported as canonical kilograms',
      (tester) async {
    await pumpRow(tester,
        unit: ExerciseWeightUnit.lb, set: const Wes2SetState(setIndex: 0));
    await tester.enterText(weightField(), '225');
    expect(changed.last.key, Wes2FieldKey.weight);
    expect(double.parse(changed.last.text), kg225lb);
    await dropFocus(tester);
    expect(double.parse(unfocused.single.text), kg225lb);
    // Other fields are never converted.
    await tester.enterText(find.byType(TextField).at(1), '5');
    expect(changed.last.text, '5');
  });

  testWidgets('reopening and saving an unchanged pound value does not drift',
      (tester) async {
    double stored = 225 * kKgPerLb;
    for (int i = 0; i < 5; i++) {
      await pumpRow(tester,
          unit: ExerciseWeightUnit.lb,
          set: Wes2SetState(
              setIndex: 0,
              weight: Wes2FieldState<double>(actualValue: stored)));
      await tester.showKeyboard(weightField()); // open, leave untouched
      await tester.pump();
      await dropFocus(tester);
      stored = double.parse(unfocused.single.text);
    }
    expect(stored, kg225lb);
  });

  testWidgets('accepting a hint stores the hint\'s exact kilograms',
      (tester) async {
    await pumpRow(tester,
        unit: ExerciseWeightUnit.lb,
        set: const Wes2SetState(
            setIndex: 0, weight: Wes2FieldState<double>(hintValue: 102.5)));
    await tester.tap(weightField());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(weightField());
    await tester.pumpAndSettle();
    // 102.5 kg = 225.9738… lb, shown to three decimals.
    expect(weightText(tester), '225.974', reason: 'the hint shown in pounds');
    expect(unfocused.last.text, '102.5', reason: 'not 225.974 lb re-derived');
  });

  testWidgets('switching the unit re-expresses the value without changing it',
      (tester) async {
    const Wes2SetState set = Wes2SetState(
        setIndex: 0, weight: Wes2FieldState<double>(actualValue: 100));
    await pumpRow(tester, set: set);
    expect(weightText(tester), '100');
    await pumpRow(tester, set: set, unit: ExerciseWeightUnit.lb);
    expect(weightText(tester), '220.462');
    expect(changed, isEmpty, reason: 'no value was written');
    expect(unfocused, isEmpty);
    await pumpRow(tester, set: set);
    expect(weightText(tester), '100');
  });

  testWidgets('E1RM is shown in the exercise unit', (tester) async {
    await pumpRow(tester,
        unit: ExerciseWeightUnit.lb,
        set: const Wes2SetState(
          setIndex: 0,
          weight: Wes2FieldState<double>(actualValue: 100),
          reps: Wes2FieldState<int>(actualValue: 1),
          rir: Wes2FieldState<double>(actualValue: 0),
        ));
    expect(find.text('220.5'), findsOneWidget);
  });
}
