from pathlib import Path

path = Path("lib/WES2_plan_service.dart")
s = path.read_text(encoding="utf-8")

start = s.find("  @override\n  Future<void> saveExerciseSettings({")
if start == -1:
    raise SystemExit("START ANCHOR NOT FOUND: saveExerciseSettings override")

end = s.find("\n}", start)
if end == -1:
    raise SystemExit("END ANCHOR NOT FOUND: class closing brace")

old_method_end = s.find("\n  }", start)
if old_method_end == -1:
    raise SystemExit("METHOD END NOT FOUND")

# Need the end of this method, not the first inner brace. Use the known final body from current implementation.
old_block = """  @override
  Future<void> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required Map<String, dynamic> settings,
  }) async {
    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);
    await docRef.set(
      {'exerciseSettings.$exerciseId': settings},
      SetOptions(merge: true),
    );
  }
"""

new_block = """  @override
  Future<void> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required Map<String, dynamic> settings,
  }) async {
    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    await FirebaseFirestore.instance.runTransaction((txn) async {
      final snap = await txn.get(docRef);
      final data = snap.exists
          ? (snap.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      final rawExerciseSettings = data['exerciseSettings'];
      final exerciseSettings = rawExerciseSettings is Map
          ? Map<String, dynamic>.from(rawExerciseSettings)
          : <String, dynamic>{};

      final rawExistingForExercise = exerciseSettings[exerciseId];
      final existingForExercise = rawExistingForExercise is Map
          ? Map<String, dynamic>.from(rawExistingForExercise)
          : <String, dynamic>{};

      exerciseSettings[exerciseId] = {
        ...existingForExercise,
        ...settings,
      };

      txn.set(
        docRef,
        {'exerciseSettings': exerciseSettings},
        SetOptions(merge: true),
      );
    });
  }
"""

if old_block not in s:
    raise SystemExit("Exact old saveExerciseSettings block not found. File may have changed.")

s = s.replace(old_block, new_block)
path.write_text(s, encoding="utf-8")
print("Patched WES2_plan_service.saveExerciseSettings nested exerciseSettings save.")
