class ExercisePairingUtils {
  static bool areCompatible(Map<String, String> a, Map<String, String> b) {
    final categoryA = a['category'] ?? '';
    final categoryB = b['category'] ?? '';
    final musclesA = _parseMuscleGroups(a['bodyPart']);
    final musclesB = _parseMuscleGroups(b['bodyPart']);

    // Rule 1: Don't allow duplicate category types in same pair
    if (_isPush(categoryA) && _isPush(categoryB)) return false;
    if (_isPull(categoryA) && _isPull(categoryB)) return false;
    if (_isLegOrCore(categoryA) && _isLegOrCore(categoryB)) return false;

    // Rule 2: Avoid overlap in main muscles worked
    if (musclesA.toSet().intersection(musclesB.toSet()).isNotEmpty) return false;

    // Rule 3: Horizontal press ↔ horizontal pull = good, same for vertical
    if ((categoryA == 'Horizontal Press' && categoryB == 'Horizontal Pull') ||
        (categoryA == 'Horizontal Pull' && categoryB == 'Horizontal Press')) {
      return true;
    }

    if ((categoryA == 'Vertical Press' && categoryB == 'Vertical Pull') ||
        (categoryA == 'Vertical Pull' && categoryB == 'Vertical Press')) {
      return true;
    }

    return true;
  }

  static bool _isPush(String category) =>
      category.contains('Press') || category == 'Arm Extension';

  static bool _isPull(String category) =>
      category.contains('Row') ||
          category.contains('Pull') ||
          category == 'Arm Curl';

  static bool _isLegOrCore(String category) =>
      category.contains('Squat') ||
          category.contains('Leg') ||
          category == 'Hip Hinge' ||
          category == 'Core' ||
          category == 'Calf Raise';

  static List<String> _parseMuscleGroups(String? bodyPart) {
    if (bodyPart == null) return [];
    return bodyPart
        .split(',')
        .map((m) => m.trim().toLowerCase())
        .where((m) => m.isNotEmpty)
        .toList();
  }
}
