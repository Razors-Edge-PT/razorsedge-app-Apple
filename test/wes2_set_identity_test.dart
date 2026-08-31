import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';

/// Stable set identity (`Wes2SetState.setId`) — the property that keeps a
/// recorded video attached to the performance it actually filmed.
///
/// The hazard these pin: the showcase reducers key a record on
/// `s.id ?? s.setId`, falling back to a POSITIONAL `s<n>`. If identity is lost
/// or reassigned by an ordinary edit, the record fingerprint changes and the
/// proof video attached to it silently points at a different set.

Wes2ExerciseRow _row({
  required String exerciseId,
  required List<Wes2SetState> sets,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: 'Bench Press, Barbell',
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets.length,
      sets: sets,
      source: Wes2RowSource.wes2Manual,
    );

Wes2SetState _set(int i, {String? id, double? weight, int? reps}) =>
    Wes2SetState(
      setIndex: i,
      setId: id,
      weight: Wes2FieldState<double>(actualValue: weight),
      reps: Wes2FieldState<int>(actualValue: reps),
    );

void main() {
  group('model serialization', () {
    test('a set with no id serialises exactly as before', () {
      final json = _set(0, weight: 100, reps: 5).toJson();
      expect(json.containsKey('setId'), isFalse,
          reason: 'an absent id must not add a key to existing documents');
    });

    test('setId round-trips through toJson/fromJson', () {
      final json = _set(2, id: 'abc-123', weight: 100, reps: 5).toJson();
      expect(json['setId'], 'abc-123');
      final back = Wes2SetState.fromJson(json);
      expect(back.setId, 'abc-123');
      expect(back.setIndex, 2);
      expect(back.weight.actualValue, 100);
    });

    test('a historical set decodes with a null id rather than throwing', () {
      final back = Wes2SetState.fromJson(<String, dynamic>{
        'setIndex': 0,
        'weight': <String, dynamic>{'actual': 90, 'hint': null},
        'reps': <String, dynamic>{'actual': 5, 'hint': null},
        'rir': <String, dynamic>{'actual': null, 'hint': null},
        'velocity': <String, dynamic>{'actual': null, 'hint': null},
      });
      expect(back.setId, isNull);
      expect(back.weight.actualValue, 90);
    });

    test('copyWith preserves an existing id', () {
      final s = _set(0, id: 'keep-me');
      expect(s.copyWith(reps: const Wes2FieldState<int>(actualValue: 8)).setId,
          'keep-me');
    });

    test('copyWith can mint an id onto a set that had none', () {
      expect(_set(0).copyWith(setId: 'fresh').setId, 'fresh');
    });
  });

  group('readStableSetId precedence matches both reducers', () {
    test("'id' wins over 'setId'", () {
      expect(readStableSetId(<String, dynamic>{'id': 'A', 'setId': 'B'}), 'A');
    });

    test("falls back to 'setId'", () {
      expect(readStableSetId(<String, dynamic>{'setId': 'B'}), 'B');
    });

    test('blank and non-string values are ignored', () {
      expect(
          readStableSetId(<String, dynamic>{'id': '   ', 'setId': 'B'}), 'B');
      expect(readStableSetId(<String, dynamic>{'id': 7, 'setId': 'B'}), 'B');
      expect(readStableSetId(<String, dynamic>{}), isNull);
      expect(
          readStableSetId(<String, dynamic>{'id': '', 'setId': '  '}), isNull);
    });

    test('a value is trimmed, matching the reducers', () {
      expect(readStableSetId(<String, dynamic>{'setId': '  B  '}), 'B');
    });
  });

  group('Firestore round trip', () {
    test('setId survives encode then decode', () {
      final row = _row(exerciseId: 'ex1', sets: <Wes2SetState>[
        _set(0, id: 'sid-0', weight: 100, reps: 5),
        _set(1, weight: 105, reps: 3),
      ]);
      final map = FirestoreWes2Repository.buildRowMapForTest(row);
      final rawSets = map['sets'] as List<dynamic>;

      expect((rawSets[0] as Map<String, dynamic>)['setId'], 'sid-0');
      expect((rawSets[1] as Map<String, dynamic>).containsKey('setId'), isFalse,
          reason: 'a set without identity must not gain an empty key');

      final decoded = FirestoreWes2Repository.parseSetsForTest(rawSets, 2);
      expect(decoded[0].setId, 'sid-0');
      expect(decoded[1].setId, isNull);
    });

    test("a legacy document carrying 'id' keeps that as its identity", () {
      final decoded = FirestoreWes2Repository.parseSetsForTest(<dynamic>[
        <String, dynamic>{
          'setIndex': 0,
          'id': 'legacy-id',
          'weight': 100,
          'reps': 5,
        },
      ], 1);
      expect(decoded[0].setId, 'legacy-id',
          reason: 'the reducers read s.id first; disagreeing detaches proofs');
    });

    test('a padded missing set decodes without identity', () {
      final decoded = FirestoreWes2Repository.parseSetsForTest(<dynamic>[], 2);
      expect(decoded.map((s) => s.setId), everyElement(isNull));
      expect(decoded.length, 2);
    });
  });

  group('identity through structural edits', () {
    late Wes2SessionController c;

    setUp(() {
      c = Wes2SessionController(DateTime(2026, 8, 31));
      c.setRows(<Wes2ExerciseRow>[
        _row(exerciseId: 'ex1', sets: <Wes2SetState>[
          _set(0, id: 'sid-0', weight: 100, reps: 5),
          _set(1, id: 'sid-1', weight: 105, reps: 4),
          _set(2, id: 'sid-2', weight: 110, reps: 3),
        ]),
      ], c.beginLoad());
    });

    test('removing a set reindexes positions but never identities', () {
      c.removeSet('ex1', 1);
      final sets = c.rows.single.sets;

      expect(sets.map((s) => s.setIndex), <int>[0, 1],
          reason: 'positions compact');
      expect(sets.map((s) => s.setId), <String>['sid-0', 'sid-2'],
          reason: "the survivor keeps its own identity, not the removed set's");
    });

    test("a removed set's identity is never reused by a survivor", () {
      c.removeSet('ex1', 0);
      expect(c.rows.single.sets.map((s) => s.setId), isNot(contains('sid-0')));
    });

    test('undo restores identities intact', () {
      c.removeSet('ex1', 1);
      c.undo();
      expect(c.rows.single.sets.map((s) => s.setId),
          <String>['sid-0', 'sid-1', 'sid-2']);
    });

    test('setting an execution note preserves identity', () {
      c.updateExecutionNote(
          exerciseId: 'ex1', setIndex: 1, rawText: 'felt heavy');
      expect(c.rows.single.sets[1].setId, 'sid-1');
    });
  });

  group('lazy identity for historical sets', () {
    late Wes2SessionController c;

    setUp(() {
      c = Wes2SessionController(DateTime(2026, 8, 31));
      c.setIdGenerator = () => 'minted-id';
      c.setRows(<Wes2ExerciseRow>[
        _row(exerciseId: 'ex1', sets: <Wes2SetState>[
          _set(0, weight: 100, reps: 5),
          _set(1, id: 'already', weight: 105, reps: 4),
        ]),
      ], c.beginLoad());
    });

    test('a set with no identity is given one on demand', () {
      expect(c.setIdAt('ex1', 0), isNull);
      expect(c.ensureSetId('ex1', 0), 'minted-id');
      expect(c.rows.single.sets.first.setId, 'minted-id');
    });

    test('a set that already has one is left alone', () {
      expect(c.ensureSetId('ex1', 1), 'already');
    });

    test('minting twice returns the same identity', () {
      final first = c.ensureSetId('ex1', 0);
      c.setIdGenerator = () => 'different';
      expect(c.ensureSetId('ex1', 0), first);
    });

    test('minting does not consume an undo slot', () {
      final before = c.canUndo;
      c.ensureSetId('ex1', 0);
      expect(c.canUndo, before,
          reason: 'bookkeeping must not cost the user their undo');
    });

    test('an unknown row or set yields null rather than throwing', () {
      expect(c.ensureSetId('nope', 0), isNull);
      expect(c.ensureSetId('ex1', 99), isNull);
    });

    test('a minted identity survives removal of an earlier set', () {
      c.ensureSetId('ex1', 1);
      c.removeSet('ex1', 0);
      expect(c.rows.single.sets.single.setId, 'already');
      expect(c.rows.single.sets.single.setIndex, 0);
    });
  });
}
