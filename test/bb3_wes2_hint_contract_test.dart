// BB3 ⇄ WES2 hint contract — field-level prescription locking and the
// canonical active training instance (option A).
//
// Drives the PRODUCTION hint service (Wes2HintServiceImpl.resolveRow) with
// real history in PeriodizationModelUtils, exactly as WES2 does. No hint
// arithmetic is restated here: every expectation is either a stored plan value
// the correct instance must select, or an equivalence between two production
// paths (a value typed in WES2 vs the same value arriving as a BB3
// prescription).
//
// Contract under test:
//   * A BB3 value locks only its own field. Free siblings are solved from the
//     day's history target exactly as if the same value had been typed in
//     WES2; only the provenance of the locked field differs (BB3 prescription,
//     not a WES2 actual).
//   * A configured fallback rep target never replaces a successful history
//     solve.
//   * The rep target and the RIR both come from ONE active exposure position:
//     distinct valid completed exposure dates strictly before the selected
//     date. Rep slot = position % instance count; RIR session = position %
//     session count (each wraps over its own configured length). The weekday
//     position (`days % 7`) and missing-key fallbacks are never used.
//   * DUP, By Week and linear models are unchanged.
//
// See test/support/bb3_wes2_instance_fixture.dart for the fixture and why the
// selected date is a Sunday.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/active_instance.dart';
import 'package:localtest222/bb3_hint_service.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/units/weight_unit.dart';
import 'package:localtest222/wes2_hint_input.dart';

import 'support/bb3_wes2_instance_fixture.dart';

/// Set-by-set shown values, for readable failure messages.
String describe(Wes2ExerciseRow r) => r.sets
    .map((Wes2SetState s) =>
        '${shown(s.weight)}x${shown(s.reps)}@${shown(s.rir)}')
    .join(' | ');

/// The free (non-prescribed) fields of every set, as shown.
List<Object?> freeView(Wes2ExerciseRow r, {required Set<Wes2FieldKey> locked}) {
  final List<Object?> out = <Object?>[];
  for (final Wes2SetState s in r.sets) {
    final bool first = s.setIndex == 0;
    out.add(
        first && locked.contains(Wes2FieldKey.weight) ? '·' : shown(s.weight));
    out.add(first && locked.contains(Wes2FieldKey.reps) ? '·' : shown(s.reps));
    out.add(first && locked.contains(Wes2FieldKey.rir) ? '·' : shown(s.rir));
  }
  return out;
}

List<double?> rirHints(Wes2ExerciseRow r) =>
    r.sets.map((Wes2SetState s) => s.rir.hintValue).toList();

