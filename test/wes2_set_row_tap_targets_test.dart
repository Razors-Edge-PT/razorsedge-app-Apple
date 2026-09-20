import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';

/// The WES2 set row is 48 logical pixels tall, but its editable cells are only
/// 36 and sit bottom-aligned, leaving 12 dead pixels above each one. That dead
/// space is given to the cell's hit region — and to nothing else.
///
/// The geometry expectations here are the measured pre-change layout: every
/// rectangle, gap and scroll extent must survive the tap-target work exactly.

/// Rect of the visible editable cell that owns [field] (the 36-high box).
Rect visibleCell(WidgetTester tester, Finder field) => tester
    .getRect(find.ancestor(of: field, matching: find.byType(SizedBox)).first);

Widget harness({
  required Wes2ExerciseEntryMode mode,
  bool showVelocity = true,
  bool scroll = false,
  double textScale = 1.0,
}) {
  final row = Wes2SetRow(
    set: const Wes2SetState(setIndex: 0),
    showVelocity: showVelocity,
    entryMode: mode,
    bwDisplayText:
        mode == Wes2ExerciseEntryMode.timedBodyweight ? '82.5 kg' : null,
    onFieldChanged: (_, __) {},
    onFieldUnfocused: (_, __) {},
    onRemoveSet: () {},
    onNoteTap: () {},
    onVideoTap: () {},
    hasVideo: false,
  );
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: scroll
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: row)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wes2SetColumnHeaders(
                      showVelocity: showVelocity, entryMode: mode),
                  row,
                ],
              ),
      ),
    ),
  );
}

Future<void> pump(WidgetTester tester, Widget app, {double width = 412}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

/// The editable cells of the normal row, in visual order.
Finder weightField() => find.byType(TextField).at(0);
Finder repsField() => find.byType(TextField).at(1);
Finder rirField() => find.byType(TextField).at(2);
Finder velocityField() => find.byType(TextField).at(3);

bool hasFocus(WidgetTester tester, Finder field) => tester
    .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)))
    .focusNode
    .hasFocus;

