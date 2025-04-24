import 'package:uuid/uuid.dart';

class ExerciseRow {
  final String id;
  String name;
  int circuitIndex;

  ExerciseRow({
    required this.name,
    required this.circuitIndex,
    String? id,
  }) : id = id ?? const Uuid().v4();
}
