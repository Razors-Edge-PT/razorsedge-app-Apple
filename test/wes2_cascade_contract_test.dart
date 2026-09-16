// The hint contract, driven through the production controller and the real
// hint service — the same pair the screen wires together.
//
// Each subsequent set must consume the preceding set's FINAL current mixture
// of actuals and hints; an edit must update its own set's siblings first and
// then propagate forward only; nothing may drift when the same inputs are
// recalculated again.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/wes2_cascade_resolver.dart';

import 'support/wes2_expected_next_set.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings({int sets = 3}) => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '10 x $sets'},
          'week2': <String, dynamic>{'instance1': '10 x $sets'},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                for (int i = 1; i <= sets; i++)
                  'set$i': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

List<Map<String, dynamic>> _history() => <Map<String, dynamic>>[
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

Wes2ExerciseRow _row(int setCount, {bool established = false}) =>
    Wes2ExerciseRow(
      exerciseId: _exId,
      name: _exName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: setCount,
      source: Wes2RowSource.wes2Manual,
      structureEstablished: established,
      sets: List<Wes2SetState>.generate(
          setCount, (int i) => Wes2SetState(setIndex: i)),
    );

/// A controller wired the way the screen wires it at day load.
Wes2SessionController _load({int setCount = 3, bool established = false}) {
  final Wes2SessionController c = Wes2SessionController(_day)
    ..initIdentity(
      actorUid: _uid,
      actingUid: _uid,
      isCoach: false,
      activeBlockId: _blockId,
      blockStartDate: _blockStart,
      blockEndDate: null,
    )
    ..setExerciseSettings(_settings());
  final int epoch = c.beginLoad();
  c.setRows(<Wes2ExerciseRow>[_row(setCount, established: established)], epoch);
  c.applyHintContext(
    Wes2HintServiceImpl(
      exerciseSettings: _settings(),
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
    ),
    _blockId,
  );
  return c;
}

void _type(Wes2SessionController c, int i, Wes2FieldKey k, String v) =>
    c.updateSetField(
        exerciseId: _exId, setIndex: i, fieldKey: k, rawText: v);

Wes2SetState _s(Wes2SessionController c, int i) => c.rows.first.sets[i];

/// What the row shows for a set: actual if present, else hint.
String _shown(Wes2SetState s) {
  final v = Wes2CascadeResolver.resolvedValues(s);
  return '${v.weight}x${v.reps}@${v.rir}';
}

String _rowShown(Wes2SessionController c) =>
    c.rows.first.sets.map(_shown).join(' | ');

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = _history();
    PeriodizationModelUtils.topSetsByExercise.clear();
  });
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-MASK — all eight actual/hint combinations, at Set 1 and at Set 2, with
  // the following set observing the result.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-MASK — every actual/hint combination feeds the next set', () {
    for (final int target in const <int>[0, 1]) {
      for (int mask = 0; mask < 8; mask++) {
        final bool aw = mask & 1 != 0;
        final bool ar = mask & 2 != 0;
        final bool arir = mask & 4 != 0;
        final String name =
            '${aw ? 'A' : 'H'}${ar ? 'A' : 'H'}${arir ? 'A' : 'H'}';

        test('set ${target + 1} $name', () {
          final Wes2SessionController c = _load();
          if (aw) _type(c, target, Wes2FieldKey.weight, '32.5');
          if (ar) _type(c, target, Wes2FieldKey.reps, '9');
          if (arir) _type(c, target, Wes2FieldKey.rir, '1.5');

          final Wes2SetState edited = _s(c, target);
          // Entered values survive exactly; nothing is suppressed.
          if (aw) expect(edited.weight.actualValue, 32.5);
          if (ar) expect(edited.reps.actualValue, 9);
          if (arir) expect(edited.rir.actualValue, 1.5);

          // Every field the athlete did not enter still shows a hint.
          if (!aw) expect(edited.weight.hintValue, isNotNull);
          if (!ar) expect(edited.reps.hintValue, isNotNull);
          if (!arir) expect(edited.rir.hintValue, isNotNull);

          // The next set consumed exactly what this set SHOWS - asserted
          // against an independent reference model, not an inequality.
          final Wes2SetState next = _s(c, target + 1);
          final double nextRir = next.rir.actualValue ?? next.rir.hintValue!;
          final ExpectedNextSet expected = expectedNextSet(
            previousFinal: edited,
            thisRir: nextRir,
            grid: IncrementGrid(primary: 2.5),
          );
          expect(next.weight.hintValue, expected.weight,
              reason: 'set ${target + 2} weight must follow set '
                  '${target + 1}: $expected');
          expect(next.reps.hintValue, expected.reps,
              reason: 'set ${target + 2} reps must follow set '
                  '${target + 1}: $expected');

          // Provenance: the next set is hinted, not entered, and its RIR came
          // from the plan rather than being re-solved.
          expect(next.weight.actualValue, isNull);
          expect(next.reps.actualValue, isNull);
          expect(next.rir.actualValue, isNull);
          expect(next.weight.hintOrigin, FieldOrigin.modelHint);
          expect(next.rir.hintValue, 2.0);

          // And the values the reference consumed are the ones the edited set
          // displays, with the provenance the athlete gave them.
          final v = Wes2CascadeResolver.resolvedValues(edited);
          expect(v.weight, aw ? 32.5 : edited.weight.hintValue);
          expect(v.reps, ar ? 9 : edited.reps.hintValue);
          expect(v.rir, arir ? 1.5 : edited.rir.hintValue);
          expect(edited.weight.actualValue != null, aw);
          expect(edited.reps.actualValue != null, ar);
          expect(edited.rir.actualValue != null, arir);
        });
      }
    }

    test('an intermediate edit leaves earlier sets untouched', () {
      final Wes2SessionController c = _load();
      final Wes2SetState before = _s(c, 0);
      _type(c, 1, Wes2FieldKey.weight, '30');
      expect(identical(_s(c, 0), before), isTrue,
          reason: 'set 1 must be carried across, not recomputed');
    });

    test('later entries survive an earlier edit and still feed forward', () {
      final Wes2SessionController c = _load();
      _type(c, 2, Wes2FieldKey.weight, '25');
      _type(c, 2, Wes2FieldKey.reps, '12');
      _type(c, 0, Wes2FieldKey.weight, '42.5');
      expect(_s(c, 2).weight.actualValue, 25.0);
      expect(_s(c, 2).reps.actualValue, 12);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-PUBLISH — a stale load cannot install anything, prescriptions included.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-PUBLISH — rows and prescriptions are published together', () {
    Wes2Prescriptions pres(double w) => Wes2Prescriptions(
          sets: <Wes2PrescribedSet>[Wes2PrescribedSet(weight: w)],
        );

    test('a completion for an older epoch changes nothing at all', () {
      final Wes2SessionController c = _load();
      final Wes2Prescriptions current = c.prescriptionsFor(_exId);

      // Day A's load is in flight when the athlete moves to day B.
      final int epochA = c.beginLoad();
      final int epochB = c.beginLoad();
      expect(epochB, isNot(epochA));

      // Day A's rows are distinguishable, so their rejection is observable.
      final Wes2ExerciseRow rowA = Wes2ExerciseRow(
        exerciseId: 'ex_from_day_a',
        name: 'Day A exercise',
        circuitIndex: 0,
        orderIndex: 0,
        setCount: 3,
        source: Wes2RowSource.wes2Manual,
        sets: List<Wes2SetState>.generate(
            3, (int i) => Wes2SetState(setIndex: i)),
      );
      c.publishLoad(
        rows: <Wes2ExerciseRow>[rowA],
        prescriptions: <String, Wes2Prescriptions>{_exId: pres(99)},
        epoch: epochA,
      );

      expect(c.prescriptionsFor(_exId).at(0).weight, current.at(0).weight,
          reason: "a stale load must not install its day's prescriptions");
      expect(c.rows.any((Wes2ExerciseRow r) => r.exerciseId == 'ex_from_day_a'),
          isFalse,
          reason: 'and its rows are still rejected');
    });

    test('the current load publishes both', () {
      final Wes2SessionController c = _load();
      final int epoch = c.beginLoad();
      c.publishLoad(
        rows: <Wes2ExerciseRow>[_row(3)],
        prescriptions: <String, Wes2Prescriptions>{_exId: pres(99)},
        epoch: epoch,
      );
      expect(c.prescriptionsFor(_exId).at(0).weight, 99.0);
      expect(c.rows, hasLength(1));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-SIBLING / H-CLEAR — edits and clears update siblings, then propagate.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-SIBLING — an edit updates its own set first', () {
    test('a weight entry moves that set\'s own rep hint, then the next set',
        () {
      // Asserted on Set 2, where weight and reps are solved together. Set 1
      // keeps its planned rep target by design — the progression model owns
      // that decision — so a Set 1 entry shows up in the cascade instead
      // (covered by the test below).
      final Wes2SessionController c = _load();
      final int? repsBefore = _s(c, 1).reps.hintValue;
      final String thirdBefore = _shown(_s(c, 2));
      _type(c, 1, Wes2FieldKey.weight, '20');
      expect(_s(c, 1).reps.hintValue, isNot(repsBefore),
          reason: 'a much lighter weight must change this set\'s rep hint');
      expect(_shown(_s(c, 2)), isNot(thirdBefore),
          reason: 'and the set after it must follow');
    });

    test('a Set 1 weight entry propagates into Set 2', () {
      final Wes2SessionController c = _load();
      final String nextBefore = _shown(_s(c, 1));
      _type(c, 0, Wes2FieldKey.weight, '20');
      expect(_shown(_s(c, 1)), isNot(nextBefore));
    });

    test('clearing one field restores the current-context hint', () {
      final Wes2SessionController c = _load();
      final String before = _rowShown(c);
      _type(c, 0, Wes2FieldKey.weight, '20');
      _type(c, 0, Wes2FieldKey.weight, '');
      expect(_rowShown(c), before,
          reason: 'clearing must return the hints for the CURRENT context');
    });

    test('clearing every field returns the whole row to its free state', () {
      final Wes2SessionController c = _load();
      final String before = _rowShown(c);
      _type(c, 0, Wes2FieldKey.weight, '25');
      _type(c, 0, Wes2FieldKey.reps, '15');
      _type(c, 0, Wes2FieldKey.rir, '0');
      _type(c, 0, Wes2FieldKey.weight, '');
      _type(c, 0, Wes2FieldKey.reps, '');
      _type(c, 0, Wes2FieldKey.rir, '');
      expect(_rowShown(c), before);
    });

    test('RIR 0 is a real entry, not an absent one', () {
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '40');
      _type(c, 0, Wes2FieldKey.reps, '8');
      _type(c, 0, Wes2FieldKey.rir, '0');
      expect(_s(c, 0).rir.actualValue, 0.0);
      final withZero = _shown(_s(c, 1));
      _type(c, 0, Wes2FieldKey.rir, '3');
      expect(_shown(_s(c, 1)), isNot(withZero),
          reason: 'RIR 0 must have driven the cascade, not been ignored');
    });

    test('an entry equal to the hint is still consumed by the next set', () {
      // The old code suppressed it: the screen showed the entry while the next
      // set calculated from the hint it replaced.
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '30'); // moves Set 2's hints
      final double accepted = _s(c, 1).weight.hintValue!;
      _type(c, 1, Wes2FieldKey.weight, accepted.toString());
      expect(_s(c, 1).weight.actualValue, accepted);
      final v = Wes2CascadeResolver.resolvedValues(_s(c, 1));
      expect(v.weight, accepted);
      expect(_s(c, 2).weight.hintValue, isNotNull);
    });

    test('an entered RIR equal to its hint keeps actual-only authority', () {
      final Wes2SessionController c = _load();
      final double hintedRir = _s(c, 0).rir.hintValue!;
      _type(c, 0, Wes2FieldKey.rir, hintedRir.toString());
      expect(_s(c, 0).rir.actualValue, hintedRir,
          reason: 'the entry must reach the model, not be dropped as "same"');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-STABILITY — repeated recalculation, order independence, no drift.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-STABILITY — the same inputs always give the same hints', () {
    test('ten further passes over a fixed Set 1 change nothing', () {
      final Wes2SessionController c = _load(setCount: 5);
      _type(c, 0, Wes2FieldKey.weight, '15');
      _type(c, 0, Wes2FieldKey.reps, '30');
      _type(c, 0, Wes2FieldKey.rir, '0');
      final String after = _rowShown(c);
      for (int i = 0; i < 10; i++) {
        c.applyHintContext(
          Wes2HintServiceImpl(
            exerciseSettings: _settings(),
            blockStartDate: _blockStart,
            blockEndDate: null,
            uid: _uid,
          ),
          _blockId,
        );
        expect(_rowShown(c), after, reason: 'pass ${i + 1} drifted');
      }
    });

    test('adding a set does not disturb the existing ones', () {
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '25');
      final String before = _rowShown(c);
      c.addSet(_exId);
      final List<String> now =
          c.rows.first.sets.map(_shown).toList().sublist(0, 3);
      expect(now.join(' | '), before);
      expect(c.rows.first.setCount, 4);
    });

    test('entry order does not change the outcome', () {
      final Wes2SessionController a = _load();
      _type(a, 0, Wes2FieldKey.weight, '35');
      _type(a, 0, Wes2FieldKey.reps, '6');
      _type(a, 0, Wes2FieldKey.rir, '1');

      final Wes2SessionController b = _load();
      _type(b, 0, Wes2FieldKey.rir, '1');
      _type(b, 0, Wes2FieldKey.reps, '6');
      _type(b, 0, Wes2FieldKey.weight, '35');

      expect(_rowShown(a), _rowShown(b));
    });

    test('edit then revert returns the original row', () {
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '40');
      final String at40 = _rowShown(c);
      _type(c, 0, Wes2FieldKey.weight, '20');
      _type(c, 0, Wes2FieldKey.weight, '40');
      expect(_rowShown(c), at40);
    });

    test('a fresh controller with the same entries agrees', () {
      final Wes2SessionController a = _load();
      _type(a, 0, Wes2FieldKey.weight, '37.5');
      _type(a, 1, Wes2FieldKey.reps, '11');

      final Wes2SessionController b = _load();
      _type(b, 1, Wes2FieldKey.reps, '11');
      _type(b, 0, Wes2FieldKey.weight, '37.5');

      expect(_rowShown(a), _rowShown(b));
    });

    test("a set's own stale hint cannot feed its own recalculation", () {
      // Set 3 used to walk 15x14 -> 12.5x19 -> 10x22 across passes because its
      // previous output was an input to the next search.
      final Wes2SessionController c = _load(setCount: 5);
      _type(c, 0, Wes2FieldKey.weight, '15');
      _type(c, 0, Wes2FieldKey.reps, '30');
      _type(c, 0, Wes2FieldKey.rir, '0');
      final String third = _shown(_s(c, 2));
      for (int i = 0; i < 5; i++) {
        _type(c, 0, Wes2FieldKey.rir, '0'); // same value, recalculates again
        expect(_shown(_s(c, 2)), third);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-STRUCT — structural changes recalculate immediately.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-STRUCT — structural changes re-cascade at once', () {
    test('removing the middle set re-cascades the survivor', () {
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '25');
      _type(c, 0, Wes2FieldKey.reps, '12');
      _type(c, 1, Wes2FieldKey.weight, '20');
      _type(c, 1, Wes2FieldKey.reps, '20');
      c.removeSet(_exId, 1);

      expect(c.rows.first.setCount, 2);
      // The survivor now follows Set 1 directly.
      final Wes2SetState survivor = _s(c, 1);
      final v0 = Wes2CascadeResolver.resolvedValues(_s(c, 0));
      final double prevE1rm = PeriodizationModelUtils.calculateE1RM(
          v0.weight!, v0.reps!.toDouble(), v0.rir ?? 0);
      final double e1rm = PeriodizationModelUtils.calculateE1RM(
          survivor.weight.hintValue!,
          survivor.reps.hintValue!.toDouble(),
          survivor.rir.hintValue ?? 0);
      expect(e1rm, lessThanOrEqualTo(prevE1rm + 0.01),
          reason: 'the survivor kept hints from the set that was removed');
    });

    test('a hint pass never resurrects a removed set', () {
      final Wes2SessionController c = _load();
      c.removeSet(_exId, 1);
      expect(c.rows.first.setCount, 2);
      c.applyHintContext(
        Wes2HintServiceImpl(
          exerciseSettings: _settings(),
          blockStartDate: _blockStart,
          blockEndDate: null,
          uid: _uid,
        ),
        _blockId,
      );
      expect(c.rows.first.setCount, 2,
          reason: 'the planned count must not grow an established row back');
    });

    test('undo restores the set and re-cascades it', () {
      final Wes2SessionController c = _load();
      _type(c, 0, Wes2FieldKey.weight, '25');
      final String before = _rowShown(c);
      c.removeSet(_exId, 1);
      c.undo();
      expect(c.rows.first.setCount, 3);
      expect(_rowShown(c), before);
    });

    test('a plan-only row still takes its initial count from the plan', () {
      final Wes2SessionController c = _load(setCount: 1);
      expect(c.rows.first.setCount, 3,
          reason: 'a row with no established structure follows the plan');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-NO-HINT-TO-ACTUAL — a hint never becomes logged data by itself.
  // ───────────────────────────────────────────────────────────────────────────
  test('recalculation never turns a hint into an actual', () {
    final Wes2SessionController c = _load();
    _type(c, 0, Wes2FieldKey.weight, '30');
    for (final Wes2SetState s in c.rows.first.sets) {
      if (s.setIndex == 0) continue;
      expect(s.weight.actualValue, isNull);
      expect(s.reps.actualValue, isNull);
      expect(s.rir.actualValue, isNull);
    }
    expect(workoutHasUserEnteredData(c.rows), isTrue);
    final Wes2SessionController untouched = _load();
    expect(workoutHasUserEnteredData(untouched.rows), isFalse,
        reason: 'hints alone are not user data');
  });
}
