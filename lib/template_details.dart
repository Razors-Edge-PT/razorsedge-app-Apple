import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'template_model.dart';
import 'exercise_catalog.dart';

class ExerciseRow {
  final String id;
  String name;
  int circuitIndex;

  ExerciseRow({
    required this.name,
    required this.circuitIndex,
    String? id,
  }) : id = id ?? const Uuid().v4();
}

class TemplateDetailsScreen extends StatefulWidget {
  final Template template;
  final void Function(Template)? onLoadTemplate; // 👈 Add this line

  const TemplateDetailsScreen({
    super.key,
    required this.template,
    this.onLoadTemplate, // 👈 Add this too
  });


  @override
  State<TemplateDetailsScreen> createState() => _TemplateDetailsScreenState();
}

class _TemplateDetailsScreenState extends State<TemplateDetailsScreen> {
  List<ExerciseRow> allRows = [];
  ExerciseRow? _lastRemovedRow;
  int? _lastRemovedIndex;
  late TextEditingController _nameController;
  List<String> plannedExercises = [];

  String get userId => UserContext.of(context, listen: false).currentUid;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.template.name);

    if (widget.template.exercises.isNotEmpty) {
      // 🧠 New Template with passed-in exercises ➔ load directly
      allRows = widget.template.exercises.map((e) {
        return ExerciseRow(
          name: e is String ? e : (e['name'] ?? ''),
          circuitIndex: e.containsKey('circuitIndex') ? e['circuitIndex'] ?? 0 : 0,
        );
      }).toList();
    } else {
      // 🔄 Otherwise (old templates) ➔ load from Firestore
      _loadTemplateFromFirestore();
    }
    _loadPlannedExercises();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadPlannedExercises() async {
    final blockPlannerDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('block_planner')
        .doc('current_block')
        .get();

    setState(() {
      plannedExercises = (blockPlannerDoc.data()?['plannedExercises'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ??
          [];
    });
  }


  Future<String?> _showExercisePickerDialog(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    // ✅ Make sure planned exercises are loaded first
    await _loadPlannedExercises();

    // Combined pool = global /exercises + this account's custom exercises.
    final combined =
        await ExerciseCatalog.loadCombinedExercisesForUser(userId);
    final allExercises = combined.map((e) => {
      'id': e.id, // ✅ important
      'name': e.name,
      'category': e.category,
    }).toList();


    bool showPlannedOnly = false;

    // Group exercises by category
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final exercise in allExercises) {
      final category = exercise['category'] ?? 'Other';
      grouped.putIfAbsent(category, () => []).add(exercise);
    }

    // Sort exercises alphabetically within each group
    for (final group in grouped.values) {
      group.sort((a, b) => a['name'].toLowerCase().compareTo(b['name'].toLowerCase()));
    }

    // Order categories in your custom order
    const categoryOrder = [
      'Horizontal Press', 'Horizontal Pull', 'Vertical Press', 'Vertical Pull',
      'Lateral Raise', 'Arm Extension', 'Arm Curl', 'Squat Pattern', 'Hip Hinge',
      'Leg Extension', 'Leg Curl', 'Hip Abduction/adduction', 'Calf Raise', 'Core',
    ];

    final Map<String, List<Map<String, dynamic>>> orderedGrouped = {};
    for (final cat in categoryOrder) {
      if (grouped.containsKey(cat)) {
        orderedGrouped[cat] = grouped[cat]!;
      }
    }
    for (final entry in grouped.entries) {
      if (!orderedGrouped.containsKey(entry.key)) {
        orderedGrouped[entry.key] = entry.value;
      }
    }

    final Map<String, bool> expandedGroups = {
      for (final key in orderedGrouped.keys) key: false
    };

    return await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final filteredGrouped = <String, List<Map<String, dynamic>>>{};
            orderedGrouped.forEach((category, exercises) {
              final filtered = showPlannedOnly
                  ? exercises.where((exercise) => plannedExercises.contains(exercise['id'])).toList()
                  : exercises;
              if (filtered.isNotEmpty) {
                filteredGrouped[category] = filtered;
              }
            });

            return AlertDialog(
              backgroundColor: Colors.blueGrey.shade900,
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Select Exercise', style: TextStyle(color: Colors.white, fontSize: 14)),
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) => setLocalState(() => showPlannedOnly = value),
                        activeColor: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  )
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 500,
                child: ListView(
                  children: filteredGrouped.entries.map((entry) {
                    final category = entry.key;
                    final exercises = entry.value;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          tileColor: Colors.blueGrey.shade800,
                          title: Text(
                            category,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                          trailing: Icon(
                            expandedGroups[category]! ? Icons.expand_less : Icons.expand_more,
                            color: Colors.white70,
                          ),
                          onTap: () {
                            setLocalState(() {
                              expandedGroups[category] = !(expandedGroups[category] ?? false);
                            });
                          },
                        ),
                        if (expandedGroups[category] ?? false)
                          ...exercises.map((exercise) => ListTile(
                            title: Text(exercise['name'], style: const TextStyle(color: Colors.white)),
                            onTap: () => Navigator.pop(context, exercise['name']),
                          )),
                        const Divider(height: 10, color: Colors.grey),
                      ],
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                ),
              ],
            );
          },
        );
      },
    );
  }


  Future<void> _loadTemplateFromFirestore() async {
    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('templates')
        .doc(widget.template.id);

    final snapshot = await docRef.get();
    if (!snapshot.exists) return;

    final data = snapshot.data();
    if (data == null) return;

    final loadedName = data['name'] ?? '';
    final loadedExercises = (data['exercises'] as List<dynamic>?) ?? [];

    setState(() {
      _nameController.text = loadedName;
      allRows = loadedExercises.map((e) {
        return ExerciseRow(
          name: e['name'] ?? '',
          circuitIndex: e['circuitIndex'] ?? 0,
        );
      }).toList();
    });
  }




  Future<void> _saveTemplateToFirestore() async {
    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('templates')
        .doc(widget.template.id);

    final exercises = allRows.map((row) => {
      'name': row.name,
      'circuitIndex': row.circuitIndex,
    }).toList();

    await docRef.set({
      'name': _nameController.text.trim(),
      'exercises': exercises,
      if (widget.template.day != null) 'day': widget.template.day,
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Template saved to Firestore')),
    );
  }



  void _addCircuit() {
    final newCircuit = (allRows.map((r) => r.circuitIndex).fold(-1, (a, b) => a > b ? a : b)) + 1;
    setState(() {
      allRows.add(ExerciseRow(name: 'New Exercise', circuitIndex: newCircuit));
    });
  }

  void _addExerciseBelow(ExerciseRow row) {
    final insertIndex = allRows.indexOf(row) + 1;
    setState(() {
      allRows.insert(insertIndex, ExerciseRow(name: 'New Exercise', circuitIndex: row.circuitIndex));
    });
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo last delete',
            onPressed: (_lastRemovedRow != null && _lastRemovedIndex != null)
                ? () {
              setState(() {
                allRows.insert(
                  _lastRemovedIndex! > allRows.length ? allRows.length : _lastRemovedIndex!,
                  _lastRemovedRow!,
                );
                _lastRemovedRow = null;
                _lastRemovedIndex = null;
              });
            }
                : null,
          ),

          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveTemplateToFirestore,
          ),
        ],
      ),

      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _nameController,
              style: const TextStyle(fontSize: 18, color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Template Name',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white54),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white),
                ),
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: allRows.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;

                  final moved = allRows.removeAt(oldIndex);
                  allRows.insert(newIndex, moved);

                  // 🧠 Detect surrounding context to assign correct circuitIndex
                  int? newCircuitIndex;
                  if (newIndex > 0) {
                    newCircuitIndex = allRows[newIndex - 1].circuitIndex;
                  } else if (allRows.length > 1) {
                    newCircuitIndex = allRows[1].circuitIndex;
                  }

                  if (newCircuitIndex != null) {
                    moved.circuitIndex = newCircuitIndex;
                  }
                });
              },
              buildDefaultDragHandles: false,
              itemBuilder: (context, index) {
                final row = allRows[index];
                final color = Colors.blueGrey[(row.circuitIndex % 3) * 100 + 700] ?? Colors.blueGrey;

                final isFirstInCircuit = index == 0 || allRows[index].circuitIndex != allRows[index - 1].circuitIndex;
                final isLastInCircuit = index == allRows.lastIndexWhere((r) => r.circuitIndex == row.circuitIndex);

                return Column(
                  key: ValueKey(row.id),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isFirstInCircuit)
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 12, bottom: 4),
                        child: Text(
                          'Circuit ${row.circuitIndex + 1}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
                        ),
                      ),
                    Dismissible(
                      key: ValueKey(row.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        color: Colors.red,
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) {
                        setState(() {
                          _lastRemovedRow = row;
                          _lastRemovedIndex = index;
                          allRows.removeAt(index);
                        });

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Deleted "${row.name}"'),
                            action: SnackBarAction(
                              label: 'Undo',
                              textColor: Colors.blueGrey,
                              onPressed: () {
                                if (_lastRemovedRow != null && _lastRemovedIndex != null) {
                                  setState(() {
                                    allRows.insert(
                                      _lastRemovedIndex! > allRows.length ? allRows.length : _lastRemovedIndex!,
                                      _lastRemovedRow!,
                                    );
                                    _lastRemovedRow = null;
                                    _lastRemovedIndex = null;
                                  });
                                }
                              },
                            ),
                          ),
                        );
                      },
                      child: ReorderableDelayedDragStartListener(
                        index: index,
                        child: Card(
                          color: color,
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: ListTile(
                            title: InkWell(
                              onTap: () async {
                                final selected = await _showExercisePickerDialog(context);
                                if (selected != null) {
                                  setState(() => row.name = selected);
                                }
                              },
                              child: Text(
                                row.name,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (isLastInCircuit)
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 4, bottom: 12),
                        child: TextButton.icon(
                          onPressed: () => _addExerciseBelow(row),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Exercise', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCircuit,
        icon: const Icon(Icons.add),
        label: const Text('Add Circuit'),
      ),
    );
  }

}
