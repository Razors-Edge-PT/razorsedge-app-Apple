import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// at the top


const List<String> kExerciseCategories = [
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


const List<String> kBodyParts = [
  'Chest',
  'Anterior Delts',
  'Lateral Delts',
  'Rear Delts',
  'Triceps',
  'Biceps',
  'Forearms',
  'Lats',
  'Rhomboids',
  'Mid Traps',
  'Upper Traps',
  'Lower Back',
  'Abs',
  'Obliques',
  'Glutes',
  'Quads',
  'Hamstrings',
  'Calves',
  'Inner Thigh',
  'Hip Abductors',
];

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
      final qs = await FirebaseFirestore.instance.collection('exercises').get();

      final data = qs.docs.map((doc) {
        final m = doc.data();

        // Normalize to ordered List<String>
        List<String> parts;
        final rawList = m['bodyParts'];
        final rawString = m['bodyPart'];

        if (rawList is List) {
          parts = rawList.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        } else if (rawString is String) {
          parts = rawString
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        } else {
          parts = <String>[];
        }

        final firstPart = parts.isNotEmpty ? parts.first : '';

        return <String, dynamic>{
          'id'               : doc.id,
          'name'             : (m['name'] ?? '').toString(),
          'category'         : (m['category'] ?? '').toString(),
          'bodyParts'        : parts,                 // full, ordered
          'bodyPart'         : firstPart,             // legacy (primary)
          'bodyPartsDisplay' : parts.join(', '),      // convenient for UI
        };
      }).toList();
      for (final ex in data) {
        print('✅ ${ex['name']} → ${ex['bodyParts']}');
      }


      setState(() => exercises = data);
    } catch (e) {
      print('Error fetching exercises: $e');
    }


  }





  void _showAddExerciseDialog() {
    final nameCtrl = TextEditingController();
    final categoryCtrl = TextEditingController();
    final bodySearchCtrl = TextEditingController();


    String? pickedCategory;
    final List<String> pickedBodyParts = [];

    final formKey = GlobalKey<FormState>();

    InputDecoration _dec(String label, {Widget? icon}) => InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      filled: true,
      fillColor: Colors.blueGrey.shade800,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.blueGrey.shade700),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.cyanAccent, width: 1.6),
      ),
      prefixIcon: icon == null
          ? null
          : IconTheme(
        data: const IconThemeData(color: Colors.cyanAccent),
        child: icon,
      ),
    );

    FocusNode? bodyPartFocusNode; // capture the one RawAutocomplete gives us

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        void _addBodyPart(String bp) {
          if (!pickedBodyParts.contains(bp)) {
            pickedBodyParts.add(bp);
            bodySearchCtrl.clear();
            (ctx as Element).markNeedsBuild();
          }
        }

        Widget _chip(String text, int i) {
          return Container(
            margin: const EdgeInsets.only(right: 4, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade700,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.blueGrey.shade600),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(text, style: const TextStyle(color: Colors.white)),
              const SizedBox(width: 6),
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.cyanAccent),
                  onPressed: i == 0
                      ? null
                      : () {
                    final tmp = pickedBodyParts[i - 1];
                    pickedBodyParts[i - 1] = pickedBodyParts[i];
                    pickedBodyParts[i] = tmp;
                    (ctx as Element).markNeedsBuild();
                  },
                ),
                IconButton(
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_downward, size: 18, color: Colors.cyanAccent),
                  onPressed: i == pickedBodyParts.length - 1
                      ? null
                      : () {
                    final tmp = pickedBodyParts[i + 1];
                    pickedBodyParts[i + 1] = pickedBodyParts[i];
                    pickedBodyParts[i] = tmp;
                    (ctx as Element).markNeedsBuild();
                  },
                ),
                IconButton(
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close, size: 18, color: Colors.cyanAccent),
                  onPressed: () {
                    pickedBodyParts.removeAt(i);
                    (ctx as Element).markNeedsBuild();
                  },
                ),
              ]),
            ]),
          );
        }

        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
          contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          title: Row(
            children: const [
              Icon(Icons.fitness_center, color: Colors.cyanAccent),
              SizedBox(width: 10),
              Text('Add Exercise', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Form(
            key: formKey,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // Name
                  TextFormField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _dec('Name', icon: const Icon(Icons.text_fields)),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a name' : null,
                  ),
                  const SizedBox(height: 12),

                  // Category (type-ahead, canonical only)
                  RawAutocomplete<String>(
                    textEditingController: categoryCtrl,
                    focusNode: FocusNode(),
                    optionsBuilder: (TextEditingValue tev) {
                      final q = tev.text.toLowerCase().trim();
                      if (q.isEmpty) return const Iterable<String>.empty();
                      return kExerciseCategories.where((c) => c.toLowerCase().contains(q));
                    },
                    onSelected: (val) => pickedCategory = val,
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec('Category', icon: const Icon(Icons.category)),
                        validator: (_) {
                          final entered = controller.text.trim();
                          if (entered.isEmpty) return 'Please choose a category';

                          // Case-insensitive match against the canonical list
                          final match = kExerciseCategories.firstWhere(
                                (c) => c.toLowerCase() == entered.toLowerCase(),
                            orElse: () => '',
                          );

                          if (match.isEmpty) return 'Select one of the suggestions';

                          // Canonicalize the text (correct casing) and store it
                          if (controller.text != match) controller.text = match;
                          pickedCategory = match;
                          return null;
                        },
                        autovalidateMode: AutovalidateMode.onUserInteraction,

                      );
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Material(
                        color: Colors.blueGrey.shade800,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(8),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          children: options
                              .map((o) => ListTile(
                            dense: true,
                            title: Text(o, style: const TextStyle(color: Colors.white)),
                            trailing: const Icon(Icons.check, color: Colors.cyanAccent, size: 18),
                            onTap: () => onSelected(o),
                          ))
                              .toList(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14),

                  // Body parts title + tooltip
                  Row(
                    children: const [
                      Text('Body Parts (primary first)',
                          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                      SizedBox(width: 6),
                      Tooltip(
                        message:
                        'Put primary muscle(s) first, then others in descending order of involvement.\n'
                            'E.g., Bench Press: Chest, Anterior Delts, Triceps.',
                        child: Icon(Icons.info_outline, color: Colors.cyanAccent, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Body parts search + add (type-ahead)
                  RawAutocomplete<String>(
                    textEditingController: bodySearchCtrl,
                    focusNode: bodyPartFocusNode ??= FocusNode(),
                    optionsBuilder: (TextEditingValue tev) {
                      final q = tev.text.toLowerCase().trim();
                      if (q.isEmpty) return const Iterable<String>.empty();
                      return kBodyParts
                          .where((bp) => bp.toLowerCase().contains(q))
                          .where((bp) => !pickedBodyParts.contains(bp));
                    },
                    onSelected: (val) => _addBodyPart(val),
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec('Add body part', icon: const Icon(Icons.search)),
                      );
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Material(
                        color: Colors.blueGrey.shade800,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(8),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          children: options
                              .map((o) => ListTile(
                            dense: true,
                            title: Text(o, style: const TextStyle(color: Colors.white)),
                            trailing: const Icon(Icons.add, color: Colors.cyanAccent, size: 18),
                            onTap: () => onSelected(o),
                          ))
                              .toList(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),

                  // Selected body parts chips (ordered)
                  if (pickedBodyParts.isEmpty)
                    Text(
                      'Add at least one body part',
                      style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                    )
                  else
                    Wrap(
                      children: List.generate(
                        pickedBodyParts.length,
                            (i) => _chip(pickedBodyParts[i], i),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black87,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                elevation: 0,
              ),
              icon: const Icon(Icons.save),
              label: const Text('Save'),
              onPressed: () async {
                final validForm = (formKey.currentState?.validate() ?? false);
                final validBody = pickedBodyParts.isNotEmpty &&
                    pickedBodyParts.every((bp) => kBodyParts.contains(bp));
                if (!validForm || !validBody) return;

                final trimmedName = nameCtrl.text.trim();
                final category = pickedCategory ?? categoryCtrl.text.trim();

                await _addExercise(trimmedName, pickedBodyParts, category);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },

            ),
          ],
        );
      },
    );
  }



  Future<void> _addExercise(
      String name,
      List<String> bodyParts,
      String category,
      ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final data = <String, dynamic>{
      'name': name.trim(),
      'category': category,
      'bodyParts': bodyParts, // ← ordered list (primary first)
      // Legacy compatibility: keep first as 'bodyPart' if you still have code reading it
      if (bodyParts.isNotEmpty) 'bodyPart': bodyParts.first,
    };

    try {
      await FirebaseFirestore.instance.collection('exercises').add(data);
      _fetchExercises();
    } catch (e) {
      print('Error adding exercise: $e');
    }
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
      backgroundColor: Colors.blueGrey.shade900,
      appBar: AppBar(
        title: const Text('Exercises'),
        backgroundColor: Colors.blueGrey.shade800,
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
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.blueGrey.shade700,
        onPressed: _showAddExerciseDialog,
        child: const Icon(Icons.add),
      ),
    );

  }


// ➡️ Helper method to build a category card
  Widget _buildCategoryTile(String category, List<Map<String, dynamic>> exercises) {
    return Card(
      color: Colors.blueGrey.shade800,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        backgroundColor: Colors.blueGrey.shade800, // ✅ Keep category background
        collapsedBackgroundColor: Colors.blueGrey.shade800, // ✅ Collapsed too
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
            color: Colors.blueGrey.shade700, // ✅ Lighter background inside!
            child: Column(
              children: exercises.map((exercise) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercise['name'] ?? 'Unnamed Exercise',
                        style: const TextStyle(
                          color: Colors.white,
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
      ),
    );
  }
}
