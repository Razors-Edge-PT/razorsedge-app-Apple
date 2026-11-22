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
import 'package:localtest222/pinch_zoom_area.dart';

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

  // ── Inside the pinch-zoomed WES2 body ───────────────────────────────────
  //
  // The WES2 body's shape: a top action bar, then the vertical exercise list
  // whose card puts the set rows in a horizontal scroller — all inside the
  // PinchZoomArea, exactly as Wes2Screen wraps _buildBody.
  group('zoomed WES2', () {
    final ScrollController list = ScrollController();
    tearDownAll(list.dispose);

    Future<void> pumpZoomed(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PinchZoomArea(
            child: Column(children: <Widget>[
              const SizedBox(
                key: ValueKey<String>('top-bar'),
                height: 48,
                child: Center(child: Text('Add Exercise')),
              ),
              Expanded(
                child: ListView(controller: list, children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: AnimatedBuilder(
                        animation: controller,
                        builder: (BuildContext context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Wes2SetColumnHeaders(showVelocity: false),
                            for (int i = 0; i < 3; i++)
                              Wes2SetRow(
                                key: ValueKey<int>(i),
                                set: controller.rows.first.sets[i],
                                showVelocity: false,
                                onFieldChanged: (Wes2FieldKey k, String t) =>
                                    controller.updateSetField(
                                  exerciseId: _exId,
                                  setIndex: i,
                                  fieldKey: k,
                                  rawText: t,
                                ),
                                onFieldUnfocused: (Wes2FieldKey k, String t) {
                                  if (i == 0) saved.add((key: k, text: t));
                                  controller.updateSetField(
                                    exerciseId: _exId,
                                    setIndex: i,
                                    fieldKey: k,
                                    rawText: t,
                                  );
                                },
                                onRemoveSet: () {},
                                onNoteTap: () {},
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 1500),
                ]),
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    PinchZoomAreaState zoom(WidgetTester tester) =>
        tester.state<PinchZoomAreaState>(find.byType(PinchZoomArea));

    Future<void> pinch(WidgetTester tester, Offset c,
        {required double from, required double to}) async {
      final TestGesture a = await tester.startGesture(c - Offset(from, 0));
      final TestGesture b = await tester.startGesture(c + Offset(from, 0));
      await tester.pump();
      for (int i = 1; i <= 10; i++) {
        final double d = from + (to - from) * i / 10;
        await a.moveTo(c - Offset(d, 0));
        await b.moveTo(c + Offset(d, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    }

    Rect visibleWeight(WidgetTester tester) => tester.getRect(find
        .ancestor(of: fieldAt(0), matching: find.byType(SizedBox))
        .first);

    bool focused(WidgetTester tester, int i) => tester
        .widget<EditableText>(
            find.descendant(of: fieldAt(i), matching: find.byType(EditableText)))
        .focusNode
        .hasFocus;

    for (final double width in <double>[320, 360]) {
      testWidgets(
          '${width}dp: pinch to 150%, pan, tap the Weight gap edge, type, '
          'save, zoom out — the value is intact', (WidgetTester tester) async {
        await pumpZoomed(tester, width);
        final Rect original = visibleWeight(tester);

        // 1-2. Pinch to 150% around the Weight field.
        await pinch(tester, original.center, from: 30, to: 45);
        expect(zoom(tester).scale, closeTo(1.5, 0.02));
        expect(visibleWeight(tester).width, closeTo(76 * 1.5, 1));
        expect(saved, isEmpty, reason: 'the pinch saved nothing');
        for (int i = 0; i < 3; i++) {
          expect(focused(tester, i), isFalse, reason: 'nor focused field $i');
        }

        // 3. Pan a little with one finger on the (non-scrolling) top bar.
        final double pan = zoom(tester).panX;
        await tester.dragFrom(
            tester.getCenter(find.byKey(const ValueKey<String>('top-bar'))),
            const Offset(-24, 0));
        await tester.pumpAndSettle();
        expect(zoom(tester).panX, isNot(pan));

        // 4-5. Tap inside Weight's half of the (now 6px) Weight|Reps gap.
        final Rect gap = tester.getRect(
            find.byKey(const ValueKey<String>('wes2-gap-weight-reps')).first);
        expect(gap.width, closeTo(6, 0.1));
        await tester.tapAt(Offset(gap.left + 1.5, gap.center.dy));
        await tester.pumpAndSettle();
        expect(focused(tester, 0), isTrue);
        expect(focused(tester, 1), isFalse);
        final double scale = zoom(tester).scale;
        final double panAfterTap = zoom(tester).panX;

        // 6-7. Type with the normal keyboard; the normal save path runs.
        await tester.enterText(fieldAt(0), '62.5');
        await dropFocus(tester);
        expect(saved.last, (key: Wes2FieldKey.weight, text: '62.5'));
        expect(set0().weight.actualValue, 62.5);
        expect(zoom(tester).scale, scale, reason: 'editing kept the zoom');
        expect(zoom(tester).panX, panAfterTap);

        // 8-9. Zoom back out: original geometry, value still correct.
        await pinch(tester, const Offset(160, 300), from: 60, to: 10);
        expect(zoom(tester).scale, 1);
        expect(visibleWeight(tester), original);
        expect(widgetAt(tester, 0).controller!.text, '62.5');
        expect(set0().weight.actualValue, 62.5);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('while zoomed: double tap still accepts the hint, and the '
        'exercise list still scrolls', (WidgetTester tester) async {
      await pumpZoomed(tester, 360);
      final String shownReps = set0().reps.hintValue!.toString();
      await pinch(tester, tester.getCenter(fieldAt(1)), from: 30, to: 45);
      expect(zoom(tester).scale, closeTo(1.5, 0.02));

      await tester.tap(fieldAt(1));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(fieldAt(1));
      await tester.pumpAndSettle();
      expect(set0().reps.actualValue.toString(), shownReps);

      await dropFocus(tester);
      final double before = list.offset;
      await tester.dragFrom(const Offset(180, 560), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(list.offset, greaterThan(before + 50));
    });
  });
}
