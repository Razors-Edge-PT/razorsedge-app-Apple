part of 'Camp_BB2.dart';

/// Helper to parse Firestore day documents into typed data
class DayPayload {
  final List<Map<String, dynamic>> exercises;
  final List<int> circuits;

  DayPayload({required this.exercises, required this.circuits});

  factory DayPayload.fromRaw(Map<String, dynamic> raw) {
    final exRaw = raw['exercises'] as List<dynamic>? ?? [];
    final exercises = exRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    final cirRaw = raw['circuitStartIndices'] as List<dynamic>? ?? [];
    final circuits = cirRaw.whereType<int>().toList();

    return DayPayload(exercises: exercises, circuits: circuits);
  }
}

/// These two methods now just become extension methods on your private State class.
/// Because this file is a `part of` your main, you can reach into all of its private fields.
extension BlockBuilderDataLoader on _BlockBuilder2State {
  Future<void> loadBlockDataFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final weekSnaps = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .get();

    await Future.wait(weekSnaps.docs.map((weekDoc) async {
      final weekIndex = int.parse(weekDoc.id.replaceFirst('week_', ''));
      final daySnaps = await weekDoc.reference.collection('days').get();

      for (final dayDoc in daySnaps.docs) {
        final dayIndex = int.parse(dayDoc.id.replaceFirst('day_', ''));
        final rawDay = dayDoc.data();
        if (rawDay == null) {
          print('⚠️ Missing data for week $weekIndex day $dayIndex');
          continue;
        }

        final payload =
        DayPayload.fromRaw(Map<String, dynamic>.from(rawDay));

        final loadedRows = payload.exercises.map((ex) {
          final row = ExerciseRow(
            exercise: ex['name'] as String? ?? '',
            circuitIndex: ex['circuitIndex'] as int? ?? 0,
          );
          final weight = (ex['weight'] as num?)?.toDouble() ?? 0.0;
          final reps = (ex['reps'] as num?)?.toInt() ?? 0;
          final rir = (ex['rir'] as num?)?.toDouble() ?? 0.0;
          if (weight > 0) row.weightController.text = weight.toString();
          if (reps > 0)   row.repsController.text   = reps.toString();
          if (rir > 0)    row.rirController.text    = rir.toString();
          return row;
        }).toList();

        exerciseRows[weekIndex][dayIndex] = loadedRows;
        circuitStartIndices[weekIndex][dayIndex] = payload.circuits;
      }
    }));

    setState(() {});
  }

  Future<void> loadBlockDataForWeek(int weekIndex) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final weekRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(user.uid)
        .collection('blocks')
        .doc(_selectedBlockId!)
        .collection('weeks')
        .doc('week_$weekIndex');

    final weekSnap = await weekRef.get();
    if (!weekSnap.exists) {
      print('❌ Week $weekIndex does not exist in Firestore.');
      return;
    }

    final daySnaps = await weekRef.collection('days').get();

    await Future.wait(daySnaps.docs.map((dayDoc) async {
      final dayIndex =
          int.tryParse(dayDoc.id.replaceFirst('day_', '')) ?? 0;
      final raw = dayDoc.data();
      if (raw == null) {
        print('⚠️ Missing data for week $weekIndex day $dayIndex');
        return;
      }

      final payload =
      DayPayload.fromRaw(Map<String, dynamic>.from(raw));
      final rows = payload.exercises.map((ex) {
        final row = ExerciseRow(
          id: const Uuid().v4(),
          exercise: ex['name'] as String? ?? '',
          circuitIndex: ex['circuitIndex'] as int? ?? 0,
        );
        final weightVal = (ex['weight'] as num?)?.toDouble();
        final repsVal   = (ex['reps']   as num?)?.toInt();
        final rirVal    = (ex['rir']    as num?)?.toDouble();
        if (weightVal != null && weightVal > 0)
          row.weightController.text = weightVal.toString();
        if (repsVal   != null && repsVal   > 0)
          row.repsController.text   = repsVal.toString();
        if (rirVal    != null && rirVal    > 0)
          row.rirController.text    = rirVal.toString();
        return row;
      }).toList();

      exerciseRows[weekIndex][dayIndex] = rows;
      circuitStartIndices[weekIndex][dayIndex] = payload.circuits;

      // …then your override logic…
      final workoutDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('block_data')
          .doc('current_block')
          .collection('weeks')
          .doc('week_$weekIndex')
          .collection('days')
          .doc('day_$dayIndex')
          .get();

      if (!workoutDoc.exists) return;
      final overrideRaw = workoutDoc.data();
      if (overrideRaw == null) return;
      final overridePayload = DayPayload.fromRaw(
        Map<String, dynamic>.from(overrideRaw),
      );

      // **Fix your firstWhere(…, orElse: () => null) here:**
      // orElse can't return null when T is non-nullable.  Instead…

      for (final ex in overridePayload.exercises) {
        final name    = ex['name'] as String? ?? '';
        final circuit = ex['circuitIndex'] as int? ?? 0;
        final sets    = List<Map<String, dynamic>>.from(ex['sets'] ?? []);

        // use try/catch or firstWhereOrNull (from package:collection)
        ExerciseRow? matching;
        try {
          matching = rows.firstWhere(
                (r) => r.exercise == name && r.circuitIndex == circuit,
          );
        } catch (_) {
          matching = null;
        }
        if (matching == null || sets.isEmpty) continue;

        matching.weightController.text = sets[0]['weight']?.toString() ?? '';
        matching.repsController.text   = sets[0]['reps']?.toString()   ?? '';
        matching.rirController.text    = sets[0]['rir']?.toString()    ?? '';
      }
    }));

    setState(() {});
  }
}
