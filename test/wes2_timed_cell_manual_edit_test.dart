import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';

/// Coverage for the timed-cell in [Wes2SetRow]: the pre-existing
/// start/stop/resume/reset timer gestures **and** the new manual scroll-wheel
/// time editor. Every test drives the real production widget.
void main() {
  late List<({Wes2FieldKey key, String text})> changed;
  late List<({Wes2FieldKey key, String text})> unfocused;

  setUp(() {
    changed = [];
    unfocused = [];
  });

  /// Stateful host that mirrors the production save pipeline closely enough for
  /// these tests: an `onFieldUnfocused` for [Wes2FieldKey.reps] is folded back
  /// into the set's `reps.actualValue` (empty text → cleared), then the row is
  /// rebuilt — exactly what the WES2 controller does.
  Widget host(
    Wes2SetState initial, {
    Wes2ExerciseEntryMode mode = Wes2ExerciseEntryMode.timedBodyweight,
  }) =>
      _Host(
        initial: initial,
        mode: mode,
        onChanged: (k, t) => changed.add((key: k, text: t)),
        onUnfocused: (k, t) => unfocused.add((key: k, text: t)),
      );

  Finder timeTarget() => find.byIcon(Icons.timer_outlined);
  Finder editIcon() => find.byIcon(Icons.edit_outlined);

  ({Wes2FieldKey key, String text}) lastRepsUnfocus() =>
      unfocused.lastWhere((c) => c.key == Wes2FieldKey.reps);

  Future<void> runTimerFor(WidgetTester tester, int steps) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // ── Existing timer gestures ────────────────────────────────────────────────

  testWidgets('1. timer tap start / stop still works', (tester) async {
    await tester.pumpWidget(host(const Wes2SetState(setIndex: 0)));

    await tester.tap(timeTarget()); // activate
    await tester.pump();
    await tester.tap(timeTarget()); // start running
    await tester.pump();

    await runTimerFor(tester, 12); // ~1.2 s → 1 whole second

    await tester.tap(timeTarget()); // stop
    await tester.pump();

    expect(lastRepsUnfocus().text, '1');
  });

  testWidgets('2. long-press reset still works', (tester) async {
    await tester.pumpWidget(host(const Wes2SetState(setIndex: 0)));

    await tester.tap(timeTarget());
    await tester.pump();
    await tester.tap(timeTarget());
    await tester.pump();
    await runTimerFor(tester, 12);
    await tester.tap(timeTarget()); // stop with a value
    await tester.pump();
    expect(lastRepsUnfocus().text, '1');

    await tester.longPress(timeTarget()); // reset
    await tester.pump();

    expect(lastRepsUnfocus().text, ''); // cleared
    expect(find.text('0:00'), findsOneWidget);
  });

  // ── Manual editor ─────────────────────────────────────────────────────────

  testWidgets('3. manual editor opens for a stopped/non-running set',
      (tester) async {
    await tester.pumpWidget(host(const Wes2SetState(setIndex: 0)));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoTimerPicker), findsOneWidget);
    expect(find.text('Edit time'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('4. existing stored time seeds the picker initial value',
      (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(actualValue: 90),
      ),
    ));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();

    final picker =
        tester.widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker));
    expect(picker.initialTimerDuration, const Duration(seconds: 90));
  });

  testWidgets(
      '5. hint seeds the picker; opening + cancelling does not create an actual',
      (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(hintValue: 45),
      ),
    ));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();

    final picker =
        tester.widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker));
    expect(picker.initialTimerDuration, const Duration(seconds: 45));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(changed.where((c) => c.key == Wes2FieldKey.reps), isEmpty);
    expect(unfocused.where((c) => c.key == Wes2FieldKey.reps), isEmpty);
    // Hint still shown, not promoted to an actual.
    expect(find.text('0:45'), findsOneWidget);
  });

  testWidgets('6. Done with 1:30 emits/saves "90" via onChanged + onUnfocused',
      (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(hintValue: 90),
      ),
    ));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done')); // no wheel change → keep 1:30
    await tester.pumpAndSettle();

    expect(changed.last, (key: Wes2FieldKey.reps, text: '90'));
    expect(lastRepsUnfocus().text, '90');
    expect(find.text('1:30'), findsOneWidget);
  });

  testWidgets('6b. picker sheet converts minutes:seconds to a total Duration',
      (tester) async {
    Duration? done;
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wes2ManualTimePickerSheet(
          initial: const Duration(seconds: 125), // 2:05
          onCancel: () => cancelled = true,
          onDone: (d) => done = d,
        ),
      ),
    ));

    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(done, const Duration(seconds: 125));
    expect(cancelled, isFalse);
  });

  testWidgets('7. Cancel makes no change', (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(actualValue: 90),
      ),
    ));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(changed.where((c) => c.key == Wes2FieldKey.reps), isEmpty);
    expect(unfocused.where((c) => c.key == Wes2FieldKey.reps), isEmpty);
    expect(find.text('1:30'), findsOneWidget);
  });

  testWidgets('8. Done at 0:00 clears the actual value and reveals the hint',
      (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(actualValue: 90, hintValue: 30),
      ),
    ));
    expect(find.text('1:30'), findsOneWidget);

    // Get the cell to a 0:00 base without dragging the wheel: activate + reset.
    await tester.tap(timeTarget());
    await tester.pump();
    await tester.longPress(timeTarget());
    await tester.pump();
    expect(find.text('0:00'), findsOneWidget); // active, value 0, hint hidden

    // Open the manual editor (seeded at 0:00) and confirm.
    await tester.tap(editIcon());
    await tester.pumpAndSettle();
    final picker =
        tester.widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker));
    expect(picker.initialTimerDuration, Duration.zero);

    changed.clear();
    unfocused.clear();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Zero → clear via the same callback path, and the editor drops the active
    // state so the hint shows through again (this is what distinguishes the
    // manual-clear branch from a plain long-press reset).
    expect(changed.last, (key: Wes2FieldKey.reps, text: ''));
    expect(lastRepsUnfocus().text, '');
    expect(find.text('0:30'), findsOneWidget); // hint restored
  });

  testWidgets('8b. sheet returns Duration.zero when initialised at 0:00',
      (tester) async {
    Duration? done;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wes2ManualTimePickerSheet(
          initial: Duration.zero,
          onCancel: () {},
          onDone: (d) => done = d,
        ),
      ),
    ));

    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(done, Duration.zero);
  });

  testWidgets('9. edit control cannot modify a currently running timer',
      (tester) async {
    await tester.pumpWidget(host(const Wes2SetState(setIndex: 0)));

    await tester.tap(timeTarget()); // activate
    await tester.pump();
    await tester.tap(timeTarget()); // run
    await tester.pump();
    await runTimerFor(tester, 5);

    // Disabled while running.
    expect(
      tester.widget<IconButton>(find.ancestor(
        of: editIcon(),
        matching: find.byType(IconButton),
      )).onPressed,
      isNull,
    );
    await tester.tap(editIcon(), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(CupertinoTimerPicker), findsNothing);

    await tester.tap(timeTarget()); // stop — now editable again
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.ancestor(
        of: editIcon(),
        matching: find.byType(IconButton),
      )).onPressed,
      isNotNull,
    );
  });

  testWidgets('10. timer resumes from a manually entered value', (tester) async {
    await tester.pumpWidget(host(
      const Wes2SetState(
        setIndex: 0,
        reps: Wes2FieldState<int>(hintValue: 90),
      ),
    ));

    await tester.tap(editIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done')); // commit 1:30
    await tester.pumpAndSettle();
    expect(lastRepsUnfocus().text, '90');

    await tester.tap(timeTarget()); // resume from 1:30
    await tester.pump();
    await runTimerFor(tester, 12); // ~1.2 s

    await tester.tap(timeTarget()); // stop
    await tester.pump();

    expect(int.parse(lastRepsUnfocus().text), greaterThanOrEqualTo(91));
  });

  // ── Both timed render modes ───────────────────────────────────────────────

  for (final mode in [
    Wes2ExerciseEntryMode.timedBodyweight,
    Wes2ExerciseEntryMode.timedWeighted,
  ]) {
    testWidgets('11. manual edit works in $mode row rendering', (tester) async {
      await tester.pumpWidget(host(
        const Wes2SetState(
          setIndex: 0,
          reps: Wes2FieldState<int>(hintValue: 90),
        ),
        mode: mode,
      ));

      expect(editIcon(), findsOneWidget);

      await tester.tap(editIcon());
      await tester.pumpAndSettle();
      final picker = tester
          .widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker));
      expect(picker.initialTimerDuration, const Duration(seconds: 90));

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(lastRepsUnfocus().text, '90');
      expect(find.text('1:30'), findsOneWidget);
    });
  }
}

class _Host extends StatefulWidget {
  final Wes2SetState initial;
  final Wes2ExerciseEntryMode mode;
  final void Function(Wes2FieldKey, String) onChanged;
  final void Function(Wes2FieldKey, String) onUnfocused;

  const _Host({
    required this.initial,
    required this.mode,
    required this.onChanged,
    required this.onUnfocused,
  });

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Wes2SetState _set = widget.initial;

  void _apply(Wes2FieldKey key, String raw) {
    if (key != Wes2FieldKey.reps) return;
    final t = raw.trim();
    final v = t.isEmpty ? null : int.tryParse(t);
    setState(() => _set = _set.copyWith(reps: _set.reps.withActual(v)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Wes2SetRow(
            set: _set,
            showVelocity: false,
            entryMode: widget.mode,
            bwDisplayText: widget.mode == Wes2ExerciseEntryMode.timedBodyweight
                ? '80 kg'
                : null,
            onFieldChanged: (k, v) => widget.onChanged(k, v),
            onFieldUnfocused: (k, v) {
              widget.onUnfocused(k, v);
              _apply(k, v);
            },
          ),
        ),
      ),
    );
  }
}
