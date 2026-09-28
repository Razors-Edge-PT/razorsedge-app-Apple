import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/wes2_top_set_navigation.dart';

Wes2ExerciseRow _row(String exerciseId, Wes2RowSource source) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: 'Chin-Up',
      circuitIndex: 0,
      orderIndex: 0,
      setCount: 1,
      source: source,
    );

void main() {
  final DateTime targetDate = DateTime(2026, 4, 17);

  test('accepts the exact date, exercise, and completed workout source', () {
    expect(
      wes2TopSetTargetIsLoaded(
        selectedDate: DateTime(2026, 4, 17, 23, 45),
        targetDate: targetDate,
        exerciseId: 'chin-up',
        rows: <Wes2ExerciseRow>[
          _row('other', Wes2RowSource.completedServer),
          _row('chin-up', Wes2RowSource.completedServer),
        ],
        serverLoadConfirmed: true,
      ),
      isTrue,
    );
  });

  test('rejects a different workout date or exercise', () {
    final rows = <Wes2ExerciseRow>[
      _row('chin-up', Wes2RowSource.completedServer),
    ];
    expect(
      wes2TopSetTargetIsLoaded(
        selectedDate: DateTime(2026, 4, 18),
        targetDate: targetDate,
        exerciseId: 'chin-up',
        rows: rows,
        serverLoadConfirmed: true,
      ),
      isFalse,
    );
    expect(
      wes2TopSetTargetIsLoaded(
        selectedDate: targetDate,
        targetDate: targetDate,
        exerciseId: 'dip',
        rows: rows,
        serverLoadConfirmed: true,
      ),
      isFalse,
    );
  });

  test('rejects deleted, planned, local-only, or unconfirmed workouts', () {
    for (final source in <Wes2RowSource>[
      Wes2RowSource.bb3Planned,
      Wes2RowSource.wes2Manual,
      Wes2RowSource.templateLoaded,
      Wes2RowSource.localDraft,
    ]) {
      expect(
        wes2TopSetTargetIsLoaded(
          selectedDate: targetDate,
          targetDate: targetDate,
          exerciseId: 'chin-up',
          rows: <Wes2ExerciseRow>[_row('chin-up', source)],
          serverLoadConfirmed: true,
        ),
        isFalse,
      );
    }
    expect(
      wes2TopSetTargetIsLoaded(
        selectedDate: targetDate,
        targetDate: targetDate,
        exerciseId: 'chin-up',
        rows: <Wes2ExerciseRow>[_row('chin-up', Wes2RowSource.completedServer)],
        serverLoadConfirmed: false,
      ),
      isFalse,
    );
  });
}
