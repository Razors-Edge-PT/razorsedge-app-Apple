import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_widgets/WES2_weight_converter_dialog.dart';

/// The production WES2 weight converter dialog, opened through the same
/// [showWes2WeightConverter] call the WES2 overflow menu makes. The menu → dialog
/// path on the real screen is covered in wes2_voice_bridge_e2e_test.dart.

Finder get _input => find.descendant(
    of: find.byType(Wes2WeightConverterDialog), matching: find.byType(TextField));

String _result(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('weightConverterResult')))
    .data!;

String? _error(WidgetTester tester) =>
    tester.widget<TextField>(_input).decoration?.errorText;

Future<void> _open(WidgetTester tester,
    {Size size = const Size(400, 800), double textScale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showWes2WeightConverter(context),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
}

void main() {
  group('parseWeightConverterInput', () {
    test('whole numbers, decimals, zero and a trailing point', () {
      expect(parseWeightConverterInput('225').value, 225);
      expect(parseWeightConverterInput('102.5').value, 102.5);
      expect(parseWeightConverterInput('.5').value, 0.5);
      expect(parseWeightConverterInput('0').value, 0);
      expect(parseWeightConverterInput('0.0').value, 0);
      expect(parseWeightConverterInput('12.').value, 12);
      expect(parseWeightConverterInput('  80 ').value, 80, reason: 'pasted whitespace');
      expect(parseWeightConverterInput('12.').error, isNull);
    });

    test('nothing to convert yet: empty or a lone separator, without an error', () {
      for (final String t in <String>['', '   ', '.', ',']) {
        final r = parseWeightConverterInput(t);
        expect(r.value, isNull, reason: t);
        expect(r.error, isNull, reason: t);
      }
    });

    test('a decimal comma is normalised; a possible thousands group is refused', () {
      expect(parseWeightConverterInput('102,5').value, 102.5);
      expect(parseWeightConverterInput('2,25').value, 2.25);
      expect(parseWeightConverterInput('1,2345').value, 1.2345);
      expect(parseWeightConverterInput(',5').value, 0.5);
      for (final String t in <String>['1,000', '2,500', '1,000.5', '1.000,5', '1,000,000']) {
        final r = parseWeightConverterInput(t);
        expect(r.value, isNull, reason: t);
        expect(r.error, isNotNull, reason: t);
      }
    });

    test('negative, non-numeric, non-finite and too-large input is refused', () {
      for (final String t in <String>[
        '-5', '-', '+5', 'abc', '12a', '1e5', '1 000', 'NaN', 'Infinity',
        '225 lb', '1..2', '100000.5', '9' * 400,
      ]) {
        final r = parseWeightConverterInput(t);
        expect(r.value, isNull, reason: t);
        expect(r.error, isNotNull, reason: t);
      }
      expect(parseWeightConverterInput('100000').value, 100000);
    });

    test('directions convert through the shared helpers at full precision', () {
      expect(WeightConversionDirection.lbToKg.convert(225), closeTo(102.05828325, 1e-9));
      expect(WeightConversionDirection.kgToLb.convert(100), closeTo(220.46226218, 1e-8));
    });
  });

  testWidgets('opens titled, lb → kg by default, with an empty result', (tester) async {
    await _open(tester);
    expect(find.text('Weight converter'), findsOneWidget);
    expect(find.text('lb → kg'), findsOneWidget);
    expect(find.text('kg → lb'), findsOneWidget);
    expect(find.text('Weight in pounds (lb)'), findsOneWidget);
    expect(_result(tester), '— kg');
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Calculate'), findsNothing);
    final EditableText field = tester.widget<EditableText>(
        find.descendant(of: _input, matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isTrue, reason: 'ready to type');
    expect(field.keyboardType, const TextInputType.numberWithOptions(decimal: true));
  });

  testWidgets('reference values in both directions, calculated live', (tester) async {
    await _open(tester);
    await _type(tester, '225');
    expect(_result(tester), '102.058 kg');

    await tester.tap(find.text('kg → lb'));
    await tester.pumpAndSettle();
    await _type(tester, '100');
    expect(_result(tester), '220.462 lb');
  });

  testWidgets('switching direction keeps the number and reads it in the new unit', (tester) async {
    await _open(tester);
    await _type(tester, '100');
    expect(_result(tester), '45.359 kg');

    await tester.tap(find.text('kg → lb'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, '100');
    expect(find.text('Weight in kilograms (kg)'), findsOneWidget);
    expect(_result(tester), '220.462 lb');

    await tester.tap(find.text('lb → kg'));
    await tester.pumpAndSettle();
    expect(_result(tester), '45.359 kg');
  });

  testWidgets('decimals, zero, decimal comma, trailing point and trimming', (tester) async {
    await _open(tester);
    await _type(tester, '0');
    expect(_result(tester), '0 kg');
    await _type(tester, '2.5');
    expect(_result(tester), '1.134 kg');
    await _type(tester, '102,5');
    expect(_result(tester), '46.493 kg');
    await _type(tester, '45.');
    expect(_result(tester), '20.412 kg');
    expect(_error(tester), isNull);

    await tester.tap(find.text('kg → lb'));
    await tester.pumpAndSettle();
    await _type(tester, '20');
    expect(_result(tester), '44.092 lb');
    await _type(tester, '0.45359237');
    expect(_result(tester), '1 lb', reason: 'trailing zeros trimmed');
  });

  testWidgets('invalid input shows a message, never NaN/Infinity, and recovers', (tester) async {
    await _open(tester);
    for (final String t in <String>['-5', 'abc', '1,000', '1e999', '9' * 400]) {
      await _type(tester, t);
      expect(_result(tester), '— kg', reason: t);
      expect(_error(tester), isNotNull, reason: t);
      expect(find.textContaining('NaN'), findsNothing);
      expect(find.textContaining('Infinity'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await _type(tester, '225');
    expect(_error(tester), isNull);
    expect(_result(tester), '102.058 kg');
  });

  testWidgets('Clear empties the input and result and keeps the direction', (tester) async {
    await _open(tester);
    await tester.tap(find.text('kg → lb'));
    await tester.pumpAndSettle();
    await _type(tester, '100');
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, '');
    expect(_result(tester), '— lb');
    expect(find.text('Weight in kilograms (kg)'), findsOneWidget);
    expect(find.byType(Wes2WeightConverterDialog), findsOneWidget);
  });

  testWidgets('Close, system back and the barrier each dismiss only the dialog', (tester) async {
    for (final String how in <String>['close', 'back', 'barrier']) {
      await _open(tester);
      await _type(tester, '225');
      switch (how) {
        case 'close':
          await tester.tap(find.text('Close'));
        case 'back':
          await tester.binding.handlePopRoute();
        case 'barrier':
          await tester.tapAt(const Offset(5, 5));
      }
      await tester.pumpAndSettle();
      expect(find.byType(Wes2WeightConverterDialog), findsNothing, reason: how);
      expect(find.text('open'), findsOneWidget, reason: '$how: the screen below stays');
    }
  });

  testWidgets('narrow phone, large text and an open keyboard: no overflow, result reachable',
      (tester) async {
    await _open(tester, size: const Size(320, 568), textScale: 2.0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await _type(tester, '225');
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('weightConverterResult')));
    await tester.pumpAndSettle();
    expect(_result(tester), '102.058 kg');
    await tester.ensureVisible(find.text('Close'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(Wes2WeightConverterDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the result is announced with its unit for screen readers', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _open(tester);
    await _type(tester, '225');
    expect(find.bySemanticsLabel('Result: 102.058 kilograms'), findsOneWidget);
    expect(find.bySemanticsLabel('Pounds to kilograms'), findsOneWidget);
    semantics.dispose();
  });
}
