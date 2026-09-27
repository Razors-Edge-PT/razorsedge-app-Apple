// BB3 first render with the viewed athlete's progression history not yet
// authoritative (DUP, By Exposure / DUP, Signature rows only).
//
// Contract:
//   * Nothing waits for history: the gate's ensure() returns immediately and
//     the panel renders with the hydration future still unresolved.
//   * While unresolved, exposure rows show NO weight / reps / RIR hint — never
//     a guessed lower-position or default value that is later replaced.
//   * Hydration is started (or joined) once per athlete; completion triggers
//     exactly one readiness callback, and the released panel shows the
//     correct hint with no user interaction.
//   * Readiness requires the history to be the VIEWED athlete's.
//   * Non-exposure rows are unaffected.

import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/active_instance.dart';
import 'package:localtest222/bb3_day_panel.dart';
import 'package:localtest222/bb3_hint_service.dart';
import 'package:localtest222/bb3_history_gate.dart';
import 'package:localtest222/bb3_models.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/units/weight_unit.dart';

import 'support/bb3_wes2_instance_fixture.dart';

void main() {
  // ── The gate ──────────────────────────────────────────────────────────────
  group('Bb3HistoryGate', () {
    test('ensure() never blocks and hydrates at most once per athlete',
        () async {
      final Completer<void> hydration = Completer<void>();
      int calls = 0;
      bool ready = false;
      int readyCallbacks = 0;
      final gate = Bb3HistoryGate(
        isReady: (_) => ready,
        hydrate: (_) {
          calls++;
          return hydration.future;
        },
      );
      gate.ensure('athlete', () => readyCallbacks++);
      gate.ensure('athlete', () => readyCallbacks++);
      gate.ensure('athlete', () => readyCallbacks++);
      expect(calls, 1,
          reason: 'one hydration per athlete, however often asked');
      expect(gate.isReady('athlete'), isFalse);
      await pumpEventQueue();
      expect(readyCallbacks, 0, reason: 'nothing fires while unresolved');

      ready = true;
      hydration.complete();
      await pumpEventQueue();
      expect(readyCallbacks, 1, reason: 'exactly one rebuild signal');
    });

    test('already-ready history is not re-hydrated', () {
      int calls = 0;
      final gate =
          Bb3HistoryGate(isReady: (_) => true, hydrate: (_) async => calls++);
      gate.ensure('athlete', () {});
      expect(calls, 0);
    });

    test('a failed hydration signals nothing and may be retried later',
        () async {
      int calls = 0;
      int readyCallbacks = 0;
      final gate = Bb3HistoryGate(
        isReady: (_) => false,
        hydrate: (_) {
          calls++;
          return Future<void>.error(StateError('offline'));
        },
      );
      gate.ensure('athlete', () => readyCallbacks++);
      await pumpEventQueue();
      gate.ensure('athlete', () => readyCallbacks++);
      await pumpEventQueue();
      expect(calls, 2);
      expect(readyCallbacks, 0);
    });

    test('readiness is per athlete (coach viewing an athlete)', () {
      final gate = Bb3HistoryGate(
          isReady: (String uid) => uid == 'coach', hydrate: (_) async {});
      expect(gate.isReady('coach'), isTrue);
      expect(gate.isReady('athlete'), isFalse,
          reason: "the coach's own history is not the athlete's");
    });
  });

  // ── The panel ─────────────────────────────────────────────────────────────
  group('BB3DayPanel withholds exposure hints until history is ready', () {
    setUp(() {
      ExerciseUnitRegistry.shared =
          ExerciseUnitRegistry(firestore: FakeFirebaseFirestore());
      seedHistory(history());
    });
    tearDown(clearHistory);

    final DateTime date = kSelected; // Sunday, block-relative weekday 6
    const int weekday = 6;
    final ActiveInstance active = ActiveInstanceResolver.forSettings(
      exSettings: exerciseSettingsFor(),
      exposurePosition: 4,
      weekIndex: 2,
    );

    BB3SetHint expectedHint() => BB3HintService.getHintsForSet(
          exerciseId: kExId,
          exerciseName: kExName,
          fullExerciseSettings: allSettings(),
          weekIndex: 2,
          sessionIndex: active.repInstanceIndex,
          rirSessionIndex: weekday,
          exposurePosition: active.exposurePosition,
          setIndex: 0,
          blockStartDate: kBlockStart,
          blockEndDate: kBlockEnd,
          selectedDate: date,
          uid: kUid,
        );

    Future<void> pumpPanel(WidgetTester tester,
        {required bool withheld}) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BB3DayPanel(
              key: ValueKey<bool>(withheld),
              dayIndex: weekday,
              date: date,
              plannedExercises: <BB3Exercise>[
                BB3Exercise(
                  exerciseId: kExId,
                  name: kExName,
                  circuitIndex: 0,
                  orderIndex: 0,
                  sets: List<BB3Set>.generate(4, (_) => const BB3Set()),
                ),
              ],
              completedExercises: const <Map<String, dynamic>>[],
              blockSettings: BB3BlockSettings(
                blockId: kBlockId,
                startDate: kBlockStart,
                endDate: kBlockEnd,
                exerciseSettings: allSettings(),
              ),
              weekIndex: 2,
              sessionIndex: 0,
              sessionIndexByExerciseId: <String, int>{
                kExId: active.repInstanceIndex,
              },
              activeInstanceByExerciseId: <String, ActiveInstance>{
                kExId: active,
              },
              hintsWithheldExerciseIds: withheld ? <String>{kExId} : null,
              uid: kUid,
              allExercises: const <Map<String, dynamic>>[],
              templates: const [],
              onSave: (_, __) async {},
              onDrop: (_, __, ___) {},
              onMoveAllToNextDay: (_) {},
              isInsideBlock: true,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('unresolved history: the panel renders, with no guessed hint',
        (WidgetTester tester) async {
      final BB3SetHint h = expectedHint();
      final String weightText = formatWeightNumber(h.weightKg!);
      await pumpPanel(tester, withheld: true);
      expect(find.byType(BB3DayPanel), findsOneWidget,
          reason: 'the page renders without waiting for history');
      expect(find.text(kExName), findsWidgets,
          reason: 'the exercise row itself is shown');
      expect(find.text(weightText), findsNothing,
          reason: 'no weight hint while history is not authoritative');
      expect(tester.takeException(), isNull);
    });

    testWidgets('history ready: the correct hint is shown', (tester) async {
      final BB3SetHint h = expectedHint();
      await pumpPanel(tester, withheld: false);
      expect(find.text(formatWeightNumber(h.weightKg!)), findsWidgets,
          reason: 'Set 1 weight hint from the resolved instance');
      expect(tester.takeException(), isNull);
    });
  });
}
