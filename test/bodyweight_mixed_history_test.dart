// Chin-Up (and every bodyweight exercise) across MIXED storage bases, on the
// app side: progression history, suggestions, and the showcase mirror.
//
//   legacy workout screen  weight = bodyweight + added  (+ weightAdded, typed)
//   WES2                   weight = added load alone    (setIndex stamped)
//
// The progression engine works in TOTAL load and converts to the added load
// the WES2 / BB3 fields expect. It used to read a WES2 "+50" day as a 50 kg
// total, so a WES2-era athlete was suggested bodyweight only.
//
// Uses only APIs that existed before the fix, so every test here ran — and the
// Chin-Up ones failed — against 5eac4f18.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/progression_engine.dart';
import 'package:localtest222/progression_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kChinId = 'XM9026peNIu0R8qh7UqY';
const String kChinName = 'Chin-Up';
const String kUid = 'athlete-1';
final DateTime kToday = DateTime(2026, 8, 23);

String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> chinDoc(DateTime date, List<Map<String, dynamic>> sets) =>
    <String, dynamic>{
      'date': ymd(date),
      '_uid': kUid,
      'exercises': <Map<String, dynamic>>[
        <String, dynamic>{'exerciseId': kChinId, 'name': kChinName, 'sets': sets},
      ],
    };

/// Legacy screen: total stored, typed added load alongside.
Map<String, dynamic> legacy(double total, double added, int reps, double rir) =>
    <String, dynamic>{
      'weight': total,
      'weightAdded': added,
      'addedWeight': added,
      'reps': reps,
      'rir': rir,
    };

/// WES2: the added load, verbatim.
Map<String, dynamic> wes2(double added, int reps, double rir, [int i = 0]) =>
    <String, dynamic>{'setIndex': i, 'weight': added, 'reps': reps, 'rir': rir};

void recordBodyweights(Map<DateTime, double> byDay) {
  PeriodizationModelUtils.setBodyweightHistory(uid: kUid, entries: <Map<String, dynamic>>[
    for (final MapEntry<DateTime, double> e in byDay.entries)
      <String, dynamic>{
        'date': DateTime(e.key.year, e.key.month, e.key.day, 12),
        'weight': e.value,
        'unit': 'kg',
      },
  ]);
}

Map<String, dynamic> runChinEngine({int repTarget = 5, double rir = 1.0}) {
  final DateTime blockStart = DateTime(2026, 8, 17);
  PeriodizationModelUtils.exercisePeriodizationModels[kChinId] =
      PeriodizationModelType.dailyUndulatingExposure;
  final Map<String, dynamic> settings = <String, dynamic>{
    kChinId: <String, dynamic>{
      'progressionModel': 'Smart Progression',
      'periodizationModel': 'DUP, By Exposure',
      'increments': <String, dynamic>{'primary': 2.5},
      'repTargets': <String, dynamic>{
        'week1': <String, dynamic>{'instance1': '$repTarget x 3'},
      },
    },
  };
  final ProgressionEngineInputs inputs = ProgressionEngineInputs(
    blockStartDate: blockStart,
    blockEndDate: blockStart.add(const Duration(days: 42)),
    selectedDate: kToday,
    cachedUid: kUid,
    selectedExercisesWithCircuits: <Map<String, dynamic>>[
      <String, dynamic>{'exerciseId': kChinId, 'id': kChinId, 'name': kChinName},
    ],
    exerciseSettings: settings,
    cachedProgressedValues: <String, Map<String, dynamic>>{},
    seedHintsByKey: const <String, Map<String, dynamic>>{},
    resolvedBB2Values: const <String, Map<String, dynamic>>{},
    rowKeyBy: (_) => '$kChinId|0',
    rowCacheKey: (_) => '$kChinId|0',
    getApplicableWeekIndex: (_) =>
        PeriodizationModelUtils.getWeekIndexForDate(kToday, blockStart),
    getRirFromPlanOrInput: (_, __) => rir,
    weightTextAt: (_, __) => '',
    rirTextAt: (_, __) => '',
  );
  return ProgressionEngine.engineProgressedValues(inputs, 0);
}

