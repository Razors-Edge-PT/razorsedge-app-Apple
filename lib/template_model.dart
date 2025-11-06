class Template {
  final String id;
  final String name;
  final String? day;
  final String? blockId; // 🔗 which block this template belongs to (active/upcoming/etc)

  final List<Map<String, dynamic>> exercises; // ✅ circuit-aware

  Template({
    required this.id,
    required this.name,
    this.day,
    required this.exercises,
    this.blockId, // 👈 add
  });


  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (day != null) 'day': day,
      if (blockId != null) 'blockId': blockId,
      'exercises': exercises,
    };
  }

  Template copyWith({
    String? id,
    String? name,
    String? day,
    List<Map<String, dynamic>>? exercises,
    String? blockId,
  }) {
    return Template(
      id: id ?? this.id,
      name: name ?? this.name,
      day: day ?? this.day,
      exercises: exercises ?? List.from(this.exercises),
      blockId: blockId ?? this.blockId,
    );
  }


  // 🧠 Helper: create from Firestore snapshot with backward compatibility
  factory Template.fromFirestore(Map<String, dynamic> data, String docId) {
    final rawExercises = data['exercises'];

    // Backward compatibility with string-only exercise templates
    final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
        ? (rawExercises.first is Map
        ? List<Map<String, dynamic>>.from(rawExercises)
        : rawExercises
        .map((e) => {'name': e.toString(), 'circuitIndex': 0})
        .toList())
        : <Map<String, dynamic>>[];

    return Template(
      id: docId,
      name: data['name'] ?? 'Unnamed',
      blockId: data['blockId'] as String?, // may be null for legacy docs
      day: data.containsKey('day') ? data['day'] : null,
      exercises: parsedExercises,
    );
  }
}