void main() {
  setUp(() => seedHistory(history()));
  tearDown(clearHistory);

  // ─────────────────────────────────────────────────────────────────────────
  group('fixture sanity — the history path is genuinely active', () {
    test('the unconstrained Set 1 is a history solve, not a default', () {
      final Wes2ExerciseRow r =
          resolve(hintService(allSettings()), plannedRow());
      final Wes2SetState s1 = r.sets.first;
      expect(s1.weight.hintValue, isNotNull);
      expect(s1.reps.hintValue, isNotNull);
      // History sits around 95–102.5 kg; a default/plan fill would not.
      expect(s1.weight.hintValue!, greaterThan(90));
      expect(s1.reps.hintValue, isNot(kFallbackInstance1Reps),
          reason: 'the unconstrained hint must come from history');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('BB3 weight-only prescription with real history', () {
    late double w;
    setUp(() {
      w = resolve(hintService(allSettings()), plannedRow())
              .sets
              .first
              .weight
              .hintValue! +
          5;
    });

    test('free reps/RIR equal the result of typing the same weight in WES2',
        () {
      final svc = hintService(allSettings());
      final bb3 = resolve(svc, plannedRow(),
          prescriptions: set1Prescription(weight: w));
      final typed = resolve(svc, withTypedSet1(plannedRow(), weight: w));
      expect(bb3.sets.first.reps.hintValue, typed.sets.first.reps.hintValue,
          reason: 'BB3 ${describe(bb3)}\ntyped ${describe(typed)}');
      expect(bb3.sets.first.rir.hintValue, typed.sets.first.rir.hintValue);
    });

    test('the configured fallback rep target never replaces the history solve',
        () {
      final svc = hintService(allSettings());
      final bb3 = resolve(svc, plannedRow(),
          prescriptions: set1Prescription(weight: w));
      final int reps = bb3.sets.first.reps.hintValue!;
      expect(reps, isNot(kFallbackInstance1Reps),
          reason: 'instance1 ($kFallbackInstance1Reps) is a fallback, '
              'not the solved rep: ${describe(bb3)}');
    });

    test('the resulting E1RM stays at the day\'s target (within one rep)', () {
      final svc = hintService(allSettings());
      final pure = resolve(svc, plannedRow()).sets.first;
      final double target = e1rm(pure.weight.hintValue!, pure.reps.hintValue!,
          pure.rir.hintValue ?? 0);
      final bb3 =
          resolve(svc, plannedRow(), prescriptions: set1Prescription(weight: w))
              .sets
              .first;
      final double rir = bb3.rir.hintValue ?? 0;
      final double got = e1rm(w, bb3.reps.hintValue!, rir);
      final double oneRep = e1rm(w, bb3.reps.hintValue! + 1, rir) -
          e1rm(w, bb3.reps.hintValue!, rir);
      expect((got - target).abs(), lessThanOrEqualTo(oneRep),
          reason: 'target ${target.toStringAsFixed(1)} vs BB3 '
              '${got.toStringAsFixed(1)} (${describe(resolve(svc, plannedRow(), prescriptions: set1Prescription(weight: w)))})');
    });

    test('the prescribed weight is shown exactly and keeps BB3 provenance', () {
      final bb3 = resolve(hintService(allSettings()), plannedRow(),
          prescriptions: set1Prescription(weight: w));
      final Wes2SetState s1 = bb3.sets.first;
      expect(s1.weight.hintValue, w);
      expect(s1.weight.actualValue, isNull,
          reason: 'a prescription is never turned into an actual');
      expect(s1.weight.hintOrigin, FieldOrigin.bb3Hint);
      expect(s1.reps.hintOrigin, FieldOrigin.modelHint);
      expect(s1.rir.hintOrigin, FieldOrigin.modelHint);
    });

    test('Set 2+ cascade from the corrected Set 1 matches the typed path', () {
      final svc = hintService(allSettings());
      final bb3 = resolve(svc, plannedRow(),
          prescriptions: set1Prescription(weight: w));
      final typed = resolve(svc, withTypedSet1(plannedRow(), weight: w));
      for (int i = 1; i < bb3.sets.length; i++) {
        expect(shown(bb3.sets[i].weight), shown(typed.sets[i].weight),
            reason:
                'set ${i + 1}: BB3 ${describe(bb3)}\ntyped ${describe(typed)}');
        expect(shown(bb3.sets[i].reps), shown(typed.sets[i].reps));
        expect(shown(bb3.sets[i].rir), shown(typed.sets[i].rir));
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group(
      'every prescription combination: locked fields authoritative, '
      'free fields solved exactly as if typed', () {
    // Each combination: BB3 locks exactly these fields, and the free fields
    // (Set 1 siblings and every later set) must equal the WES2-typed result.
    final List<({String name, bool w, bool r, bool rir})> combos =
        <({String name, bool w, bool r, bool rir})>[
      (name: 'weight only', w: true, r: false, rir: false),
      (name: 'reps only', w: false, r: true, rir: false),
      (name: 'RIR only', w: false, r: false, rir: true),
      (name: 'weight + reps', w: true, r: true, rir: false),
      (name: 'weight + RIR', w: true, r: false, rir: true),
      (name: 'reps + RIR', w: false, r: true, rir: true),
      (name: 'weight + reps + RIR', w: true, r: true, rir: true),
    ];

    for (final c in combos) {
      test(c.name, () {
        final svc = hintService(allSettings());
        final double w =
            resolve(svc, plannedRow()).sets.first.weight.hintValue! + 5;
        const int reps = 7;
        const double rir = 2.0;
        final bb3 = resolve(svc, plannedRow(),
            prescriptions: set1Prescription(
                weight: c.w ? w : null,
                reps: c.r ? reps : null,
                rir: c.rir ? rir : null));
        final typed = resolve(
            svc,
            withTypedSet1(plannedRow(),
                weight: c.w ? w : null,
                reps: c.r ? reps : null,
                rir: c.rir ? rir : null));

        final Wes2SetState s1 = bb3.sets.first;
        // Locked: exact prescribed value, BB3 provenance, never an actual.
        if (c.w) {
          expect(s1.weight.hintValue, w);
          expect(s1.weight.hintOrigin, FieldOrigin.bb3Hint);
          expect(s1.weight.actualValue, isNull);
        }
        if (c.r) {
          expect(s1.reps.hintValue, reps);
          expect(s1.reps.hintOrigin, FieldOrigin.bb3Hint);
          expect(s1.reps.actualValue, isNull);
        }
        if (c.rir) {
          expect(s1.rir.hintValue, rir);
          expect(s1.rir.hintOrigin, FieldOrigin.bb3Hint);
          expect(s1.rir.actualValue, isNull);
        }
        // Free: identical to the typed path.
        final Set<Wes2FieldKey> locked = <Wes2FieldKey>{
          if (c.w) Wes2FieldKey.weight,
          if (c.r) Wes2FieldKey.reps,
          if (c.rir) Wes2FieldKey.rir,
        };
        expect(freeView(bb3, locked: locked), freeView(typed, locked: locked),
            reason: 'BB3   ${describe(bb3)}\ntyped ${describe(typed)}');
      });
    }
    // RIR-only keeps origin/main's plan rep target on BOTH paths (typed and
    // BB3 are asserted equal above). Switching RIR-only to the engine's reps
    // changed ordinary WES2 and was withdrawn; see
    // docs/wes2/specs/rir_models_next_pass_spec.md.
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('reload and provenance', () {
    test('a resolved row yields back exactly the BB3 prescriptions', () {
      final svc = hintService(allSettings());
      final bb3 = resolve(svc, plannedRow(),
          prescriptions: set1Prescription(weight: 111.0));
      final p = Wes2HintInput.prescriptionsFromRow(bb3);
      expect(p.at(0).weight, 111.0);
      expect(p.at(0).reps, isNull,
          reason: 'a generated rep hint is never promoted to a prescription');
      expect(p.at(0).rir, isNull);
      for (int i = 1; i < bb3.sets.length; i++) {
        expect(p.at(i).isEmpty, isTrue, reason: 'set ${i + 1}');
      }
      final round = Wes2Prescriptions.fromJson(p.toJson());
      expect(round.at(0).weight, 111.0);
      expect(round.at(0).reps, isNull);
    });

    test('resolving the reloaded row again changes nothing (idempotent)', () {
      final svc = hintService(allSettings());
      final first = resolve(svc, plannedRow(),
          prescriptions: set1Prescription(weight: 111.0));
      final second = resolve(svc, first,
          prescriptions: Wes2HintInput.prescriptionsFromRow(first));
      expect(describe(second), describe(first));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // WES2's rep instance follows the exposure count (unchanged). Its RIR
  // session is, deliberately for this pass, the EFFECTIVE origin/main
  // selection: block-relative weekday (days % 7), falling back to session1
  // when that sessionN is absent (and to RIR 1.0 for an absent setN). This is
  // pinned so BB3 can match it; it is NOT the final design of RIR Static —
  // Weekly. The exposure-based RIR expectations belong to the next RIR-model
  // feature: docs/wes2/specs/rir_models_next_pass_spec.md.
  group('WES2 active instance (origin/main effective selection)', () {
    test('Sunday, 4 prior exposures: instance2 set count, session1 RIR', () {
      final r = resolve(hintService(allSettings()), plannedRow());
      expect(r.setCount, 4, reason: "instance2 is '5 x 4'");
      expect(rirHints(r), <double>[...kSessionRir[1]!, 1.0],
          reason: 'weekday 6 has no session7 → session1; set4 → 1.0: '
              '${describe(r)}');
    });

    test('Tuesday, 2 prior exposures: instance3 set count, session2 RIR', () {
      // 2026-01-13 (days % 7 = 1). Prior exposures 01-06, 01-09 → instance3.
      // History also holds the selected date itself and 01-16: neither counts.
      final day = DateTime(2026, 1, 13);
      final r = resolve(hintService(allSettings()), plannedRow(setCount: 5),
          date: day);
      expect(r.setCount, 5, reason: "instance3 is '3 x 5'");
      expect(rirHints(r), <double>[...kSessionRir[2]!, 1.0],
          reason: describe(r));
    });

    test(
        'a workout already logged on the selected date does not move the '
        'instance or the RIR session', () {
      final without = resolve(hintService(allSettings()), plannedRow());
      seedHistory(history(extra: <Map<String, dynamic>>[
        workout('2026-01-25', weight: 104),
      ]));
      final withToday = resolve(hintService(allSettings()), plannedRow());
      expect(withToday.setCount, without.setCount);
      expect(rirHints(withToday), rirHints(without));
    });

    test('later exposures never change an earlier selected date', () {
      final without = resolve(hintService(allSettings()), plannedRow());
      seedHistory(history(extra: <Map<String, dynamic>>[
        workout('2026-01-27', weight: 130),
        workout('2026-01-30', weight: 140),
      ]));
      final withLater = resolve(hintService(allSettings()), plannedRow());
      expect(describe(withLater), describe(without));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Exercise-performance history feeding the target E1RM (progression top
  // sets) and the exposure position is STRICTLY BEFORE the selected date: the
  // selected workout — partially logged, saved, reopened or completed — never
  // feeds back into its own Set-1 target. Bodyweight measurements are NOT
  // exercise-performance history: a weigh-in on the selected date still
  // converts that date's bodyweight-exercise loads.
  group('selected-date target history is strictly before the selected date',
      () {
    ({
      double w,
      int r,
      double rir,
      double target,
      int count,
      List<double?> rirs
    }) baseline() {
      final Wes2ExerciseRow row =
          resolve(hintService(allSettings()), plannedRow());
      final Wes2SetState s1 = row.sets.first;
      final double w = s1.weight.hintValue!;
      final int r = s1.reps.hintValue!;
      final double rir = s1.rir.hintValue ?? 0;
      return (
        w: w,
        r: r,
        rir: rir,
        target: e1rm(w, r, rir),
        count: row.setCount,
        rirs: rirHints(row),
      );
    }

    test(
        'an extreme performance ON the selected date changes nothing about '
        'that date\'s baseline', () {
      final before = baseline();
      // Same set shape (5 reps @ RIR 2) as the prior history, so the engine
      // genuinely consumes it; an off-shape set would be ignored anyway and
      // make this test vacuous.
      seedHistory(history(extra: <Map<String, dynamic>>[
        workout('2026-01-25', weight: 200, reps: 5, rir: 2),
      ]));
      final after = baseline();
      expect(after.target, before.target,
          reason: 'the selected workout fed its own target E1RM: '
              '${before.target.toStringAsFixed(1)} → '
              '${after.target.toStringAsFixed(1)}');
      expect((after.w, after.r, after.rir), (before.w, before.r, before.rir),
          reason: 'unconstrained Set-1 hint moved');
      expect(after.count, before.count, reason: 'exposure position moved');
      expect(after.rirs, before.rirs, reason: 'exposure position moved');
    });

    test('a later-date performance cannot affect the earlier selected date',
        () {
      final before = baseline();
      seedHistory(history(extra: <Map<String, dynamic>>[
        workout('2026-01-26', weight: 200, reps: 5, rir: 2),
      ]));
      final after = baseline();
      expect(after.target, before.target);
      expect((after.w, after.r, after.rir), (before.w, before.r, before.rir));
      expect(after.count, before.count);
      expect(after.rirs, before.rirs);
    });

    test('a prior-date performance still moves the selected date\'s target',
        () {
      final before = baseline();
      seedHistory(history(extra: <Map<String, dynamic>>[
        workout('2026-01-20', weight: 130, reps: 5, rir: 2),
      ]));
      final after = baseline();
      expect(after.target, greaterThan(before.target),
          reason: 'history strictly before the selected date must still '
              'drive progression');
    });

    group('bodyweight measured ON the selected date is still used', () {
      const String chinId = 'XM9026peNIu0R8qh7UqY';
      const String chinName = 'Chin-Up';

      void recordBodyweights(Map<DateTime, double> byDay) {
        PeriodizationModelUtils.setBodyweightHistory(
            uid: kUid,
            entries: <Map<String, dynamic>>[
              for (final MapEntry<DateTime, double> e in byDay.entries)
                <String, dynamic>{
                  'date': DateTime(e.key.year, e.key.month, e.key.day, 12),
                  'weight': e.value,
                  'unit': 'kg',
                },
            ]);
      }

      tearDown(() => PeriodizationModelUtils.setBodyweightHistory(
          uid: kUid, entries: const <Map<String, dynamic>>[]));

      test('load conversion on the selected date uses that day\'s weigh-in',
          () {
        recordBodyweights(<DateTime, double>{
          DateTime(2026, 1, 20): 75,
          kSelected: 80,
        });
        final double abs = PeriodizationModelUtils.toAbsoluteWeight(
          uid: kUid,
          displayAddedKg: 10,
          exerciseId: chinId,
          exerciseName: chinName,
          exerciseType: 'Body Weight',
          asOfDate: kSelected,
        );
        expect(abs, 90, reason: '10 kg added + 80 kg weighed on the day');
      });

      test('a selected-date weigh-in changes the bodyweight exercise hint', () {
        seedHistory(history(exerciseId: chinId, name: chinName));
        final svc = hintService(
            allSettings(exerciseId: chinId, settings: exerciseSettingsFor()));
        final row = plannedRow(
            exerciseId: chinId, name: chinName, exerciseType: 'Body Weight');

        recordBodyweights(<DateTime, double>{
          DateTime(2026, 1, 1): 80,
          kSelected: 60,
        });
        final light = resolve(svc, row).sets.first.weight.hintValue;
        recordBodyweights(<DateTime, double>{
          DateTime(2026, 1, 1): 80,
          kSelected: 100,
        });
        final heavy = resolve(svc, row).sets.first.weight.hintValue;
        expect(light, isNotNull);
        expect(heavy, isNotNull);
        expect(light, isNot(heavy),
            reason: 'the added-load hint must reflect the bodyweight '
                'recorded on the selected date');
      });
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('pounds display', () {
    // 15 lb primary increment, stored canonically in kg.
    final Map<String, dynamic> lbSettings = exerciseSettingsFor(
        increments: <String, dynamic>{'primary': 6.80388555});

    bool isWhole15Lb(double kg) {
      final double lb = ExerciseWeightUnit.lb.fromKg(kg);
      return (lb - (lb / 15).round() * 15).abs() < 1e-6;
    }

    // Exact numeric handling is scoped to BB3 and BB3-prescription paths in
    // this pass; ordinary WES2 pound precision is addressed separately.
    test(
        'BB3-prescribed row: the solved free weight on a 15 lb grid is an '
        'exact multiple of 15 lb', () {
      final r = resolve(
          hintService(allSettings(settings: lbSettings)), plannedRow(),
          prescriptions: set1Prescription(reps: 7));
      final double kg = r.sets.first.weight.hintValue!;
      expect(isWhole15Lb(kg), isTrue,
          reason: '${formatWeightNumber(ExerciseWeightUnit.lb.fromKg(kg))} lb '
              '($kg kg) is not a clean grid value');
      expect(formatWeightNumber(ExerciseWeightUnit.lb.fromKg(kg)),
          isNot(contains('.')));
    });

    test('BB3-prescribed row: Set 2+ hints stay on the pound grid too', () {
      final r = resolve(
          hintService(allSettings(settings: lbSettings)), plannedRow(),
          prescriptions: set1Prescription(reps: 7));
      for (final Wes2SetState s in r.sets) {
        expect(isWhole15Lb(s.weight.hintValue!), isTrue,
            reason: 'set ${s.setIndex + 1}: '
                '${ExerciseWeightUnit.lb.fromKg(s.weight.hintValue!)} lb');
      }
    });

    test('ordinary WES2 row keeps origin/main pound behaviour (unchanged)', () {
      final r =
          resolve(hintService(allSettings(settings: lbSettings)), plannedRow());
      final double kg = r.sets.first.weight.hintValue!;
      // origin/main reads the 2-decimal kg display string.
      expect(kg, double.parse(kg.toStringAsFixed(2)));
    });

    test('a BB3 pound prescription (285 lb) is shown exactly as prescribed',
        () {
      const double kg285 = 285 * 0.45359237;
      final r = resolve(
          hintService(allSettings(settings: lbSettings)), plannedRow(),
          prescriptions: set1Prescription(weight: kg285));
      expect(
          formatWeightNumber(
              ExerciseWeightUnit.lb.fromKg(r.sets.first.weight.hintValue!)),
          '285');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // BB3 RIR stays numeric through the BB3 and BB3-prescription path (1.25 is
  // never formatted to "1.3" and parsed back). Ordinary WES2 plan-RIR
  // behaviour is unchanged in this pass.
  group('numeric RIR on the BB3 path', () {
    // Sunday → effective session1; its Set-1 RIR is a quarter value.
    final Map<String, dynamic> quarterSettings =
        exerciseSettingsFor(sessionRir: <int, List<double>>{
      1: <double>[1.25, 1.75, 2.25],
      2: <double>[1.0, 1.5, 2.0, 2.5],
      3: <double>[0.5, 1.0, 1.5, 2.0, 2.5],
    });

    test('BB3HintService carries the exact RIR beside its display string', () {
      final h = BB3HintService.getHintsForSet(
        exerciseId: kExId,
        exerciseName: kExName,
        fullExerciseSettings: allSettings(settings: quarterSettings),
        weekIndex: 2,
        sessionIndex: 1,
        rirSessionIndex: 6, // weekday: no session7 → session1
        setIndex: 0,
        blockStartDate: kBlockStart,
        blockEndDate: kBlockEnd,
        selectedDate: kSelected,
        uid: kUid,
      );
      expect(h.rirValue, 1.25);
      expect(h.rirDisplay, '1.3', reason: 'the display string is unchanged');
    });

    test('a BB3-prescribed row solves its free RIR to exactly 1.25', () {
      final r = resolve(
          hintService(allSettings(settings: quarterSettings)), plannedRow(),
          prescriptions: set1Prescription(reps: 7));
      expect(r.sets.first.rir.hintValue, 1.25);
    });

    test('a BB3-prescribed RIR of 1.25 survives exactly', () {
      final r = resolve(
          hintService(allSettings(settings: quarterSettings)), plannedRow(),
          prescriptions: set1Prescription(weight: 100, rir: 1.25));
      expect(r.sets.first.rir.hintValue, 1.25);
      expect(r.sets.first.rir.hintOrigin, FieldOrigin.bb3Hint);
    });

    test('ordinary WES2 row keeps origin/main plan-RIR parsing (unchanged)',
        () {
      final r = resolve(
          hintService(allSettings(settings: quarterSettings)), plannedRow());
      expect(r.sets.first.rir.hintValue, 1.3);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // BB3's Set-1 hint for a DUP, By Exposure row uses the resolved exposure
  // position for its rep instance and the EFFECTIVE WES2 RIR selection
  // (block-relative weekday) for its RIR — so on a day with no intervening
  // plans it equals WES2's ordinary Set-1 hint.
  group('BB3 and WES2 show the same Set-1 hint', () {
    test('Sunday: BB3 indices reproduce WES2 weight, reps and RIR', () {
      final wes2 = resolve(hintService(allSettings()), plannedRow()).sets.first;
      final ActiveInstance active = ActiveInstanceResolver.forSettings(
        exSettings: exerciseSettingsFor(),
        exposurePosition: ActiveInstanceResolver.exposurePosition(
          selectedDate: kSelected,
          completedDates: kPriorExposureDates,
          blockStartDate: kBlockStart,
        ),
        weekIndex: 2,
      );
      final int weekday = kSelected.difference(kBlockStart).inDays % 7;
      final bb3 = BB3HintService.getHintsForSet(
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
        selectedDate: kSelected,
        uid: kUid,
      );
      expect(bb3.weightKg, wes2.weight.hintValue);
      expect(int.parse(bb3.repsDisplay), wes2.reps.hintValue);
      expect(bb3.rirValue, wes2.rir.hintValue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('bodyweight and timed safety', () {
    const String chinId = 'XM9026peNIu0R8qh7UqY';
    const String chinName = 'Chin-Up';

    test(
        'bodyweight: a BB3 added-load prescription solves like the typed '
        'added load', () {
      seedHistory(history(exerciseId: chinId, name: chinName));
      final svc = hintService(
          allSettings(exerciseId: chinId, settings: exerciseSettingsFor()));
      final row = plannedRow(
          exerciseId: chinId, name: chinName, exerciseType: 'Body Weight');
      const double added = 12.5;
      final bb3 =
          resolve(svc, row, prescriptions: set1Prescription(weight: added));
      final typed = resolve(svc, withTypedSet1(row, weight: added));
      expect(bb3.sets.first.weight.hintValue, added,
          reason: 'the ADDED load is shown as prescribed');
      expect(freeView(bb3, locked: <Wes2FieldKey>{Wes2FieldKey.weight}),
          freeView(typed, locked: <Wes2FieldKey>{Wes2FieldKey.weight}),
          reason: 'BB3 ${describe(bb3)}\ntyped ${describe(typed)}');
    });

    test(
        'timed: a BB3 weight on a weighted timed exercise keeps seconds and '
        'no RIR, exactly as typed', () {
      const String timedId = 'DTkkN5pi05RWQyNYhizQ'; // Weighted Plank
      const String timedName = 'Weighted Plank';
      seedHistory(history(exerciseId: timedId, name: timedName));
      final settings = exerciseSettingsFor(
          model: 'Linear, Classic',
          repTargetsWeek1: <String, dynamic>{'instance1': '9 x 3'});
      final svc =
          hintService(allSettings(exerciseId: timedId, settings: settings));
      final row = plannedRow(setCount: 3, exerciseId: timedId, name: timedName);
      final bb3 =
          resolve(svc, row, prescriptions: set1Prescription(weight: 10));
      final typed = resolve(svc, withTypedSet1(row, weight: 10));
      expect(bb3.sets.first.reps.hintValue, 45,
          reason: '9 plan reps are 45 seconds');
      expect(bb3.sets.first.rir.hintValue, isNull);
      expect(freeView(bb3, locked: <Wes2FieldKey>{Wes2FieldKey.weight}),
          freeView(typed, locked: <Wes2FieldKey>{Wes2FieldKey.weight}));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Characterisation: the pre-change output of the two model families this
  // work must NOT alter, pinned on the same fixture and history.
  group('DUP, By Week and linear models are unchanged', () {
    final Map<String, Map<String, String>> expected =
        <String, Map<String, String>>{
      'DUP, By Week': <String, String>{
        '2026-01-20': '82.5x12@1.0 | 80.0x12@1.5 | 80.0x12@1.5 | 80.0x12@1.5',
        '2026-01-21': '85.0x12@0.5 | 82.5x12@1.0 | 82.5x12@1.0 | 82.5x12@1.0',
        '2026-01-25': '80.0x12@2.5 | 75.0x13@3.0 | 75.0x13@3.0 | 75.0x13@3.0',
      },
      'Linear, Classic': <String, String>{
        '2026-01-20': '90.0x10@1.0 | 87.5x10@1.5 | 85.0x10@2.0 | 82.5x10@2.5',
        '2026-01-21':
            '95.0x9@0.5 | 92.5x9@1.0 | 90.0x9@1.5 | 87.5x9@2.0 | 85.0x9@2.5',
        '2026-01-25': '82.5x11@2.5 | 77.5x12@3.0 | 77.5x12@3.0 | 77.5x12@3.0',
      },
    };
    for (final MapEntry<String, Map<String, String>> m in expected.entries) {
      for (final MapEntry<String, String> d in m.value.entries) {
        test('${m.key} on ${d.key}', () {
          final List<String> p = d.key.split('-');
          final r = resolve(
              hintService(
                  allSettings(settings: exerciseSettingsFor(model: m.key))),
              plannedRow(),
              date:
                  DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2])));
          expect(describe(r), d.value);
        });
      }
    }
  });
}
