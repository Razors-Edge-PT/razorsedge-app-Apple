import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';

/// The lifetime record rules, and the provenance that makes a record checkable.
void main() {
  const String bench = 'AmfUWbF1DH3I7qPAdh5k';
  const String squat = 'heeBViVINHO6tUScSd6y';

  Map<String, Object?> row(
    String exerciseId,
    List<Map<String, Object?>> sets, {
    String name = 'x',
  }) =>
      <String, Object?>{'exerciseId': exerciseId, 'name': name, 'sets': sets};

  Map<String, Object?> day(List<Map<String, Object?>> rows) =>
      <String, Object?>{'exercises': rows};

  Map<String, Object?> oneLift(
    String exerciseId,
    List<Map<String, Object?>> sets,
  ) =>
      day(<Map<String, Object?>>[row(exerciseId, sets)]);

  ShowcaseLiftSnapshot benchOf(Map<String, Object?> history) =>
      buildShowcase(history).forSlot(BigFiveSlot.bench);

  group('valid completed sets', () {
    test('a set needs weight > 0 AND reps > 0', () {
      final Map<String, List<ShowcaseSet>> got =
          extractBigFiveSets(oneLift(bench, [
        <String, Object?>{'weight': 100, 'reps': 5},
        <String, Object?>{'weight': 0, 'reps': 5},
        <String, Object?>{'weight': 100, 'reps': 0},
        <String, Object?>{'weight': -50, 'reps': 3},
        <String, Object?>{'weight': 120},
        <String, Object?>{'reps': 3},
        <String, Object?>{'weight': 'heavy', 'reps': 3},
        <String, Object?>{'weight': 90, 'reps': 3},
      ]));
      expect(got[BigFiveSlot.bench]!.map((ShowcaseSet s) => s.weight),
          <double>[100, 90]);
    });

    test('WES2 actualWeight / actualReps are accepted', () {
      final Map<String, List<ShowcaseSet>> got = extractBigFiveSets(
        oneLift(bench, [
          <String, Object?>{'actualWeight': 140, 'actualReps': 3},
        ]),
      );
      expect(got[BigFiveSlot.bench]!.single.weight, 140);
      expect(got[BigFiveSlot.bench]!.single.reps, 3);
    });

    test('a set key is deterministic, and stable against unrelated changes',
        () {
      final Map<String, List<ShowcaseSet>> both = extractBigFiveSets(day([
        row(bench, [
          <String, Object?>{'weight': 100, 'reps': 5},
        ]),
        row(squat, [
          <String, Object?>{'weight': 200, 'reps': 5},
        ]),
      ]));
      final Map<String, List<ShowcaseSet>> squatOnly = extractBigFiveSets(day([
        row(squat, [
          <String, Object?>{'weight': 200, 'reps': 5},
        ]),
      ]));
      // Deleting bench must not renumber squat, or every proof video attached
      // to a squat record would be orphaned by an unrelated edit.
      expect(both[BigFiveSlot.squat]!.single.setKey,
          squatOnly[BigFiveSlot.squat]!.single.setKey);
    });

    test('an explicit set id wins over the positional key', () {
      final Map<String, List<ShowcaseSet>> got =
          extractBigFiveSets(oneLift(bench, [
        <String, Object?>{'id': 'set-abc', 'weight': 100, 'reps': 5},
      ]));
      expect(got[BigFiveSlot.bench]!.single.setKey, 'set-abc');
    });
  });

  group('best E1RM', () {
    test('picks the highest estimate, not the heaviest load', () {
      // 100x10 estimates 133.3; 130x1 estimates 130.
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 130, 'reps': 1},
          <String, Object?>{'weight': 100, 'reps': 10},
        ]),
      });
      expect(snap.bestE1rm!.weight, 100);
      expect(snap.bestE1rm!.reps, 10);
      expect(snap.heaviest!.weight, 130);
    });

    test('spans the whole history, not just the latest day', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 150, 'reps': 3},
        ]),
        '2026-06-01': oneLift(bench, [
          <String, Object?>{'weight': 100, 'reps': 3},
        ]),
      });
      expect(snap.bestE1rm!.dateKey, '2026-01-01');
      expect(snap.bestE1rm!.weight, 150);
    });
  });

  group('heaviest load', () {
    test('ignores rep count: 180 x 2 beats 175 x 1', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 175, 'reps': 1},
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      });
      expect(snap.heaviest!.weight, 180);
      expect(snap.heaviest!.reps, 2);
    });

    test('190 x 1 beats 180 x 2', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
        '2026-02-01': oneLift(bench, [
          <String, Object?>{'weight': 190, 'reps': 1},
        ]),
      });
      expect(snap.heaviest!.weight, 190);
      expect(snap.heaviest!.reps, 1);
    });

    test('on equal weight, more repetitions wins', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 1},
        ]),
        '2026-01-02': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 4},
        ]),
        '2026-01-03': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      });
      expect(snap.heaviest!.reps, 4);
      expect(snap.heaviest!.dateKey, '2026-01-02');
    });
  });

  group('tie-breaking', () {
    test('identical performances break to the LATEST date', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
        '2026-05-09': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
        '2026-03-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      });
      expect(snap.heaviest!.dateKey, '2026-05-09');
      expect(snap.bestE1rm!.dateKey, '2026-05-09');
    });

    test('within one day it breaks to a stable set identity', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'id': 'zzz', 'weight': 180, 'reps': 2},
          <String, Object?>{'id': 'aaa', 'weight': 180, 'reps': 2},
        ]),
      });
      expect(snap.heaviest!.setKey, 'aaa');
    });

    test('the result never depends on the order days are processed', () {
      final Map<String, Object?> history = <String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 140, 'reps': 4},
        ]),
        '2026-02-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 1},
        ]),
        '2026-03-01': oneLift(bench, [
          <String, Object?>{'weight': 160, 'reps': 3},
        ]),
      };
      final ProfileShowcase forward = buildShowcase(history);
      final ProfileShowcase reversed = buildShowcase(
        Map<String, Object?>.fromEntries(history.entries.toList().reversed),
      );
      expect(reversed.forSlot(BigFiveSlot.bench).heaviest!.fingerprint,
          forward.forSlot(BigFiveSlot.bench).heaviest!.fingerprint);
      expect(reversed.forSlot(BigFiveSlot.bench).bestE1rm!.fingerprint,
          forward.forSlot(BigFiveSlot.bench).bestE1rm!.fingerprint);
    });
  });

  group('provenance', () {
    test('a record identifies its exact source', () {
      final ShowcaseRecord r = benchOf(<String, Object?>{
        '2026-04-17': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      }).heaviest!;

      expect(r.slot, BigFiveSlot.bench);
      expect(r.exerciseId, bench);
      expect(r.dateKey, '2026-04-17');
      expect(r.setKey, isNotEmpty);
      expect(r.weight, 180);
      expect(r.reps, 2);
      expect(r.formulaVersion, greaterThan(0));
      expect(r.fingerprint, hasLength(32));
    });

    test('the original catalogue casing is preserved for display', () {
      final ShowcaseRecord r = benchOf(<String, Object?>{
        // The lowercased id production wrote for two months in 2026.
        '2026-04-17': oneLift(bench.toLowerCase(), [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      }).heaviest!;
      expect(r.exerciseId, bench.toLowerCase(),
          reason: 'the id actually written that day is what is recorded');
      // ...and it still folds into the right slot.
      expect(r.slot, BigFiveSlot.bench);
    });
  });

  group('fingerprints', () {
    Map<String, Object?> h(String date, num weight, int reps) =>
        <String, Object?>{
          date: oneLift(bench, [
            <String, Object?>{'weight': weight, 'reps': reps},
          ]),
        };

    test('are stable across recomputation', () {
      expect(benchOf(h('2026-01-01', 180, 2)).heaviest!.fingerprint,
          benchOf(h('2026-01-01', 180, 2)).heaviest!.fingerprint);
    });

    test('change when the source performance changes', () {
      final Set<String> fps = <String>{
        benchOf(h('2026-01-01', 180, 2)).heaviest!.fingerprint,
        benchOf(h('2026-01-01', 181, 2)).heaviest!.fingerprint,
        benchOf(h('2026-01-01', 180, 3)).heaviest!.fingerprint,
        benchOf(h('2026-01-02', 180, 2)).heaviest!.fingerprint,
      };
      expect(fps, hasLength(4),
          reason: 'each is a different performance, so each retires the last '
              'proof rather than silently inheriting it');
    });

    test('do not depend on the E1RM formula version', () {
      // A curve change must not orphan every attached proof video.
      expect(
        recordFingerprint(
          slot: BigFiveSlot.bench,
          exerciseId: bench,
          dateKey: '2026-01-01',
          setKey: 's0',
          weight: 180,
          reps: 2,
        ),
        recordFingerprint(
          slot: BigFiveSlot.bench,
          exerciseId: bench.toLowerCase(),
          dateKey: '2026-01-01',
          setKey: 's0',
          // Representation noise below 3dp is absorbed on purpose.
          weight: 180.0002,
          reps: 2,
        ),
      );
    });

    test('one set holding both records yields ONE fingerprint', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 100, 'reps': 1},
          <String, Object?>{'weight': 150, 'reps': 3},
        ]),
      });
      expect(snap.sharesOneSource, isTrue);
      expect(snap.bestE1rm!.fingerprint, snap.heaviest!.fingerprint);
    });

    test('two different sources yield two fingerprints', () {
      final ShowcaseLiftSnapshot snap = benchOf(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 130, 'reps': 1},
          <String, Object?>{'weight': 100, 'reps': 10},
        ]),
      });
      expect(snap.sharesOneSource, isFalse);
      expect(snap.bestE1rm!.fingerprint, isNot(snap.heaviest!.fingerprint));
    });
  });

  group('reconciliation', () {
    test('an edit that lowers the record retires the old fingerprint', () {
      final ProfileShowcase before = buildShowcase(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 100, 'reps': 5},
        ]),
        '2026-02-01': oneLift(bench, [
          <String, Object?>{'weight': 200, 'reps': 1},
        ]),
      });
      final ProfileShowcase after = buildShowcase(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 100, 'reps': 5},
        ]),
        // The 200 was a typo; it was really 120.
        '2026-02-01': oneLift(bench, [
          <String, Object?>{'weight': 120, 'reps': 1},
        ]),
      });
      expect(before.forSlot(BigFiveSlot.bench).heaviest!.weight, 200);
      expect(after.forSlot(BigFiveSlot.bench).heaviest!.weight, 120);
      expect(
        after.liveFingerprints
            .contains(before.forSlot(BigFiveSlot.bench).heaviest!.fingerprint),
        isFalse,
        reason: 'a proof attached to the old record must stop being displayed',
      );
    });

    test('deleting the record workout falls back to surviving history', () {
      final ProfileShowcase after = buildShowcase(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 100, 'reps': 5},
        ]),
      });
      expect(after.forSlot(BigFiveSlot.bench).heaviest!.weight, 100);
    });

    test('deleting all history empties the showcase without error', () {
      final ProfileShowcase after = buildShowcase(<String, Object?>{});
      expect(after.hasAnything, isFalse);
      expect(after.forSlot(BigFiveSlot.bench).isEmpty, isTrue);
      expect(after.liveFingerprints, isEmpty);
    });

    test('lifts are independent of one another', () {
      final ProfileShowcase snap = buildShowcase(<String, Object?>{
        '2026-01-01': day([
          row(bench, [
            <String, Object?>{'weight': 100, 'reps': 5},
          ]),
          row(squat, [
            <String, Object?>{'weight': 200, 'reps': 5},
          ]),
        ]),
      });
      expect(snap.forSlot(BigFiveSlot.bench).heaviest!.weight, 100);
      expect(snap.forSlot(BigFiveSlot.squat).heaviest!.weight, 200);
      expect(snap.forSlot(BigFiveSlot.deadlift).isEmpty, isTrue);
    });
  });

  group('snapshot shape', () {
    test('round-trips through its serialised form', () {
      final ProfileShowcase original = buildShowcase(<String, Object?>{
        '2026-01-01': oneLift(bench, [
          <String, Object?>{'weight': 180, 'reps': 2},
        ]),
      });
      final ProfileShowcase restored =
          ProfileShowcase.fromMap(original.toMap());
      expect(restored.forSlot(BigFiveSlot.bench).heaviest!.fingerprint,
          original.forSlot(BigFiveSlot.bench).heaviest!.fingerprint);
      expect(restored.schema, kProfileShowcaseSchema);
      expect(restored.forSlot(BigFiveSlot.bench).heaviest!.weight, 180);
    });

    test('tolerates a missing or malformed snapshot', () {
      expect(ProfileShowcase.fromMap(null).hasAnything, isFalse);
      expect(ProfileShowcase.fromMap('nonsense').hasAnything, isFalse);
      expect(
        ProfileShowcase.fromMap(<String, Object?>{'lifts': 'nonsense'})
            .hasAnything,
        isFalse,
      );
    });

    test('untrained lifts are absent, not zeroed', () {
      final ProfileShowcase snap = buildShowcase(<String, Object?>{
        '2026-01-01': oneLift(squat, [
          <String, Object?>{'weight': 200, 'reps': 3},
        ]),
      });
      expect(snap.lifts.keys, <String>[BigFiveSlot.squat]);
      expect(snap.forSlot(BigFiveSlot.bench).bestE1rm, isNull);
    });
  });
}
