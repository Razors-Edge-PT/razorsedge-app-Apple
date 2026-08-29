import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/profile/core/e1rm_spec.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';

/// The E1RM curve exists in three places: this Dart spec, the Cloud Functions
/// mirror, and the app's long-standing PeriodizationModelUtils. These cases pin
/// all three to the same numbers so they cannot drift apart silently.
void main() {
  group('the curve', () {
    test('one repetition is the weight itself, exactly', () {
      expect(showcaseE1rm(180, 1), 180);
      expect(showcaseE1rm(2.5, 1), 2.5);
      expect(showcaseE1rm(147.5, 1), 147.5);
    });

    test('two to twenty-five repetitions use Brzycki', () {
      expect(showcaseE1rm(180, 2), closeTo(180 * 36 / 35, 1e-9));
      expect(showcaseE1rm(100, 3), closeTo(100 * 36 / 34, 1e-9));
      expect(showcaseE1rm(100, 5), closeTo(100 * 36 / 32, 1e-9));
      expect(showcaseE1rm(60, 10), closeTo(60 * 36 / 27, 1e-9));
      expect(showcaseE1rm(40, 20), closeTo(40 * 36 / 17, 1e-9));
    });

    test('a worked example reads the way the showcase prints it', () {
      // 180 kg x 2 -> 185.1 kg. The card rounds for display; the stored value
      // keeps full precision.
      expect(showcaseE1rm(180, 2), closeTo(185.142857, 1e-5));
    });

    test('twenty-five repetitions is still Brzycki', () {
      expect(kBrzyckiMaxReps, 25);
      expect(showcaseE1rm(50, 25), closeTo(50 * 36 / 12, 1e-9));
    });

    test('twenty-six repetitions switches to Epley', () {
      expect(showcaseE1rm(50, 26), closeTo(50 * (1 + 0.0333 * 26), 1e-9));
    });

    test('the 25/26 boundary is a real discontinuity, not an off-by-one', () {
      final double at25 = showcaseE1rm(50, 25);
      final double at26 = showcaseE1rm(50, 26);
      // Brzycki blows up as reps approach 37; Epley stays tame. The two must
      // land far apart here, which is what makes an off-by-one impossible to
      // miss.
      expect(at25, greaterThan(at26));
      expect(at25 - at26, greaterThan(50));
    });

    test('invalid input yields zero rather than a nonsense record', () {
      expect(showcaseE1rm(0, 5), 0);
      expect(showcaseE1rm(100, 0), 0);
      expect(showcaseE1rm(-100, 5), 0);
      expect(showcaseE1rm(double.nan, 5), 0);
      expect(showcaseE1rm(100, double.infinity), 0);
    });
  });

  group('RIR independence', () {
    test('RIR is never added to repetitions', () {
      // If RIR leaked in, 100x5 @ RIR 3 would be computed as 100x8.
      expect(showcaseE1rm(100, 5), isNot(closeTo(showcaseE1rm(100, 8), 1e-9)));
      expect(showcaseE1rm(100, 5), closeTo(100 * 36 / 32, 1e-9));
    });

    test('the reducer produces identical records whatever the RIR says', () {
      Map<String, Object?> day(num? rir) => <String, Object?>{
            'exercises': <Object?>[
              <String, Object?>{
                'exerciseId': 'AmfUWbF1DH3I7qPAdh5k',
                'name': 'Bench Press, Barbell',
                'sets': <Object?>[
                  <String, Object?>{'weight': 100, 'reps': 5, 'rir': rir},
                ],
              },
            ],
          };

      final List<double> e1rms = <num?>[null, 0, 1, 4, 10]
          .map((num? rir) => buildShowcase(<String, Object?>{
                '2026-01-01': day(rir),
              }).forSlot('bench').bestE1rm!.e1rm)
          .toList();

      expect(e1rms.toSet(), hasLength(1),
          reason: 'RIR must not change a record in any way');
      expect(e1rms.first, closeTo(100 * 36 / 32, 1e-9));
    });
  });

  group('cross-implementation pins', () {
    test('matches PeriodizationModelUtils with RIR forced to zero', () {
      // The app's existing calculator is what every other screen uses. The
      // showcase must agree with it, or one lift would read differently in two
      // places in the same app.
      for (final List<num> c in <List<num>>[
        <num>[180, 1],
        <num>[180, 2],
        <num>[100, 5],
        <num>[60, 10],
        <num>[50, 25],
        <num>[50, 26],
        <num>[40, 30],
      ]) {
        expect(
          showcaseE1rm(c[0], c[1]),
          closeTo(
            PeriodizationModelUtils.calculateE1RM(
                c[0].toDouble(), c[1].toDouble(), 0.0),
            1e-9,
          ),
          reason: '${c[0]}kg x ${c[1]}',
        );
      }
    });

    test('the Cloud Functions mirror states the same constants', () {
      // A source-level pin: if someone edits the JS curve without editing this
      // spec, this fails. It reads the file rather than running node so the
      // check works in a plain `flutter test` run.
      final File js = File('functions/coach/e1rm.js');
      expect(js.existsSync(), isTrue,
          reason: 'the canonical Functions E1RM module must exist');
      final String source = js.readAsStringSync();

      expect(source, contains('if (r === 1) return w;'));
      expect(source, contains('if (r <= 25) return w * (36 / (37 - r));'));
      expect(source, contains('return w * (1 + 0.0333 * r);'));
      expect(source, contains('E1RM_FORMULA_VERSION = $kE1rmFormulaVersion'));
    });

    test('the showcase JS re-exports that one implementation, not a copy', () {
      final String source =
          File('functions/showcase/e1rm_spec.js').readAsStringSync();
      expect(source, contains("require('../coach/e1rm')"),
          reason: 'two arithmetic definitions in Functions could drift');
      // The comment header documents the curve; what must not appear is a
      // second IMPLEMENTATION of it.
      expect(source, isNot(contains(r'return w * (1 + 0.0333')),
          reason: 'two arithmetic definitions in Functions could drift');
      expect(source, isNot(contains(r'36 / (37 - r)')),
          reason: 'two arithmetic definitions in Functions could drift');
    });
  });

  group('formula versioning', () {
    test('every record carries the formula version it was computed under', () {
      final showcase = buildShowcase(<String, Object?>{
        '2026-01-01': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': 'AmfUWbF1DH3I7qPAdh5k',
              'sets': <Object?>[
                <String, Object?>{'weight': 100, 'reps': 5},
              ],
            },
          ],
        },
      });
      expect(showcase.forSlot('bench').bestE1rm!.formulaVersion,
          kE1rmFormulaVersion);
      expect(showcase.formulaVersion, kE1rmFormulaVersion);
    });
  });
}
