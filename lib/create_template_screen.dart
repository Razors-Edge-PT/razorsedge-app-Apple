import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'template_details.dart'; // 👈 unchanged
import 'exercise_model.dart';
import 'template_model.dart';
import 'template_utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'block_repository.dart';

class CreateTemplateScreen extends StatefulWidget {
  final VoidCallback onTemplateCreated; // Callback to refresh template list
  const CreateTemplateScreen({super.key, required this.onTemplateCreated});

  @override
  State<CreateTemplateScreen> createState() => _CreateTemplateScreenState();
}

class _CreateTemplateScreenState extends State<CreateTemplateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  // ---- circuits + drag/drop (new UI)
  final List<_EditableCircuit> _circuits = <_EditableCircuit>[];

  // ---- from your old screen
  bool _plannedOnly = false;
  bool _isLoading = true;
  String? _activeBlockId;

  List<Exercise> exercises = []; // fetched from Firestore
  Set<String> _plannedExerciseIds = {}; // planned exercise IDs (from block)

  // id/name helpers (local)
  final Map<String, Exercise> _exerciseById = {};
  final Map<String, String> _idByName = {}; // name -> id

  // Generate a unique ID (unchanged)
  final generatedId =
      'template_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

  @override
  void initState() {
    super.initState();
    // Start with one empty circuit
    _circuits.add(_EditableCircuit());
    _initLoad();
  }

  Future<void> _initLoad() async {
    await _fetchActiveBlockAndPlannedExercises();
    await _fetchExercises();
    setState(() => _isLoading = false);
  }

  Future<void> _fetchActiveBlockAndPlannedExercises() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _activeBlockId = await BlockRepository().fetchActiveBlockId();
    if (_activeBlockId == null) return;

    final docSnap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(user.uid)
        .collection('blocks')
        .doc(_activeBlockId!)
        .get();

    if (docSnap.exists && docSnap.data()!.containsKey('plannedExercises')) {
      final List<dynamic> plannedList = docSnap.data()!['plannedExercises'];
      _plannedExerciseIds = plannedList.cast<String>().toSet();
    }
  }

  Future<void> _fetchExercises() async {
    try {
      final querySnapshot =
      await FirebaseFirestore.instance.collection('exercises').get();

      final exerciseList = querySnapshot.docs
          .map((doc) => Exercise(
        id: doc.id,
        name: doc.get('name'),
        bodyPart: doc.get('bodyPart'),
        category: doc.get('category'),
      ))
          .toList();

      exercises = exerciseList;

      _exerciseById
        ..clear()
        ..addEntries(exercises.map((e) => MapEntry(e.id, e)));

      _idByName
        ..clear()
        ..addEntries(exercises.map((e) => MapEntry(e.name, e.id)));
    } catch (error) {
      // Keep UI usable even if this fails
    }
  }

  // ----- UI helpers: filtered list for the picker -----
  List<Exercise> _displayedExercises() {
    if (_plannedOnly) {
      final set = _plannedExerciseIds;
      return exercises.where((e) => set.contains(e.id)).toList();
    }
    return exercises;
  }

  // ----- Circuit UI -----
  @override
  void dispose() {
    for (final c in _circuits) {
      c.dispose();
    }
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayed = _displayedExercises();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Design Workout'),
        actions: [
          Row(
            children: [
              const Text('Planned Only', style: TextStyle(fontSize: 12)),
              Switch(
                value: _plannedOnly,
                onChanged: (value) {
                  setState(() {
                    _plannedOnly = value;
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: () => _submitTemplate(context),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
        key: _formKey,
        child: Column(
          children: [
            // Name
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Template Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                (value == null || value.trim().isEmpty)
                    ? 'Please enter a name'
                    : null,
              ),
            ),

            // Add circuit
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Add circuit'),
                  onPressed: () {
                    setState(() {
                      _circuits.add(_EditableCircuit());
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Circuits list (reorderable)
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                itemCount: _circuits.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final circuit = _circuits.removeAt(oldIndex);
                    _circuits.insert(newIndex, circuit);
                  });
                },
                buildDefaultDragHandles: false,
                itemBuilder: (context, index) =>
                    _buildCircuitCard(context, index, displayed),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircuitCard(
      BuildContext context,
      int index,
      List<Exercise> displayedExercises,
      ) {
    final circuit = _circuits[index];
    final theme = Theme.of(context);

    return Card(
      key: ValueKey(circuit.id),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey('circuit_${circuit.id}'),
          initiallyExpanded: circuit.expanded,
          maintainState: true,
          onExpansionChanged: (expanded) {
            setState(() => circuit.expanded = expanded);
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  'Circuit ${index + 1}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (_circuits.length > 1)
                IconButton(
                  tooltip: 'Remove circuit',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _circuits.removeAt(index).dispose();
                    });
                  },
                ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_indicator, color: theme.colorScheme.outline),
                ),
              ),
            ],
          ),
          children: [
            const SizedBox(height: 12),
            if (circuit.exercises.isEmpty)
              _buildEmptyExerciseTarget(circuit)
            else
              _buildExerciseList(circuit),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.fitness_center),
                label: const Text('Choose exercises'),
                onPressed: () => _openExercisePickerForCircuit(index, displayedExercises),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExerciseList(_EditableCircuit circuit) {
    final children = <Widget>[];
    for (var i = 0; i < circuit.exercises.length; i++) {
      children.add(
        _buildExerciseDropTarget(
          circuit: circuit,
          insertIndex: i,
          builder: (candidate) {
            final active = candidate.isNotEmpty;
            return Column(
              children: [
                _buildDropIndicator(active: active, dense: true),
                _buildExerciseRow(circuit, i),
              ],
            );
          },
        ),
      );
      if (i < circuit.exercises.length - 1) children.add(const Divider(height: 1));
    }
    children.add(
      _buildExerciseDropTarget(
        circuit: circuit,
        insertIndex: circuit.exercises.length,
        builder: (candidate) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _buildDropIndicator(active: candidate.isNotEmpty, dense: false),
        ),
      ),
    );
    return Column(children: children);
  }

  Widget _buildExerciseRow(_EditableCircuit circuit, int exerciseIndex) {
    final exercise = circuit.exercises[exerciseIndex];
    final theme = Theme.of(context);
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.drag_indicator, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(child: Text(exercise.name, style: theme.textTheme.bodyMedium)),
          IconButton(
            tooltip: 'Remove exercise',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() {
                circuit.exercises.remove(exercise);
              });
            },
          ),
        ],
      ),
    );

    return LongPressDraggable<_ExerciseDragData>(
      data: _ExerciseDragData(circuitId: circuit.id, exercise: exercise),
      feedback: Material(
        color: Colors.transparent,
        child: Card(
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(exercise.name, style: theme.textTheme.bodyMedium),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: row),
      child: row,
    );
  }

  Widget _buildEmptyExerciseTarget(_EditableCircuit circuit) {
    final theme = Theme.of(context);
    return _buildExerciseDropTarget(
      circuit: circuit,
      insertIndex: 0,
      builder: (candidate) {
        final active = candidate.isNotEmpty;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? theme.colorScheme.primary : theme.dividerColor),
            color: active ? theme.colorScheme.primary.withOpacity(0.08) : Colors.transparent,
          ),
          child: Text(
            'No exercises yet. Use the exercise picker below to add them.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
        );
      },
    );
  }

  Widget _buildDropIndicator({required bool active, required bool dense}) {
    final theme = Theme.of(context);
    final inactiveHeight = dense ? 0.0 : 8.0;
    final activeHeight = dense ? 12.0 : 16.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: active ? activeHeight : inactiveHeight,
      width: double.infinity,
      decoration: BoxDecoration(
        color: active ? theme.colorScheme.primary.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: active ? theme.colorScheme.primary : Colors.transparent),
      ),
    );
  }

  // IMPORTANT: builder takes List<_ExerciseDragData?> to match DragTarget's candidateData
  Widget _buildExerciseDropTarget({
    required _EditableCircuit circuit,
    required int insertIndex,
    required Widget Function(List<_ExerciseDragData?> candidate) builder,
  }) {
    return DragTarget<_ExerciseDragData>(
      onWillAccept: (data) => data != null,
      onAccept: (data) => _handleExerciseDrop(data, circuit, insertIndex),
      builder: (context, candidate, rejected) => builder(candidate),
    );
  }

  void _handleExerciseDrop(
      _ExerciseDragData data,
      _EditableCircuit targetCircuit,
      int insertIndex,
      ) {
    setState(() {
      final sourceCircuitIndex = _circuits.indexWhere((c) => c.id == data.circuitId);
      if (sourceCircuitIndex == -1) return;

      final sourceCircuit = _circuits[sourceCircuitIndex];
      final currentIndex = sourceCircuit.exercises.indexOf(data.exercise);
      if (currentIndex == -1) return;

      final movingExercise = sourceCircuit.exercises.removeAt(currentIndex);
      var destinationIndex = insertIndex;
      if (sourceCircuit == targetCircuit && currentIndex < insertIndex) {
        destinationIndex -= 1;
      }
      destinationIndex = destinationIndex.clamp(0, targetCircuit.exercises.length);
      targetCircuit.exercises.insert(destinationIndex, movingExercise);
    });
  }

  // -------- Picker (uses only material; no extra imports)
  Future<void> _openExercisePickerForCircuit(
      int circuitIndex,
      List<Exercise> displayedExercises,
      ) async {
    final circuit = _circuits[circuitIndex];

    // Initial selection: names already in the circuit
    final initialSelection = circuit.exercises.map((e) => e.name).toSet();

    final selectedNames = await _showExercisePickerDialog(
      context: context,
      allExercises: displayedExercises,
      initialSelection: initialSelection,
    );

    if (!mounted || selectedNames == null) return;

    setState(() {
      // Update circuit to exactly match the selection (keep alphabetical consistency)
      final keep = selectedNames.toSet();
      circuit.exercises.removeWhere((e) => !keep.contains(e.name));

      final existing = circuit.exercises.map((e) => e.name).toSet();
      final toAdd = selectedNames.where((n) => !existing.contains(n)).toList()
        ..sort();
      for (final name in toAdd) {
        circuit.exercises.add(_EditableExercise(name: name));
      }
    });
  }

  Future<Set<String>?> _showExercisePickerDialog({
    required BuildContext context,
    required List<Exercise> allExercises,
    required Set<String> initialSelection,
  }) async {
    // Group by category (same categories you used)
    final grouped = <String, List<Exercise>>{};
    for (final e in allExercises) {
      final cat = e.category ?? 'Other';
      grouped.putIfAbsent(cat, () => []).add(e);
    }

    // Custom category order
    final List<String> customCategoryOrder = [
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
      'Other',
    ];

    final selection = initialSelection.toSet();

    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Select exercises'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              children: [
                for (final category in customCategoryOrder)
                  if (grouped.containsKey(category))
                    ExpansionTile(
                      title: Text(category),
                      children: [
                        for (final e in (grouped[category]!..sort((a,b) => a.name.compareTo(b.name))))
                          StatefulBuilder(
                            builder: (context, setStateTile) => CheckboxListTile(
                              title: Text(e.name),
                              value: selection.contains(e.name),
                              onChanged: (val) {
                                setStateTile(() {
                                  if (val == true) {
                                    selection.add(e.name);
                                  } else {
                                    selection.remove(e.name);
                                  }
                                });
                              },
                            ),
                          ),
                      ],
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selection),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  // ----- Save (uses your existing addTemplateToFirestore and navigation)
  void _submitTemplate(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    // Build payload from circuits (each exercise saved with name + circuitIndex)
    final exerciseMaps = <Map<String, dynamic>>[];
    for (var circuitIndex = 0; circuitIndex < _circuits.length; circuitIndex++) {
      final circuit = _circuits[circuitIndex];
      for (final ex in circuit.exercises) {
        final exerciseName = ex.name.trim();
        if (exerciseName.isEmpty) continue;
        exerciseMaps.add({
          'name': exerciseName,
          'circuitIndex': circuitIndex,
        });
      }
    }

    if (exerciseMaps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one exercise')),
      );
      return;
    }

    final newTemplate = Template(
      id: ' ', // Firestore generated downstream (matching your old code)
      name: name,
      exercises: exerciseMaps,
    );

    addTemplateToFirestore(newTemplate, generatedId).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template created successfully')),
      );
      widget.onTemplateCreated();

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => TemplateDetailsScreen(
            template: Template(
              id: generatedId,
              name: name,
              exercises: exerciseMaps,
            ),
          ),
        ),
      );
    }).catchError((error) {
      // Handle errors as you wish
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to create template')),
      );
    });
  }
}

// ===== local types for the editor =====
class _ExerciseDragData {
  const _ExerciseDragData({required this.circuitId, required this.exercise});
  final int circuitId;
  final _EditableExercise exercise;
}

class _EditableCircuit {
  _EditableCircuit({List<_EditableExercise>? exercises, bool expanded = true})
      : id = _nextId++,
        expanded = expanded,
        exercises = exercises ?? <_EditableExercise>[];

  static int _nextId = 0;

  final int id;
  bool expanded;
  final List<_EditableExercise> exercises;

  void dispose() {}
}

class _EditableExercise {
  const _EditableExercise({this.name = ''});
  final String name;
}
