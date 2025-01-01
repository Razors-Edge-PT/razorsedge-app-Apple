class SetDetails {
  int setNumber;
  String reps;
  String weight;
  String rir;

  SetDetails({
    required this.setNumber,
    required this.reps,
    required this.weight,
    required this.rir,
  });

  // Factory constructor to create SetDetails from Firestore data
  factory SetDetails.fromFirestore(Map<String, dynamic> data) {
    return SetDetails(
      setNumber: data['setNumber'] ?? 1,  // Default to 1 if not provided
      reps: data['reps'] ?? '',
      weight: data['weight'] ?? '',
      rir: data['rir'] ?? '',
    );
  }

  // Method to convert SetDetails to a Firestore-friendly map
  Map<String, dynamic> toMap() {
    return {
      'setNumber': setNumber,
      'reps': reps,
      'weight': weight,
      'rir': rir,
    };
  }
}
