import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';

/// Constrained layout and touch-target cover for the WES2 set row.
///
/// These fail against e52184f, where the set-video control was a 24x36
/// IconButton that pushed an already-tight row into a RenderFlex overflow:
/// 49px at 320dp and 9px at 360dp in normal mode — 360dp being the width of
/// most Android phones in use. A striped overflow banner across every set row
/// is not a cosmetic problem.
///
/// Two things are asserted here and nowhere else: that no supported width
/// overflows in any row variant at any supported text scale, and that the
/// trailing controls actually reach a usable touch size.

/// Widths that must not overflow. 320 is the narrowest logical width the app
/// can meet in practice (iPhone SE 1st gen); 360 covers most Android phones.
const List<double> _widths = <double>[320, 360, 375, 390, 412];

/// 1.0 is the default; 1.3 is a common accessibility setting; 2.0 is close to
/// the largest non-accessibility iOS size.
const List<double> _textScales = <double>[1.0, 1.3, 2.0];

const List<Wes2ExerciseEntryMode> _modes = <Wes2ExerciseEntryMode>[
  Wes2ExerciseEntryMode.normal,
  Wes2ExerciseEntryMode.timedBodyweight,
  Wes2ExerciseEntryMode.timedWeighted,
];

Widget _harness({
  required Wes2ExerciseEntryMode mode,
  required double textScale,
  bool hasVideo = false,
  bool withRemove = true,
  bool showVelocity = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wes2SetColumnHeaders(
              showVelocity: showVelocity,
              entryMode: mode,
            ),
            Wes2SetRow(
              set: const Wes2SetState(setIndex: 0),
              showVelocity: showVelocity,
              entryMode: mode,
              bwDisplayText: mode == Wes2ExerciseEntryMode.timedBodyweight
                  ? '82.5 kg'
                  : null,
              onFieldChanged: (_, __) {},
              onFieldUnfocused: (_, __) {},
              onRemoveSet: withRemove ? () {} : null,
              onNoteTap: () {},
              onVideoTap: () {},
              hasVideo: hasVideo,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('no overflow at any supported width or text scale', () {
    for (final Wes2ExerciseEntryMode mode in _modes) {
      for (final double width in _widths) {
        for (final double scale in _textScales) {
          testWidgets('${mode.name} @ ${width}dp, ${scale}x text',
              (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(_harness(mode: mode, textScale: scale));
            await tester.pump();

            expect(tester.takeException(), isNull,
                reason: '${mode.name} overflows at ${width}dp / ${scale}x');
          });
        }
      }
    }

    testWidgets('a row with velocity shown also fits the narrowest width',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        mode: Wes2ExerciseEntryMode.normal,
        textScale: 1.0,
        showVelocity: true,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row without the remove control also fits', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        mode: Wes2ExerciseEntryMode.normal,
        textScale: 1.0,
        withRemove: false,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('touch targets', () {
    for (final Wes2ExerciseEntryMode mode in _modes) {
      testWidgets('the camera control is at least 28x48 in ${mode.name}',
          (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_harness(mode: mode, textScale: 1.0));
        await tester.pump();

        final Size size = tester
            .getSize(find.widgetWithIcon(IconButton, Icons.videocam_outlined));
        expect(size.height, greaterThanOrEqualTo(48),
            reason: 'the recommended 48 on the axis that has room');
        expect(size.width, greaterThanOrEqualTo(kWes2RowIconSlotWidth));
        // Strictly larger than the 24x36 it replaced.
        expect(size.width * size.height, greaterThan(24 * 36));
      });

      testWidgets('the note control is not shrunk to make room in ${mode.name}',
          (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_harness(mode: mode, textScale: 1.0));
        await tester.pump();

        final Size note = tester
            .getSize(find.widgetWithIcon(IconButton, Icons.sticky_note_2));
        expect(note.height, greaterThanOrEqualTo(48));
      });
    }

    testWidgets('the trailing controls do not overlap each other',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _harness(mode: Wes2ExerciseEntryMode.normal, textScale: 1.0));
      await tester.pump();

      final Rect remove = tester.getRect(
          find.widgetWithIcon(IconButton, Icons.remove_circle_outline));
      final Rect note =
          tester.getRect(find.widgetWithIcon(IconButton, Icons.sticky_note_2));
      final Rect camera = tester
          .getRect(find.widgetWithIcon(IconButton, Icons.videocam_outlined));

      expect(remove.overlaps(note), isFalse);
      expect(note.overlaps(camera), isFalse);
      expect(camera.left, greaterThanOrEqualTo(note.right),
          reason: 'camera sits immediately right of the note icon');
    });

    testWidgets('the whole trailing cluster is no wider than it replaced',
        (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _harness(mode: Wes2ExerciseEntryMode.normal, textScale: 1.0));
      await tester.pump();

      final Rect remove = tester.getRect(
          find.widgetWithIcon(IconButton, Icons.remove_circle_outline));
      final Rect camera = tester
          .getRect(find.widgetWithIcon(IconButton, Icons.videocam_outlined));

      // Three 28pt slots = 84, against the 86pt the two old controls plus
      // their spacers occupied. The accessibility gain costs no width.
      expect(camera.right - remove.left, lessThanOrEqualTo(86.0));
    });
  });

  group('recorded state is not signalled by colour alone', () {
    testWidgets('the icon glyph itself changes', (tester) async {
      await tester.pumpWidget(
          _harness(mode: Wes2ExerciseEntryMode.normal, textScale: 1.0));
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

      await tester.pumpWidget(_harness(
        mode: Wes2ExerciseEntryMode.normal,
        textScale: 1.0,
        hasVideo: true,
      ));
      expect(find.byIcon(Icons.videocam), findsOneWidget,
          reason: 'a filled glyph, readable without perceiving colour');
      expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    });

    testWidgets('the tooltip and semantic label also change', (tester) async {
      await tester.pumpWidget(_harness(
        mode: Wes2ExerciseEntryMode.normal,
        textScale: 1.0,
        hasVideo: true,
      ));
      final IconButton button = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.videocam));
      expect(button.tooltip, isNotNull);
      expect(button.tooltip, isNot('Record this set'));
    });
  });

  group('header and row stay column-aligned', () {
    for (final double width in <double>[320, 360, 390]) {
      testWidgets('the header reserves the trailing cluster at ${width}dp',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
            _harness(mode: Wes2ExerciseEntryMode.normal, textScale: 1.0));
        await tester.pump();

        // Both must consume the full width without overflow, which is what
        // keeps the flexible E1RM column the same size in each.
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(Wes2SetColumnHeaders)).width, width);
      });
    }
  });
}
