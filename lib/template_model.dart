class Template {
  final String id; // Add the id property
  final String name;
  final String? day; // ✅ make nullable
  final List<String> exercises; // List of exercise IDs

  Template({
    required this.id,
    required this.name,
   this.day,
    required this.exercises,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (day != null) 'day': day, // ✅ only include if present
      'exercises': exercises,
    };
  }

  Template copyWith({
    String? id,
    String? name,
    String? day,
    List<String>? exercises,
  }) {
    return Template(
      id: id ?? this.id,
      name: name ?? this.name,
      day: day ?? this.day,
      exercises: exercises ?? List.from(this.exercises),
    );
  }
}