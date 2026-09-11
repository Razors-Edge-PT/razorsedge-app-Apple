// The bodyweight normalisation boundary (lib/bodyweight_load.dart), pinned to
// the server by the SAME vectors functions/test/showcase_bodyweight_vectors
// .test.js asserts — plus the Dart showcase mirror held to the server's output
// for the Chin-Up and, byte for byte, to the pre-fix output for the other
// four lifts.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/bodyweight_load.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/workout_model.dart';

double? _d(Object? v) => v is num ? v.toDouble() : null;

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void _close(Object? actual, Object? expected, String label) {
  if (expected == null) {
    expect(actual, isNull, reason: label);
    return;
  }
  if (expected is num) {
    expect(actual, isA<num>(), reason: label);
    expect((actual! as num).toDouble(),
        closeTo(expected.toDouble(), 1e-9), reason: label);
    return;
  }
  expect(actual, expected, reason: label);
}

/// Same keys, same values (numbers to 1e-9).
void _sameRecord(Map<String, Object?> actual, Map<String, dynamic> expected,
    String label) {
  expect(actual.keys.toSet(), expected.keys.toSet(), reason: label);
  for (final String k in expected.keys) {
    _close(actual[k], expected[k], '$label.$k');
  }
}

Map<String, RecordedBodyweight?> _bwByDate(Object? raw) =>
    <String, RecordedBodyweight?>{
      for (final MapEntry<String, dynamic> e
          in ((raw as Map<String, dynamic>?) ?? const <String, dynamic>{})
              .entries)
        e.key: RecordedBodyweight.fromMap(e.value),
    };

