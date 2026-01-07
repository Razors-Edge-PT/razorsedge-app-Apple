class Template {
  final String id;
  String name;
  final String? day;

  /// Which block this template belongs to (Firestore block doc ID)
  final String? blockId;

  /// Human-friendly block label (e.g. "B1", "B2")
  /// Used for grouping templates in the selection dialog
  final String? blockAssignment;

  final List<Map<String, dynamic>> exercises; // circuit-aware

  Template({
    required this.id,
    required this.name,
    this.day,
    required this.exercises,
    this.blockId,
    this.blockAssignment,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (day != null) 'day': day,
      if (blockId != null) 'blockId': blockId,
      if (blockAssignment != null) 'blockAssignment': blockAssignment,
      'exercises': exercises,
    };
  }

  Template copyWith({
    String? id,
    String? name,
    String? day,
    List<Map<String, dynamic>>? exercises,
    String? blockId,
    String? blockAssignment,
  }) {
    return Template(
      id: id ?? this.id,
      name: name ?? this.name,
      day: day ?? this.day,
      exercises: exercises ?? List.from(this.exercises),
      blockId: blockId ?? this.blockId,
      blockAssignment: blockAssignment ?? this.blockAssignment,
    );
  }

  /// Create from Firestore snapshot with backward compatibility
  factory Template.fromFirestore(Map<String, dynamic> data, String docId) {
    final rawExercises = data['exercises'];

    // Backward compatibility for older string-only templates
    final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
        ? (rawExercises.first is Map
        ? List<Map<String, dynamic>>.from(rawExercises)
        : rawExercises
        .map((e) =>
    {'name': e.toString(), 'circuitIndex': 0})
        .toList())
        : <Map<String, dynamic>>[];

    return Template(
      id: docId,
      name: data['name'] ?? 'Unnamed',
      day: data['day'],
      blockId: data['blockId'],
      blockAssignment: data['blockAssignment'],       // ← NEW
      exercises: parsedExercises,
    );
  }
}

