import 'package:flutter/material.dart';
import '../WES2_models.dart';

/// Placeholder exercise card — renders name, set count, circuit, and Done pill.
/// Full set-row rendering and field controllers are added in Phase 4.
class Wes2ExerciseCard extends StatelessWidget {
  final Wes2ExerciseRow row;

  const Wes2ExerciseCard({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(row.name),
        subtitle: Text(
          '${row.setCount} set${row.setCount == 1 ? '' : 's'} '
          '· Circuit ${row.circuitIndex + 1}'
          '${row.source == Wes2RowSource.bb3Planned ? ' · BB3 Plan' : ''}',
        ),
        trailing: row.isMarkedDone
            ? const Chip(
                label: Text(
                  'Done',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
                backgroundColor: Colors.green,
              )
            : null,
      ),
    );
  }
}
