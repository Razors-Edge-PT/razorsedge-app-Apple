// Typing, through the real [Wes2SetRow] wired to the real controller and the
// real hint service — the same three pieces the exercise card puts together.
//
// The behaviours under test are the ones that used to disagree with each
// other: a half-typed value left the field showing "." while the model still
// held 25; `NaN` and `Infinity` were accepted as weights; and a value that
// equalled its hint was dropped on the way into the cascade.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/periodization_model_utils.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings() => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '10 x 3'},
          'week2': <String, dynamic>{'instance1': '10 x 3'},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                'set1': <String, dynamic>{'rir': '2'},
                'set2': <String, dynamic>{'rir': '2'},
                'set3': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

void main() {
  late Wes2SessionController controller;
  late List<({Wes2FieldKey key, String text})> saved;

  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[
      <String, dynamic>{
        'date': DateTime(2026, 1, 5),
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': _exId,
            'name': _exName,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'weight': 35.0, 'reps': 8, 'rir': 2.0}
            ],
          }
        ],
      }
    ];
    PeriodizationModelUtils.topSetsByExercise.clear();
    saved = <({Wes2FieldKey key, String text})>[];

    controller = Wes2SessionController(_day)
      ..initIdentity(
        actorUid: _uid,
        actingUid: _uid,
        isCoach: false,
        activeBlockId: _blockId,
        blockStartDate: _blockStart,
        blockEndDate: null,
      )
      ..setExerciseSettings(_settings());
    final int epoch = controller.beginLoad();
    controller.setRows(<Wes2ExerciseRow>[
      Wes2ExerciseRow(
        exerciseId: _exId,
        name: _exName,
        circuitIndex: 0,
        orderIndex: 0,
        setCount: 3,
        source: Wes2RowSource.wes2Manual,
        sets: List<Wes2SetState>.generate(
            3, (int i) => Wes2SetState(setIndex: i)),
      )
    ], epoch);
    controller.applyHintContext(
      Wes2HintServiceImpl(
        exerciseSettings: _settings(),
        blockStartDate: _blockStart,
        blockEndDate: null,
        uid: _uid,
      ),
      _blockId,
    );
  });

  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  /// Pumps the real row for [setIndex], rebuilt from the controller exactly
  /// the way the exercise card rebuilds it after every notification.
  Future<void> pump(WidgetTester tester, {int setIndex = 0}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, _) => Wes2SetRow(
            set: controller.rows.first.sets[setIndex],
            showVelocity: false,
            onFieldChanged: (Wes2FieldKey k, String t) =>
                controller.updateSetField(
              exerciseId: _exId,
              setIndex: setIndex,
              fieldKey: k,
              rawText: t,
            ),
            onFieldUnfocused: (Wes2FieldKey k, String t) {
              saved.add((key: k, text: t));
              controller.updateSetField(
                exerciseId: _exId,
                setIndex: setIndex,
                fieldKey: k,
                rawText: t,
              );
            },
          ),
        ),
      ),
    ));
  }

  Finder fieldAt(int i) => find.byType(TextField).at(i);
  TextField widgetAt(WidgetTester tester, int i) =>
      tester.widget<TextField>(fieldAt(i));
  Wes2SetState set0() => controller.rows.first.sets[0];

  Future<void> dropFocus(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  testWidgets('H-TEXT-RAPID 2 -> 22 -> 22. -> 22.5 follows the keystrokes',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '2');
    expect(set0().weight.actualValue, 2.0);
    await tester.enterText(fieldAt(0), '22');
    expect(set0().weight.actualValue, 22.0);
    await tester.enterText(fieldAt(0), '22.');
    expect(set0().weight.actualValue, 22.0,
        reason: 'a trailing point is a valid partial number');
    expect(widgetAt(tester, 0).controller!.text, '22.',
        reason: 'the athlete is still typing; the text must not be rewritten');
    await tester.enterText(fieldAt(0), '22.5');
    expect(set0().weight.actualValue, 22.5);
  });

  testWidgets('H-TEXT-UNFINISHED "-" and "." keep the last valid number',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '25');
    expect(set0().weight.actualValue, 25.0);

    await tester.enterText(fieldAt(0), '-');
    expect(set0().weight.actualValue, 25.0,
        reason: 'a lone minus is not a number');
    expect(widgetAt(tester, 0).controller!.text, '-',
        reason: 'the text the athlete typed stays while the field has focus');

    await tester.enterText(fieldAt(0), '.');
    expect(set0().weight.actualValue, 25.0);
  });

  testWidgets('H-TEXT-BLUR restores the last valid number AND saves it',
      (WidgetTester tester) async {
    // The durable write happens on blur, not on every keystroke. Restoring the
    // display without saving left the athlete looking at 25 while the server
    // still held the old value, and a reload brought the old value back.
    await pump(tester);
    await tester.enterText(fieldAt(0), '25');
    saved.clear();
    await tester.enterText(fieldAt(0), '-');
    await dropFocus(tester);

    expect(widgetAt(tester, 0).controller!.text, '25',
        reason: 'invalid text is replaced by the value the model holds');
    expect(set0().weight.actualValue, 25.0);
    expect(saved, hasLength(1),
        reason: 'the last valid entry must still reach the durable write');
    expect(saved.single.key, Wes2FieldKey.weight);
    expect(double.parse(saved.single.text), 25.0);
  });

  testWidgets('H-TEXT-BLUR saves the exact number, not the displayed rounding',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '22.4999999');
    expect(set0().weight.actualValue, 22.4999999);
    saved.clear();
    await tester.enterText(fieldAt(0), '-');
    await dropFocus(tester);

    // The row displays three decimals; what is saved must not be rounded to
    // the display on the way out.
    expect(widgetAt(tester, 0).controller!.text, '22.5');
    expect(set0().weight.actualValue, 22.4999999);
    expect(double.parse(saved.single.text), 22.4999999);
  });

  testWidgets('H-TEXT-BLUR on an empty-model field leaves it empty, never 0',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '-');
    await dropFocus(tester);

    expect(widgetAt(tester, 0).controller!.text, '');
    expect(set0().weight.actualValue, isNull);
    expect(set0().weight.hintValue, isNotNull,
        reason: 'the hint shows again; it is not adopted as an entry');
    expect(saved, isEmpty);
  });

  testWidgets('H-TEXT-BLUR an explicit clear still reaches the save path',
      (WidgetTester tester) async {
    // saved 25 -> clear it -> leave half-typed text -> blur. The clear is the
    // athlete's real intent; without it the old 25 comes back on reload.
    await pump(tester);
    await tester.enterText(fieldAt(0), '25');
    await dropFocus(tester);
    expect(set0().weight.actualValue, 25.0);

    saved.clear();
    await tester.tap(fieldAt(0));
    await tester.pump();
    await tester.enterText(fieldAt(0), '');
    await tester.enterText(fieldAt(0), '-');
    await dropFocus(tester);

    expect(set0().weight.actualValue, isNull);
    expect(widgetAt(tester, 0).controller!.text, '');
    expect(saved, hasLength(1), reason: 'the clear must be recorded');
    expect(saved.single.text, '');
  });

  testWidgets('H-TEXT-NONFINITE NaN, Infinity and exponent forms are refused',
      (WidgetTester tester) async {
    await pump(tester);
    for (final String bad in <String>['NaN', 'Infinity', '-Infinity', '1e3']) {
      await tester.enterText(fieldAt(0), bad);
      expect(set0().weight.actualValue, isNull, reason: 'accepted "$bad"');
    }
    // Reps are decimal-only: hex slipped through int.tryParse before.
    await tester.enterText(fieldAt(1), '0x10');
    expect(set0().reps.actualValue, isNull);
  });

  testWidgets('H-TEXT-ZERO-RIR zero is a real entry and is saved',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(2), '0');
    await dropFocus(tester);
    expect(set0().rir.actualValue, 0.0);
    expect(saved.where((e) => e.key == Wes2FieldKey.rir).single.text, '0');
  });

  testWidgets('H-TEXT-CLEAR an emptied field is a clear, not invalid text',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '30');
    saved.clear();
    await tester.enterText(fieldAt(0), '');
    await dropFocus(tester);
    expect(set0().weight.actualValue, isNull);
    expect(saved.single.text, '');
  });

  testWidgets('H-TEXT-ACCEPT double-tap enters exactly the displayed hint',
      (WidgetTester tester) async {
    await pump(tester);
    final String shownReps = set0().reps.hintValue!.toString();
    // Two taps inside kDoubleTapTimeout but beyond kDoubleTapMinTime.
    await tester.tap(fieldAt(1));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(fieldAt(1));
    await tester.pumpAndSettle();

    expect(set0().reps.actualValue.toString(), shownReps);
    expect(saved.map((e) => e.text), contains(shownReps));
  });

  testWidgets('H-TEXT-NO-HINT-SAVED only entered fields are ever saved',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.enterText(fieldAt(0), '42.5');
    await dropFocus(tester);
    expect(saved.map((e) => e.key).toSet(), <Wes2FieldKey>{Wes2FieldKey.weight});
    expect(set0().reps.actualValue, isNull);
    expect(set0().rir.actualValue, isNull);
  });
}