void main() {
  group('unchanged geometry (normal row, velocity on, 412dp)', () {
    testWidgets('row height and every visible cell rectangle', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));

      // 48 of row content plus the row's existing 2px top padding.
      expect(tester.getSize(find.byType(Wes2SetRow)).height, 50);
      expect(tester.getRect(find.byType(Wes2SetRow)),
          const Rect.fromLTRB(0, 14, 412, 64));

      expect(visibleCell(tester, weightField()),
          const Rect.fromLTRB(40, 28, 116, 64));
      expect(visibleCell(tester, repsField()),
          const Rect.fromLTRB(120, 28, 170, 64));
      expect(visibleCell(tester, rirField()),
          const Rect.fromLTRB(174, 28, 224, 64));
      expect(visibleCell(tester, velocityField()),
          const Rect.fromLTRB(280, 28, 325, 64));
    });

    testWidgets('visible sizes: 76/50/50/45 wide, all 36 high', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      expect(visibleCell(tester, weightField()).size, const Size(76, 36));
      expect(visibleCell(tester, repsField()).size, const Size(50, 36));
      expect(visibleCell(tester, rirField()).size, const Size(50, 36));
      expect(visibleCell(tester, velocityField()).size, const Size(45, 36));
    });

    testWidgets('4px gaps and bottom alignment are preserved', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      final w = visibleCell(tester, weightField());
      final r = visibleCell(tester, repsField());
      final rir = visibleCell(tester, rirField());
      final v = visibleCell(tester, velocityField());
      expect(r.left - w.right, 4);
      expect(rir.left - r.right, 4);
      // E1RM sits between RIR and velocity, with 4px either side.
      final e1rm = tester.getRect(find
          .ancestor(of: find.text('—'), matching: find.byType(SizedBox))
          .first);
      expect(e1rm.left - rir.right, 4);
      expect(v.left - e1rm.right, 4);
      // Every cell shares the row's bottom edge.
      for (final rect in [w, r, rir, v, e1rm]) {
        expect(rect.bottom, 64);
        expect(rect.height, 36);
      }
    });

    testWidgets('trailing controls keep their geometry', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      expect(tester.getRect(find.byIcon(Icons.remove_circle_outline)),
          const Rect.fromLTRB(331, 32, 347, 48));
      expect(tester.getRect(find.byIcon(Icons.sticky_note_2)),
          const Rect.fromLTRB(359, 32, 375, 48));
      // Both remain full 28x48 targets.
      for (final icon in [Icons.remove_circle_outline, Icons.sticky_note_2]) {
        final slot = find
            .ancestor(of: find.byIcon(icon), matching: find.byType(SizedBox))
            .last;
        expect(tester.getSize(slot), const Size(28, 48));
      }
    });

    testWidgets('horizontal scroll extent is unchanged', (tester) async {
      await pump(
          tester, harness(mode: Wes2ExerciseEntryMode.normal, scroll: true),
          width: 320);
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos.maxScrollExtent, 96);
    });
  });

  group('unchanged geometry (timed rows)', () {
    testWidgets('timed weighted: weight cell and time cell', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedWeighted));
      expect(tester.getSize(find.byType(Wes2SetRow)).height, 50);
      expect(visibleCell(tester, find.byType(TextField).at(0)),
          const Rect.fromLTRB(40, 28, 116, 64));
      expect(tester.getRect(find.byIcon(Icons.timer_outlined)),
          const Rect.fromLTRB(122, 43, 134, 55));
      final timeCell = find
          .ancestor(
              of: find.byIcon(Icons.timer_outlined),
              matching: find.byType(SizedBox))
          .first;
      expect(tester.getRect(timeCell), const Rect.fromLTRB(120, 28, 190, 64));
    });

    testWidgets('timed bodyweight: time cell', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedBodyweight));
      expect(tester.getSize(find.byType(Wes2SetRow)).height, 50);
      expect(tester.getRect(find.byIcon(Icons.timer_outlined)),
          const Rect.fromLTRB(136, 43, 148, 55));
      final timeCell = find
          .ancestor(
              of: find.byIcon(Icons.timer_outlined),
              matching: find.byType(SizedBox))
          .first;
      expect(tester.getRect(timeCell), const Rect.fromLTRB(134, 28, 204, 64));
    });

    testWidgets('no overflow at narrow widths in either mode', (tester) async {
      for (final mode in [
        Wes2ExerciseEntryMode.normal,
        Wes2ExerciseEntryMode.timedWeighted,
        Wes2ExerciseEntryMode.timedBodyweight,
      ]) {
        for (final width in [320.0, 360.0]) {
          await pump(tester, harness(mode: mode), width: width);
          expect(tester.takeException(), isNull,
              reason: '${mode.name} at ${width}dp');
        }
      }
    });
  });

  group('dead space above each field belongs to that field', () {
    /// A point in the formerly dead region: 6px below the row content top.
    Offset aboveField(WidgetTester tester, Finder field) {
      final cell = visibleCell(tester, field);
      return Offset(cell.center.dx, cell.top - 6);
    }

    testWidgets('a tap above Weight focuses Weight', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      await tester.tapAt(aboveField(tester, weightField()));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, weightField()), isTrue);
      expect(hasFocus(tester, repsField()), isFalse);
    });

    testWidgets('a tap above Reps focuses Reps, never its neighbours',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      await tester.tapAt(aboveField(tester, repsField()));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, repsField()), isTrue);
      expect(hasFocus(tester, weightField()), isFalse);
      expect(hasFocus(tester, rirField()), isFalse);
    });

    testWidgets('a tap above RIR focuses RIR', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      await tester.tapAt(aboveField(tester, rirField()));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, rirField()), isTrue);
      expect(hasFocus(tester, repsField()), isFalse);
    });

    testWidgets('a tap above Velocity focuses Velocity', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      await tester.tapAt(aboveField(tester, velocityField()));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, velocityField()), isTrue);
      expect(hasFocus(tester, rirField()), isFalse);
    });

    testWidgets('the full 48 height is tappable, top edge included',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      final cell = visibleCell(tester, weightField());
      // 16 is the top of the row's content box; 64 its bottom: 48 tall.
      await tester.tapAt(Offset(cell.center.dx, 17));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, weightField()), isTrue);
    });

    testWidgets('the 4px gaps stay inert', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      final w = visibleCell(tester, weightField());
      final r = visibleCell(tester, repsField());
      final rir = visibleCell(tester, rirField());
      for (final gapX in [w.right + 2, r.right + 2, rir.right + 2]) {
        for (final y in [22.0, 50.0]) {
          await tester.tapAt(Offset(gapX, y));
          await tester.pumpAndSettle();
          expect(hasFocus(tester, weightField()), isFalse,
              reason: 'gap at $gapX,$y');
          expect(hasFocus(tester, repsField()), isFalse,
              reason: 'gap at $gapX,$y');
          expect(hasFocus(tester, rirField()), isFalse,
              reason: 'gap at $gapX,$y');
        }
      }
    });

    testWidgets('E1RM stays display-only', (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      final e1rm = tester.getRect(find
          .ancestor(of: find.text('—'), matching: find.byType(SizedBox))
          .first);
      await tester.tapAt(Offset(e1rm.center.dx, e1rm.top - 6));
      await tester.tapAt(e1rm.center);
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find
                  .ancestor(of: find.text('—'), matching: find.byType(SizedBox))
                  .first,
              matching: find.byType(EditableText)),
          findsNothing);
      for (final f in [weightField(), repsField(), rirField()]) {
        expect(hasFocus(tester, f), isFalse);
      }
    });

    testWidgets('timed weighted: Weight and Time answer their dead space',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedWeighted));
      final weight = find.byType(TextField).at(0);
      await tester.tapAt(aboveField(tester, weight));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, weight), isTrue);

      // The Time cell activates from its dead space exactly as it does from
      // the visible cell: its underline switches to the active colour.
      Color underline() {
        final container = tester.widget<Container>(find
            .ancestor(
                of: find.byIcon(Icons.timer_outlined),
                matching: find.byType(Container))
            .first);
        final border = (container.decoration as BoxDecoration).border!;
        return border.bottom.color;
      }

      final resting = underline();
      final timeCell = tester.getRect(find
          .ancestor(
              of: find.byIcon(Icons.timer_outlined),
              matching: find.byType(SizedBox))
          .first);
      await tester.tapAt(Offset(timeCell.center.dx, timeCell.top - 6));
      await tester.pumpAndSettle();
      expect(underline(), isNot(resting), reason: 'activated from dead space');
    });

    testWidgets('timed bodyweight: Time answers its dead space',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedBodyweight));
      Color underline() {
        final container = tester.widget<Container>(find
            .ancestor(
                of: find.byIcon(Icons.timer_outlined),
                matching: find.byType(Container))
            .first);
        return ((container.decoration as BoxDecoration).border!).bottom.color;
      }

      final resting = underline();
      final timeCell = tester.getRect(find
          .ancestor(
              of: find.byIcon(Icons.timer_outlined),
              matching: find.byType(SizedBox))
          .first);
      await tester.tapAt(Offset(timeCell.center.dx, timeCell.top - 6));
      await tester.pumpAndSettle();
      expect(underline(), isNot(resting));
    });
  });

  group('expanded hit regions', () {
    testWidgets('each cell is tappable across the full 48 row height',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      const expected = {
        'wes2-cell-weight': Size(76, 48),
        'wes2-cell-reps': Size(50, 48),
        'wes2-cell-rir': Size(50, 48),
        'wes2-cell-velocity': Size(45, 48),
      };
      expected.forEach((key, size) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.size, size, reason: key);
        // Spans the row's content box: 16 to 64.
        expect(rect.top, 16, reason: key);
        expect(rect.bottom, 64, reason: key);
      });
    });

    testWidgets('timed rows expand Weight and Time the same way',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedWeighted));
      expect(tester.getRect(find.byKey(const ValueKey('wes2-cell-weight'))),
          const Rect.fromLTRB(40, 16, 116, 64));
      expect(tester.getRect(find.byKey(const ValueKey('wes2-cell-time'))),
          const Rect.fromLTRB(120, 16, 190, 64));

      await pump(tester, harness(mode: Wes2ExerciseEntryMode.timedBodyweight));
      expect(tester.getRect(find.byKey(const ValueKey('wes2-cell-time'))),
          const Rect.fromLTRB(134, 16, 204, 64));
    });

    testWidgets('no duplicate tappable semantics are introduced',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      // 4 editable fields + remove, note and video controls.
      expect(tappableSemanticsNodes(tester), 7);
      handle.dispose();
    });
  });

  group('editing still behaves', () {
    testWidgets('typing, cursor placement and unfocus are unaffected',
        (tester) async {
      await pump(tester, harness(mode: Wes2ExerciseEntryMode.normal));
      await tester.tap(weightField());
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, weightField()), isTrue);
      await tester.enterText(weightField(), '100');
      await tester.pumpAndSettle();
      expect(find.text('100'), findsOneWidget);
      expect(hasFocus(tester, weightField()), isTrue);

      await tester.tap(repsField());
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(hasFocus(tester, repsField()), isTrue);
      expect(hasFocus(tester, weightField()), isFalse);
      await tester.enterText(repsField(), '8');
      await tester.pumpAndSettle();
      expect(find.text('8'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
    });
  });
}

/// Counts semantics nodes that expose a tap action, so the invisible strips
/// cannot quietly add duplicate controls for screen readers.
int tappableSemanticsNodes(WidgetTester tester) {
  var count = 0;
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().hasAction(SemanticsAction.tap)) count++;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return count;
}
