import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'add_exercise_dialog.dart';
import 'exercise_catalog.dart';
import 'user_context.dart';
// at the top

export 'add_exercise_dialog.dart' show kExerciseCategories, kBodyParts;



class ExercisesScreen extends StatefulWidget {
  const ExercisesScreen({super.key});


  @override
  State<ExercisesScreen> createState() => _ExercisesScreenState();
}

class _ExercisesScreenState extends State<ExercisesScreen> {
  List<Map<String, dynamic>> exercises = [];
  final _formKey = GlobalKey<FormState>();
  String _name = '';
  String _bodyPart = '';
  String _category = '';

  Future<void> backfillBodyPartsOnce({bool dryRun = true}) async {
    final col = FirebaseFirestore.instance.collection('exercises');

    int scanned = 0, toUpdate = 0, updated = 0;
    const int pageSize = 450; // keep <500 to leave headroom
    DocumentSnapshot? last;

    List<List<QueryDocumentSnapshot<Map<String, dynamic>>>> pages = [];

    // Page through all docs
    while (true) {
      Query<Map<String, dynamic>> q = col.limit(pageSize);
      if (last != null) q = q.startAfterDocument(last!);

      final snap = await q.get();
      if (snap.docs.isEmpty) break;

      pages.add(snap.docs);
      last = snap.docs.last;
    }

    for (final docs in pages) {
      scanned += docs.length;
      final batch = FirebaseFirestore.instance.batch();

      for (final d in docs) {
        final m = d.data();

        final hasList = m['bodyParts'] is List;
        final raw = m['bodyPart'];

        if (!hasList && raw is String && raw.trim().isNotEmpty) {
          // Parse comma-separated string into ordered list
          final parts = raw
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

          if (parts.isNotEmpty) {
            toUpdate++;
            if (!dryRun) {
              batch.update(d.reference, {
                'bodyParts': parts,       // new canonical list (primary first)
                'bodyPart': parts.first,  // ensure primary matches first
              });
            }
            // Log for visibility
            // ignore: avoid_print
            print('→ ${d.id}: "$raw"  ==>  $parts');
          }
        }
      }

      if (!dryRun && toUpdate > 0) {
        await batch.commit();
        updated += toUpdate;
        toUpdate = 0;
      }
    }

    print('✅ Backfill scan complete. Scanned: $scanned, Updated: $updated (dryRun=$dryRun)');
  }

  @override
  void initState() {
    super.initState();
    _fetchExercises();
  }

  Future<void> _fetchExercises() async {
    try {
      // Combined pool = global /exercises + this account's custom exercises.
      // In coach mode currentUid is the selected athlete UID.
      final ownerUid = UserContext.of(context, listen: false).currentUid;
      final combined =
          await ExerciseCatalog.loadCombinedExercisesForUser(ownerUid);
      final data = combined.map((e) => e.toDisplayMap()).toList();

      if (!mounted) return;
      setState(() => exercises = data);
    } catch (e) {
      print('Error fetching exercises: $e');
    }
  }





  Future<void> _showAddExerciseDialog() async {
    final uc = UserContext.of(context, listen: false);
    // Admin (Richard) → global /exercises. Everyone else → their account's
    // custom pool at /users/{ownerUid}/customExercises (athlete in coach mode).
    final result = await showAddExerciseDialog(
      context,
      ownerUid: uc.currentUid,
      actorUid: uc.actorUid,
    );
    if (!mounted || result == null) return;
    if (result.isDuplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That exercise already exists in your list.'),
        ),
      );
      return;
    }
    _fetchExercises();
  }



  @override
  Widget build(BuildContext context) {
    // ➡️ Group exercises by category
    final Map<String, List<Map<String, dynamic>>> groupedExercises = {};
    for (var exercise in exercises) {
      final category = exercise['category'] ?? 'Other';
      if (!groupedExercises.containsKey(category)) {
        groupedExercises[category] = [];
      }
      groupedExercises[category]!.add(exercise);
    }

    const categoryOrder = [
      'Horizontal Press',
      'Horizontal Pull',
      'Vertical Press',
      'Vertical Pull',
      'Lateral Raise',
      'Arm Extension',
      'Arm Curl',
      'Squat Pattern',
      'Hip Hinge',
      'Leg Extension',
      'Leg Curl',
      'Hip Abduction/adduction',
      'Calf Raise',
      'Core',
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Exercises'),
        centerTitle: true,
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            // ➡️ Category groups
            ...categoryOrder
                .where((cat) => groupedExercises.containsKey(cat))
                .map((category) => _buildCategoryTile(category, groupedExercises[category]!)),

            // ➡️ Other categories
            ...groupedExercises.entries
                .where((entry) => !categoryOrder.contains(entry.key))
                .map((entry) => _buildCategoryTile(entry.key, entry.value)),

            const SizedBox(height: 40),
          ],
        ),


      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddExerciseDialog,
        child: const Icon(Icons.add),
      ),

    );

  }


// ➡️ Helper method to build a category card
  Widget _buildCategoryTile(String category, List<Map<String, dynamic>> exercises) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Builder(builder: (context) => ExpansionTile(
        backgroundColor: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
        collapsedBackgroundColor: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
        title: Text(
          category,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.white,
          ),
        ),
        children: [
          Container(
            color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
            child: Column(
              children: exercises.map((exercise) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercise['name'] ?? 'Unnamed Exercise',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        exercise['bodyPartsDisplay'] ?? 'Unknown Body Part',
                        style: TextStyle(
                          color: Colors.grey.shade300,
                          fontSize: 12,
                        ),
                      ),
                      const Divider(
                        height: 16,
                        thickness: 0.5,
                        color: Colors.white24,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      )),
    );
  }
}
