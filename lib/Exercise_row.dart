import 'package:uuid/uuid.dart';

class exerciseRow {
  final String id; // unique identifier
  String name;
  int circuitIndex;

  exerciseRow({
    required this.name,
    required this.circuitIndex,
    String? id,
  }) : id = id ?? const Uuid().v4();
}
