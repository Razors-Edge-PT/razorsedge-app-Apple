// The RE Points catalogue (lib/profile/core/re_catalog.dart), pinned to the
// SAME fixture the server suite asserts (functions/test/showcase_re_catalog
// .test.js), so the Dart and Node definitions cannot drift.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/formula.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/re_catalog.dart';

Map<String, dynamic> _fixture() {
  for (Directory d = Directory.current; d.parent.path != d.path; d = d.parent) {
    final File f =
        File('${d.path}/functions/test/fixtures/re_catalog_parity.json');
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  fail('re_catalog_parity.json not found');
}

void main() {
  final Map<String, dynamic> fixture = _fixture();

  test('categories and exercises match the server fixture exactly', () {
    final List<Map<String, Object?>> actual = <Map<String, Object?>>[
      for (final ReCategory c in kReCategories)
        <String, Object?>{
          'key': c.key,
          'displayName': c.displayName,
          'exercises': <Map<String, Object?>>[
            for (final ReExercise e in reExercisesOfCategory(c.key))
              <String, Object?>{
                'slot': e.slot,
                'exerciseId': e.exerciseId,
                'displayName': e.displayName,
                'legacyNameAliases': e.legacyNameAliases,
                'factor': e.factor,
                'bodyweightLoaded': e.bodyweightLoaded,
                'loadSemantics': e.loadSemantics,
              },
          ],
        },
    ];
    // Round-trip through JSON so 1.0 and 1 compare as the server writes them.
    expect(jsonDecode(jsonEncode(actual)), fixture['categories']);
  });

  test('exact factors that were specifically agreed', () {
    expect(reExerciseById('RdsGazgdH0xgpjek0n3u')!.factor, 2.61);
    expect(reExerciseById('MsGl7e9yanDeEnYX0e4X')!.factor, 0.74);
    expect(reExerciseById('10pEctikt6PP8eAg9Eip')!.factor, 0.74);
    expect(reExerciseById('1XOIXxeLFhgmgjZS9Cyq')!.factor, 0.85);
    expect(reExerciseById('1XOIXxeLFhgmgjZS9Cyq')!.category,
        ReCategoryKey.verticalPull);
  });

  test('the rolling RE calculation uses the same factors for its five lifts',
      () {
    const ReWeights w = ReWeights.defaults;
    expect(w.dbShoulder, 2.61);
    expect(w.bench, reExerciseBySlot('bench')!.factor);
    expect(w.squat, reExerciseBySlot('squat')!.factor);
    expect(w.deadlift, reExerciseBySlot('deadlift')!.factor);
    expect(w.chinUp, reExerciseBySlot('chinUp')!.factor);
    expect(w.dbShoulder, reExerciseBySlot('ohpUnilateral')!.factor);
  });

  test('coefficient: lib/formula.dart equals the server port on shared vectors',
      () {
    for (final dynamic v in fixture['coefficients'] as List<dynamic>) {
      final Gender g = v['sex'] == 'female' ? Gender.female : Gender.male;
      final double expected = (v['coefficient'] as num).toDouble();
      final double got = reCoefficient(
          gender: g, bodyweightKg: (v['bodyweightKg'] as num).toDouble());
      expect((got - expected).abs() <= 1e-12 * expected.abs(), isTrue,
          reason: '$v → $got');
    }
  });

  test('points vectors equal e1rm × factor × coefficient at 4 dp', () {
    for (final dynamic v in fixture['points'] as List<dynamic>) {
      final Object? bw = v['bodyweightKg'];
      final Object? expected = v['rePoints'];
      if (bw == null) {
        expect(expected, isNull, reason: 'missing bodyweight is unavailable');
        continue;
      }
      final Gender g = v['sex'] == 'female' ? Gender.female : Gender.male;
      final double pts = (v['e1rmKg'] as num).toDouble() *
          (v['factor'] as num).toDouble() *
          reCoefficient(gender: g, bodyweightKg: (bw as num).toDouble());
      expect(
          double.parse(pts.toStringAsFixed(4)), (expected as num).toDouble());
    }
  });

  test('the five Big Five lifts keep their slots and ids', () {
    for (final BigFiveLift l in kBigFive) {
      final ReExercise? e = reExerciseBySlot(l.slot);
      expect(e, isNotNull, reason: l.slot);
      expect(e!.exerciseId, l.exerciseId);
      expect(e.bodyweightLoaded, l.bodyweightLoaded);
    }
  });

  test('bodyweight-loaded is definition-driven: Chin-Up and Triceps Dip', () {
    expect(isBodyweightLoadedSlot('chinUp'), isTrue);
    expect(isBodyweightLoadedSlot('tricepsDip'), isTrue);
    expect(isBodyweightLoadedSlot('bench'), isFalse);
    expect(isBodyweightLoadedSlot('dbBenchFlat'), isFalse);
    expect(isBodyweightLoadedSlot('unknown'), isFalse);
  });

  test('matching: a present id decides; only id-less rows use exact aliases',
      () {
    expect(
        matchReExercise(rawId: '10pectikt6pp8eag9eip')!.slot, 'deadliftSumo');
    expect(
        matchReExercise(rawId: 't66qeWQqnuEtaoyZqRp0', rawName: 'Triceps Dip'),
        isNull);
    expect(matchReExercise(rawName: 'Sumo Deadlift')!.slot, 'deadliftSumo');
    expect(matchReExercise(rawName: 'Bulgarian Split Squat')!.slot,
        'bulgarianSplitSquatDumbbell');
    for (final String n in <String>[
      'Triceps Dip Machine',
      'Bulgarian Split Squat, Deficit',
      'Overhead Dumbbell Press',
      'Pull-Up',
    ]) {
      expect(matchReExercise(rawName: n), isNull, reason: n);
    }
  });

  group('selectDefaultExerciseId', () {
    String? pick(String cat, Map<String, double?> points) =>
        selectDefaultExerciseId(
          cat,
          hasRecord: (String id) => points.containsKey(id),
          pointsOf: (String id) => points[id],
        );

    test('highest valid points wins', () {
      expect(
        pick(ReCategoryKey.horizontalPress, <String, double?>{
          'AmfUWbF1DH3I7qPAdh5k': 100,
          'kTs5fLSTKjUkUZL10iii': 117.5,
        }),
        'kTs5fLSTKjUkUZL10iii',
      );
    });

    test('ties go to catalogue order', () {
      expect(
        pick(ReCategoryKey.hipHinge, <String, double?>{
          '10pEctikt6PP8eAg9Eip': 98.2608,
          'MsGl7e9yanDeEnYX0e4X': 98.2608,
        }),
        'MsGl7e9yanDeEnYX0e4X',
      );
    });

    test('an unscored exercise never displaces a scored one', () {
      expect(
        pick(ReCategoryKey.hipHinge, <String, double?>{
          'MsGl7e9yanDeEnYX0e4X': null,
          'LGhFj8o0sG3X12296UAh': 1,
        }),
        'LGhFj8o0sG3X12296UAh',
      );
    });

    test('no points → first with a record; nothing → the primary', () {
      expect(
        pick(ReCategoryKey.hipHinge, <String, double?>{
          'LGhFj8o0sG3X12296UAh': null,
          '10pEctikt6PP8eAg9Eip': null,
        }),
        '10pEctikt6PP8eAg9Eip',
      );
      expect(pick(ReCategoryKey.squatPattern, <String, double?>{}),
          'heeBViVINHO6tUScSd6y');
    });
  });
}
