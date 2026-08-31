import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/wes2_video/set_video_copy.dart';

/// The set-video control in the WES2 set row.
///
/// The requirement is positional — the camera sits immediately to the RIGHT of
/// the note icon — and it has to hold in every row variant, because the row is
/// rendered by two different code paths (a shared helper for the timed modes,
/// and an inline block for the normal one). A change to one and not the other
/// is exactly the regression these exist to catch.

const List<Wes2ExerciseEntryMode> _allModes = <Wes2ExerciseEntryMode>[
  Wes2ExerciseEntryMode.normal,
  Wes2ExerciseEntryMode.timedBodyweight,
  Wes2ExerciseEntryMode.timedWeighted,
];

String _modeName(Wes2ExerciseEntryMode m) => m.name;

Widget _row({
  required Wes2ExerciseEntryMode mode,
  VoidCallback? onVideoTap,
  VoidCallback? onNoteTap,
  bool hasVideo = false,
  int setIndex = 0,
  double textScale = 1.0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1200,
            child: Wes2SetRow(
              set: Wes2SetState(setIndex: setIndex),
              showVelocity: false,
              entryMode: mode,
              bwDisplayText: mode == Wes2ExerciseEntryMode.timedBodyweight
                  ? '82.5 kg'
                  : null,
              onFieldChanged: (_, __) {},
              onFieldUnfocused: (_, __) {},
              onRemoveSet: () {},
              onNoteTap: onNoteTap ?? () {},
              onVideoTap: onVideoTap ?? () {},
              hasVideo: hasVideo,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The horizontal centre of a widget, used to assert left-to-right order.
double _centreX(WidgetTester tester, Finder f) => tester.getCenter(f).dx;

void main() {
  group('the camera sits immediately right of the note icon', () {
    for (final Wes2ExerciseEntryMode mode in _allModes) {
      testWidgets('in ${_modeName(mode)} rows', (tester) async {
        await tester.pumpWidget(_row(mode: mode));

        final Finder note = find.byIcon(Icons.sticky_note_2);
        final Finder camera = find.byIcon(Icons.videocam_outlined);

        expect(note, findsOneWidget,
            reason: 'the note icon must still be here');
        expect(camera, findsOneWidget);
        expect(_centreX(tester, camera), greaterThan(_centreX(tester, note)),
            reason: 'the camera must be to the RIGHT of the note icon');
      });

      testWidgets('with nothing rendered between them in ${_modeName(mode)}',
          (tester) async {
        await tester.pumpWidget(_row(mode: mode));

        final double note = _centreX(tester, find.byIcon(Icons.sticky_note_2));
        final double camera =
            _centreX(tester, find.byIcon(Icons.videocam_outlined));

        // No other IconButton may sit between the two.
        final Iterable<double> between = find
            .byType(IconButton)
            .evaluate()
            .map((e) => tester.getCenter(find.byWidget(e.widget)).dx)
            .where((x) => x > note && x < camera);
        expect(between, isEmpty,
            reason:
                'the camera is adjacent to the note icon, not merely after');
      });
    }
  });

  group('recorded state', () {
    for (final Wes2ExerciseEntryMode mode in _allModes) {
      testWidgets('an attached video shows a filled icon in ${_modeName(mode)}',
          (tester) async {
        await tester.pumpWidget(_row(mode: mode, hasVideo: true));
        expect(find.byIcon(Icons.videocam), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsNothing);
      });
    }

    testWidgets('the tooltip distinguishes empty from recorded',
        (tester) async {
      await tester.pumpWidget(_row(mode: Wes2ExerciseEntryMode.normal));
      expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.videocam_outlined))
            .tooltip,
        SetVideoCopy.recordSetTooltip,
      );

      await tester
          .pumpWidget(_row(mode: Wes2ExerciseEntryMode.normal, hasVideo: true));
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.videocam))
            .tooltip,
        SetVideoCopy.recordedSetTooltip,
      );
    });
  });

  group('accessibility', () {
    testWidgets('the empty control announces what it does', (tester) async {
      await tester
          .pumpWidget(_row(mode: Wes2ExerciseEntryMode.normal, setIndex: 1));
      expect(find.bySemanticsLabel(SetVideoCopy.recordSemanticLabel(2)),
          findsOneWidget);
    });

    testWidgets('the recorded control announces its state and its actions',
        (tester) async {
      await tester.pumpWidget(_row(
          mode: Wes2ExerciseEntryMode.normal, setIndex: 2, hasVideo: true));
      expect(find.bySemanticsLabel(SetVideoCopy.recordedSemanticLabel(3)),
          findsOneWidget);
    });

    testWidgets('the label uses the human set number, not the index',
        (tester) async {
      await tester
          .pumpWidget(_row(mode: Wes2ExerciseEntryMode.normal, setIndex: 0));
      expect(SetVideoCopy.recordSemanticLabel(1), contains('set 1'));
      expect(find.bySemanticsLabel(SetVideoCopy.recordSemanticLabel(1)),
          findsOneWidget);
    });

    testWidgets('it is marked as a button for assistive technology',
        (tester) async {
      await tester.pumpWidget(_row(mode: Wes2ExerciseEntryMode.normal));
      final SemanticsNode node = tester.getSemantics(
          find.bySemanticsLabel(SetVideoCopy.recordSemanticLabel(1)));
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    });

    for (final double scale in <double>[1.3, 2.0]) {
      testWidgets('it still renders at ${scale}x text scale', (tester) async {
        await tester.pumpWidget(
            _row(mode: Wes2ExerciseEntryMode.normal, textScale: scale));
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('tapping', () {
    for (final Wes2ExerciseEntryMode mode in _allModes) {
      testWidgets('the control fires its callback in ${_modeName(mode)}',
          (tester) async {
        int taps = 0;
        await tester.pumpWidget(_row(mode: mode, onVideoTap: () => taps++));
        await tester.tap(find.byIcon(Icons.videocam_outlined));
        await tester.pump();
        expect(taps, 1);
      });
    }

    testWidgets('it does not fire the note callback', (tester) async {
      int notes = 0;
      await tester.pumpWidget(_row(
        mode: Wes2ExerciseEntryMode.normal,
        onNoteTap: () => notes++,
      ));
      await tester.tap(find.byIcon(Icons.videocam_outlined));
      await tester.pump();
      expect(notes, 0);
    });
  });

  group('rows that cannot carry footage', () {
    for (final Wes2ExerciseEntryMode mode in _allModes) {
      testWidgets(
          'no control and no gap when onVideoTap is null in '
          '${_modeName(mode)}', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 1200,
                child: Wes2SetRow(
                  set: const Wes2SetState(setIndex: 0),
                  showVelocity: false,
                  entryMode: mode,
                  bwDisplayText: mode == Wes2ExerciseEntryMode.timedBodyweight
                      ? '82.5 kg'
                      : null,
                  onFieldChanged: (_, __) {},
                  onFieldUnfocused: (_, __) {},
                  onRemoveSet: () {},
                  onNoteTap: () {},
                ),
              ),
            ),
          ),
        ));

        expect(find.byIcon(Icons.videocam_outlined), findsNothing);
        expect(find.byIcon(Icons.videocam), findsNothing);
        expect(find.byIcon(Icons.sticky_note_2), findsOneWidget,
            reason: 'the existing row is otherwise untouched');
      });
    }
  });
}
