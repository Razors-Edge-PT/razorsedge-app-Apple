import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_exercise_classifier.dart';
import 'package:localtest222/block_planner_2/bp2_models.dart';
import 'package:localtest222/exercise_catalog.dart';

CatalogExercise _g(String id, String name,
        {String category = 'Squat Pattern'}) =>
    CatalogExercise(
      id: id,
      name: name,
      category: category,
      bodyParts: const ['Quads'],
      bodyPart: 'Quads',
      source: ExerciseSource.global,
    );

CatalogExercise _c(String id, String name) => CatalogExercise(
      id: id,
      name: name,
      category: 'Core',
      bodyParts: const ['Abs'],
      bodyPart: 'Abs',
      source: ExerciseSource.custom,
      ownerUid: 'athlete',
    );

Bp2TemplateSummary _t(
        String id, String? blockId, List<(String, String)> refs) =>
    Bp2TemplateSummary(
      id: id,
      blockId: blockId,
      refs: [
        for (final r in refs) Bp2TemplateRef(exerciseId: r.$1, name: r.$2)
      ],
    );

void main() {
  final shared = [
    _g('sq', 'Back Squat, Barbell'),
    _g('bp', 'bench press, barbell'),
    _g('dl', 'Deadlift'),
    _g('ohp', 'Overhead Press'),
    _g('row', 'Row'),
  ];
  final custom = [
    _c('cust1', 'ab wheel'),
    _c('cust2', 'Cable Crunch'),
  ];

  group('mergeCatalogue', () {
    test(
        'merges shared and custom, sorted case-insensitively with id tie-break',
        () {
      final merged = Bp2ExerciseClassifier.mergeCatalogue(
        shared: [...shared, _g('zz2', 'Dup Name'), _g('zz1', 'dup name')],
        custom: custom,
      );
      expect(merged.map((e) => e.id).toList(), [
        'cust1', // ab wheel
        'sq', // Back Squat
        'bp', // bench press
        'cust2', // Cable Crunch
        'dl',
        'zz1', // dup name (id tie-break)
        'zz2',
        'ohp',
        'row',
      ]);
      expect(merged.firstWhere((e) => e.id == 'cust1').source,
          ExerciseSource.custom);
    });

    test('deduplicates by canonical id (shared wins over custom)', () {
      final merged = Bp2ExerciseClassifier.mergeCatalogue(
        shared: [_g('sq', 'Back Squat, Barbell')],
        custom: [_c('sq', 'Back Squat (custom copy)')],
      );
      expect(merged.length, 1);
      expect(merged.single.name, 'Back Squat, Barbell');
      expect(merged.single.source, ExerciseSource.global);
    });
  });

  group('classify', () {
    final catalogue =
        Bp2ExerciseClassifier.mergeCatalogue(shared: shared, custom: custom);

    test('current-block exercises take precedence over other blocks', () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', 'active', [('sq', 'Back Squat, Barbell'), ('bp', 'bench')]),
          _t('t2', 'old', [('sq', 'Back Squat, Barbell'), ('dl', 'Deadlift')]),
        ],
        activeBlockId: 'active',
        otherBlockIds: {'old'},
      );
      expect(g.currentBlock.map((e) => e.id), ['sq', 'bp']);
      expect(g.otherBlocks.map((e) => e.id), ['dl']);
      expect(g.allOther.map((e) => e.id), ['cust1', 'cust2', 'ohp', 'row']);
    });

    test(
        'other-block exercises deduplicate across historic and upcoming blocks',
        () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', 'old1', [('dl', 'Deadlift'), ('row', 'Row')]),
          _t('t2', 'old2', [('dl', 'Deadlift')]),
          _t('t3', 'future', [('dl', 'Deadlift'), ('ohp', 'Overhead Press')]),
        ],
        activeBlockId: 'active',
        otherBlockIds: {'old1', 'old2', 'future'},
      );
      expect(g.currentBlock, isEmpty);
      expect(g.otherBlocks.map((e) => e.id), ['dl', 'ohp', 'row']);
      expect(g.allOther.map((e) => e.id), ['cust1', 'sq', 'bp', 'cust2']);
    });

    test('all other exercises excludes both template-derived groups', () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', 'active', [('cust1', 'ab wheel')]),
          _t('t2', 'old', [('row', 'Row')]),
        ],
        activeBlockId: 'active',
        otherBlockIds: {'old'},
      );
      final all = {...g.currentBlock, ...g.otherBlocks, ...g.allOther};
      expect(all.length, catalogue.length);
      expect(g.allOther.any((e) => e.id == 'cust1' || e.id == 'row'), isFalse);
    });

    test('no active block → everything template-linked is "other"', () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', 'b1', [('sq', 'Back Squat, Barbell')])
        ],
        activeBlockId: null,
        otherBlockIds: {'b1'},
      );
      expect(g.currentBlock, isEmpty);
      expect(g.otherBlocks.map((e) => e.id), ['sq']);
    });

    test('templates without a block contribute nothing', () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', null, [('sq', 'Back Squat, Barbell')])
        ],
        activeBlockId: 'active',
        otherBlockIds: const {},
      );
      expect(g.currentBlock, isEmpty);
      expect(g.otherBlocks, isEmpty);
      expect(g.allOther.length, catalogue.length);
    });

    test(
        'legacy name-only references resolve by exact name; unknown stay visible',
        () {
      final g = Bp2ExerciseClassifier.classify(
        catalogue: catalogue,
        templates: [
          _t('t1', 'active', [
            ('', 'back squat, barbell'), // name only, different case
            ('Ghost Exercise', 'Ghost Exercise'), // legacy id == name
          ]),
        ],
        activeBlockId: 'active',
        otherBlockIds: const {},
      );
      expect(g.currentBlock.map((e) => e.id), ['sq', 'Ghost Exercise']);
      final ghost = g.currentBlock.last;
      expect(ghost.unresolvedReference, isTrue);
      expect(ghost.name, 'Ghost Exercise');
      // The catalogue itself is untouched.
      expect(g.allOther.any((e) => e.unresolvedReference), isFalse);
    });
  });
}
