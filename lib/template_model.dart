class Template {
  final String id; // Add the id property
  final String name;
  final String day;
  final List<String> exercises; // List of exercise IDs

  Template({
    required this.id,
    required this.name,
    required this.day,
    required this.exercises,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'day': day,
      'exercises': exercises,
    };
  }

  Template copyWith({
    String? id, // Make id nullable for updates
    String? name,
    String? day,
    List<String>? exercises,
  }) {
    return Template(
      id: '',
      name: name ?? this.name,
      day: day ?? this.day,
      exercises: exercises ?? List.from(this.exercises),
    );
  }
}