void main() {
  final Map<String, dynamic> vectors =
      _json('functions/showcase/bodyweight_vectors.json');

  group('normalizeLoad (shared vectors)', () {
    for (final dynamic v in vectors['normalize'] as List<dynamic>) {
      test(v['name'] as String, () {
        final Map<String, dynamic> input = v['input'] as Map<String, dynamic>;
        final int reps = (input['reps'] as num).toInt();
        final NormalizedLoad n = normalizeLoad(
          basis: input['basis'] as String?,
          storedKg: _d(input['storedKg']),
          reps: reps,
          typedAddedKg: _d(input['typedAddedKg']),
          bodyweightKg: _d(input['bodyweightKg']),
        );
        final Map<String, dynamic> e = v['expect'] as Map<String, dynamic>;
        _close(n.addedKg, e['addedKg'], 'addedKg');
        _close(n.totalKg, e['totalKg'], 'totalKg');
        _close(n.totalE1rm, e['totalE1rm'], 'totalE1rm');
        _close(n.addedE1rm, e['addedE1rm'], 'addedE1rm');

        final RankKey er = e1rmRank(n, reps);
        final Map<String, dynamic> ee = v['e1rmRank'] as Map<String, dynamic>;
        expect(er.tier, ee['tier']);
        _close(er.value, ee['value'], 'e1rmRank.value');
        _close(er.tie, ee['tie'], 'e1rmRank.tie');

        final RankKey hr = heaviestRank(n);
        final Map<String, dynamic> he =
            v['heaviestRank'] as Map<String, dynamic>;
        expect(hr.tier, he['tier']);
        _close(hr.value, he['value'], 'heaviestRank.value');
        expect(hr.tie, isNull);
      });
    }
  });

  group('pickBodyweightAsOf (shared vectors)', () {
    for (final dynamic v in vectors['pick'] as List<dynamic>) {
      test(v['name'] as String, () {
        final List<BodyweightEntry> entries = <BodyweightEntry>[
          for (final dynamic e in v['entries'] as List<dynamic>)
            BodyweightEntry(
              weight: _d(e['weight']),
              unit: e['unit'] as String?,
              tod: e['tod'] as String?,
              dateKey: e['dateKey'] as String?,
              tsMillis: (e['tsMillis'] as num?)?.toInt(),
              id: (e['id'] as String?) ?? '',
            ),
        ];
        final RecordedBodyweight? got =
            pickBodyweightAsOf(entries, v['dateKey'] as String);
        final Object? want = v['expect'];
        if (want == null) {
          expect(got, isNull);
        } else {
          final Map<String, dynamic> m = want as Map<String, dynamic>;
          expect(got, isNotNull);
          _close(got!.weightKg, m['weightKg'], 'weightKg');
          expect(got.dateKey, m['dateKey']);
        }
      });
    }
  });

  group('the Dart showcase mirror publishes what the server publishes', () {
    for (final dynamic v in vectors['showcase'] as List<dynamic>) {
      test(v['name'] as String, () {
        final ProfileShowcase s = buildShowcase(
          Map<String, Object?>.from(v['history'] as Map<String, dynamic>),
          bodyweightByDate: _bwByDate(v['bodyweightByDate']),
        );
        final ShowcaseLiftSnapshot chin = s.forSlot(BigFiveSlot.chinUp);
        final Map<String, dynamic> want = v['expect'] as Map<String, dynamic>;
        _sameRecord(chin.bestE1rm!.toMap(),
            want['e1rm'] as Map<String, dynamic>, 'e1rm');
        _sameRecord(chin.heaviest!.toMap(),
            want['heaviest'] as Map<String, dynamic>, 'heaviest');
      });
    }
  });

  test('the other four lifts publish exactly the pre-fix output', () {
    final Map<String, dynamic> golden =
        _json('functions/test/fixtures/showcase_other_lifts_golden.json');
    final Map<String, dynamic> history =
        golden['history'] as Map<String, dynamic>;
    for (final Map<String, RecordedBodyweight?> bw
        in <Map<String, RecordedBodyweight?>>[
      const <String, RecordedBodyweight?>{},
      <String, RecordedBodyweight?>{
        for (final String d in history.keys)
          d: RecordedBodyweight(weightKg: 85, dateKey: d),
      },
    ]) {
      final ProfileShowcase s = buildShowcase(
        Map<String, Object?>.from(history),
        bodyweightByDate: bw,
      );
      final Map<String, dynamic> lifts =
          golden['lifts'] as Map<String, dynamic>;
      for (final String slot in lifts.keys) {
        final Map<String, dynamic> want = lifts[slot] as Map<String, dynamic>;
        final ShowcaseLiftSnapshot got = s.forSlot(slot);
        _sameRecord(got.bestE1rm!.toMap(),
            want['e1rm'] as Map<String, dynamic>, '$slot.e1rm');
        _sameRecord(got.heaviest!.toMap(),
            want['heaviest'] as Map<String, dynamic>, '$slot.heaviest');
      }
    }
  });

  test('history screens read a set through the boundary, and never write it',
      () {
    final SetDetails wes2 = SetDetails.fromFirestore(
        <String, dynamic>{'setIndex': 2, 'weight': 60, 'reps': 3}, 1);
    expect(wes2.setIndex, 2);
    expect(wes2.bodyweightLoad(85).addedKg, 60);
    expect(wes2.bodyweightLoad(85).totalKg, 145);
    expect(wes2.bodyweightLoad(null).totalKg, isNull);

    final SetDetails legacy = SetDetails.fromFirestore(<String, dynamic>{
      'weight': 135,
      'weightAdded': 55,
      'addedWeight': 55,
      'reps': 3,
    }, 1);
    expect(legacy.setIndex, isNull);
    expect(legacy.bodyweightLoad(85).addedKg, 55);
    expect(legacy.bodyweightLoad(85).totalKg, 140);
    expect(legacy.bodyweightLoad(null).totalKg, 135);

    // Saving a set back never gains a field it did not have.
    expect(legacy.toMap().keys,
        <String>['reps', 'weight', 'rir', 'velocity', 'notes']);
  });

  test('a day contribution keeps its sets and bodyweight through storage', () {
    const RecordedBodyweight bw =
        RecordedBodyweight(weightKg: 85, dateKey: '2026-08-09');
    final ShowcaseDayContribution d = summarizeWorkoutDay(
      '2026-08-10',
      <String, Object?>{
        'exercises': <Object?>[
          <String, Object?>{
            'exerciseId': 'XM9026peNIu0R8qh7UqY',
            'name': 'Chin-Up',
            'sets': <Object?>[
              <String, Object?>{'weight': 138.5, 'weightAdded': 53.5, 'reps': 3},
              <String, Object?>{'setIndex': 1, 'weight': 60, 'reps': 3},
            ],
          },
        ],
      },
      bodyweight: bw,
    )[BigFiveSlot.chinUp]!;
    final ShowcaseDayContribution back =
        ShowcaseDayContribution.fromMap(d.toMap())!;
    expect(back.bodyweight, bw);
    expect(back.sets!.length, 2);
    expect(back.sets!.first.typedAddedKg, 53.5);
    expect(back.bestE1rmSet.setKey, 's1', reason: '+60 beats +53.5 at 85 kg');
  });
}