/// Four recent WES2 sessions at +45..+50 and two older legacy ones.
List<Map<String, dynamic>> mixedHistory() => <Map<String, dynamic>>[
      chinDoc(DateTime(2026, 8, 20), <Map<String, dynamic>>[wes2(50, 5, 1)]),
      chinDoc(DateTime(2026, 8, 13), <Map<String, dynamic>>[wes2(47.5, 5, 1)]),
      chinDoc(DateTime(2026, 8, 6), <Map<String, dynamic>>[wes2(45, 5, 1)]),
      chinDoc(DateTime(2026, 7, 30), <Map<String, dynamic>>[wes2(45, 5, 1)]),
      chinDoc(DateTime(2026, 5, 1), <Map<String, dynamic>>[legacy(138.5, 53.5, 3, 1)]),
      chinDoc(DateTime(2026, 4, 20), <Map<String, dynamic>>[legacy(136, 51, 3, 1)]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PeriodizationModelUtils.clearHistorySnapshot();
    PeriodizationModelUtils.exercisePeriodizationModels.clear();
    PeriodizationModelUtils.setBodyweightHistory(
        uid: kUid, entries: const <Map<String, dynamic>>[]);
  });

  tearDown(PeriodizationModelUtils.clearHistorySnapshot);

  group('progression history is normalised to total load', () {
    test('a WES2 day is its added load plus that day\'s bodyweight', () {
      recordBodyweights(<DateTime, double>{DateTime(2026, 1, 1): 85});
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: kUid, workouts: mixedHistory());
      final List<Map<String, dynamic>> samples =
          PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kChinId,
        exerciseName: kChinName,
        asOfDate: kToday,
      );
      final Map<String, double> byDay = <String, double>{
        for (final Map<String, dynamic> s in samples)
          ymd(s['date'] as DateTime): (s['weight'] as num).toDouble(),
      };
      expect(byDay['2026-08-20'], 135, reason: '+50 at 85 kg is a 135 kg total');
      expect(byDay['2026-07-30'], 130);
      expect(byDay['2026-05-01'], 138.5, reason: 'legacy totals stay totals');
    });

    test('each day uses its own recorded bodyweight', () {
      recordBodyweights(<DateTime, double>{
        DateTime(2026, 1, 1): 90,
        DateTime(2026, 8, 10): 80,
      });
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: kUid, workouts: mixedHistory());
      final Map<String, double> byDay = <String, double>{
        for (final Map<String, dynamic> s
            in PeriodizationModelUtils.resolveTopSetHistory(
                exerciseId: kChinId, exerciseName: kChinName, asOfDate: kToday))
          ymd(s['date'] as DateTime): (s['weight'] as num).toDouble(),
      };
      expect(byDay['2026-08-06'], 135, reason: '+45 at 90 kg');
      expect(byDay['2026-08-13'], 127.5, reason: '+47.5 at 80 kg');
    });

    test('a WES2 day with no bodyweight recorded on or before it is left out',
        () {
      // Only a weigh-in AFTER every WES2 day: it must not be used for them.
      recordBodyweights(<DateTime, double>{DateTime(2026, 8, 22): 85});
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: kUid, workouts: mixedHistory());
      final List<String> days = <String>[
        for (final Map<String, dynamic> s
            in PeriodizationModelUtils.resolveTopSetHistory(
                exerciseId: kChinId, exerciseName: kChinName, asOfDate: kToday))
          ymd(s['date'] as DateTime),
      ];
      expect(days, isNot(contains('2026-08-20')));
      expect(days, containsAll(<String>['2026-05-01', '2026-04-20']));
    });
  });

  group('the history store publishes weigh-ins before history', () {
    test('a WES2 day is indexed at the bodyweight the store hydrated',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final ProgressionHistoryStore store = ProgressionHistoryStore.instance;
      store.debugReset();
      store.debugServerFetch = (_) async => mixedHistory();
      store.debugWeightsFetch = (_) async => <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'w1',
              'date': DateTime(2026, 1, 1, 12),
              'weight': 85.0,
              'unit': 'kg',
              'tod': 'am',
            },
          ];
      addTearDown(() {
        store.debugReset();
        store.debugServerFetch = null;
        store.debugWeightsFetch = null;
      });

      await store.ensureHydrated(uid: kUid);

      final Map<String, double> byDay = <String, double>{
        for (final Map<String, dynamic> s
            in PeriodizationModelUtils.resolveTopSetHistory(
                exerciseId: kChinId, exerciseName: kChinName, asOfDate: kToday))
          ymd(s['date'] as DateTime): (s['weight'] as num).toDouble(),
      };
      expect(byDay['2026-08-20'], 135);
      expect(byDay['2026-05-01'], 138.5);
    });

    test('a weigh-in published later re-indexes bodyweight days', () {
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: kUid, workouts: mixedHistory());
      List<String> days() => <String>[
            for (final Map<String, dynamic> s
                in PeriodizationModelUtils.resolveTopSetHistory(
                    exerciseId: kChinId,
                    exerciseName: kChinName,
                    asOfDate: kToday))
              ymd(s['date'] as DateTime),
          ];
      expect(days(), isNot(contains('2026-08-20')), reason: 'no weigh-in yet');
      recordBodyweights(<DateTime, double>{DateTime(2026, 1, 1): 85});
      expect(days(), contains('2026-08-20'));
    });
  });

  group('the other lifts are untouched', () {
    test('bench history samples are the stored values, whatever the weigh-ins',
        () {
      const String bench = 'AmfUWbF1DH3I7qPAdh5k';
      final List<Map<String, dynamic>> docs = <Map<String, dynamic>>[
        <String, dynamic>{
          'date': '2026-08-20',
          '_uid': kUid,
          'exercises': <Map<String, dynamic>>[
            <String, dynamic>{
              'exerciseId': bench,
              'name': 'Bench Press, Barbell',
              'sets': <Map<String, dynamic>>[
                <String, dynamic>{'setIndex': 0, 'weight': 100.0, 'reps': 5, 'rir': 1.0},
                <String, dynamic>{'weight': 105.0, 'weightAdded': 12.0, 'reps': 3, 'rir': 1.0},
              ],
            },
          ],
        },
      ];
      List<Map<String, dynamic>> samples() =>
          PeriodizationModelUtils.resolveTopSetHistory(
              exerciseId: bench,
              exerciseName: 'Bench Press, Barbell',
              asOfDate: kToday);

      PeriodizationModelUtils.applyHistorySnapshot(uid: kUid, workouts: docs);
      final List<Map<String, dynamic>> before = <Map<String, dynamic>>[
        for (final Map<String, dynamic> s in samples())
          Map<String, dynamic>.from(s),
      ];
      recordBodyweights(<DateTime, double>{DateTime(2026, 1, 1): 85});
      PeriodizationModelUtils.applyHistorySnapshot(uid: kUid, workouts: docs);
      expect(samples(), before);
      // The day's top set (100 × 5 out-ranks 105 × 3 on E1RM), at its stored
      // weight: no bodyweight added, the stray fields ignored.
      expect((before.single['weight'] as num).toDouble(), 100.0);
    });
  });

  group('suggestions come back in the basis each field expects', () {
    test('WES2/BB3 receive an ADDED load that reflects the WES2 history', () {
      recordBodyweights(<DateTime, double>{DateTime(2026, 1, 1): 85});
      PeriodizationModelUtils.applyHistorySnapshot(
          uid: kUid, workouts: mixedHistory());
      final Map<String, dynamic> p = runChinEngine();
      final double added = (p['weightDisplayAdded'] as num).toDouble();
      final double total = (p['weight'] as num).toDouble();
      // ~150 kg total E1RM from +45..+50 × 5 at 85 kg → ~+45 at 5 reps.
      expect(added, inInclusiveRange(35.0, 55.0),
          reason: 'not bodyweight-only: the WES2 sessions are real history');
      expect(added % 2.5, 0, reason: 'snapped on the added-load grid');
      // The total-load output is the same suggestion in the other basis.
      expect(total, closeTo(added + 85, 1e-9));
    });
  });

  group('the Dart showcase mirror', () {
    test('heaviest compares added loads, never a legacy total with an added load',
        () {
      final ProfileShowcase s = buildShowcase(<String, Object?>{
        '2026-05-01': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': kChinId,
              'name': kChinName,
              'sets': <Object?>[legacy(142, 57, 2, 0)],
            },
          ],
        },
        '2026-08-10': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': kChinId,
              'name': kChinName,
              'sets': <Object?>[wes2(60, 2, 0)],
            },
          ],
        },
      });
      final ShowcaseRecord h = s.forSlot(BigFiveSlot.chinUp).heaviest!;
      expect(h.dateKey, '2026-08-10', reason: '+60 beats +57');
      expect(h.weight, 60, reason: 'the stored value is untouched');
    });
  });
}
