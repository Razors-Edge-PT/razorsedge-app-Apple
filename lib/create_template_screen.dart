import 'dart:async' show unawaited;
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'template_details.dart'; // 👈 unchanged
import 'template_model.dart';
import 'template_utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'block_repository.dart';
import 'block_exercise_defaults_repository.dart';
import 'user_context.dart';
import 'package:provider/provider.dart';
import 'main.dart' show showAppSnack;
import 'WES2_widgets/WES2_exercise_picker.dart';




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
  bool _isLoading = true;
  String? _activeBlockId;
  // ---- blocks for dropdown
  List<Map<String, String>> _blocks = []; // [{id, name}]
  String? _selectedBlockId;
  String? _selectedBlockName;

  // Generate a unique ID (unchanged)
  final generatedId =
      'template_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

  String get userId => context.read<UserContext>().currentUid;


  @override
  void initState() {
    super.initState();
    // Start with one empty circuit
    _circuits.add(_EditableCircuit());
    _initLoad();
  }

  Future<void> _initLoad() async {
    await _fetchActiveBlockAndPlannedExercises();
    setState(() => _isLoading = false);
  }

  Future<void> _fetchActiveBlockAndPlannedExercises() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1) active block
    _activeBlockId = await BlockRepository().fetchActiveBlockId(userId);



    // 2) load ALL blocks for dropdown
    final blocksSnap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId) // ✅ selected athlete
        .collection('blocks')
        .get();

    final loadedBlocks = <Map<String, String>>[];
    for (final doc in blocksSnap.docs) {
      final data = doc.data();

      // Try common fields you’ve used elsewhere; fall back gracefully
      final name = (data['name'] ??
          data['blockName'] ??
          data['blockAssignment'] ??
          doc.id)
          .toString();

      loadedBlocks.add({
        'id': doc.id,
        'name': name,
      });
    }

    // 3) default dropdown to active block if possible
    if (_activeBlockId != null) {
      final activeBlock = loadedBlocks.firstWhere(
            (b) => b['id'] == _activeBlockId,
        orElse: () => loadedBlocks.isNotEmpty ? loadedBlocks.first : {'id': _activeBlockId!, 'name': 'Active Block'},
      );
      _selectedBlockId = activeBlock['id'];
      _selectedBlockName = activeBlock['name'];
    } else if (loadedBlocks.isNotEmpty) {
      _selectedBlockId = loadedBlocks.first['id'];
      _selectedBlockName = loadedBlocks.first['name'];
    }

    _blocks = loadedBlocks;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Design Workout'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _submitTemplate,
          ),
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
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
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
            const SizedBox(height: 2),
            // Block selector + Add circuit on same row
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 3, 4),
              child: Row(
                children: [
                  // smaller dropdown on the left
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      isDense: true,
                      isExpanded: true, // ✅ forces dropdown to take available width
                      value: _selectedBlockId,
                      decoration: InputDecoration(
                        labelText: 'Block',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),

                        // 👇 normal border
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white70, width: 1.2),
                          borderRadius: BorderRadius.circular(6),
                        ),

                        // 👇 border when focused
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white70, width: 1.6),
                          borderRadius: BorderRadius.circular(6),
                        ),

                        // 👇 optional hover border (desktop/web)
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueGrey.shade300),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),


                      // ✅ controls ONLY the collapsed (selected) view to ellipsize safely
                      selectedItemBuilder: (context) {
                        return _blocks.map((b) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              b['name'] ?? 'Unnamed block',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          );
                        }).toList();
                      },

                      items: _blocks.map((b) {
                        return DropdownMenuItem<String>(
                          value: b['id'],
                          child: Text(
                            b['name'] ?? 'Unnamed block',
                            // expanded menu can show full name naturally
                          ),
                        );
                      }).toList(),

                      onChanged: (val) {
                        setState(() {
                          _selectedBlockId = val;
                          _selectedBlockName =
                          _blocks.firstWhere((b) => b['id'] == val)['name'];
                        });
                      },
                    ),

                  ),
                  const SizedBox(width: 6),

                  // add circuit button on the right
                  Expanded(
                    flex: 2,
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
                ],
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
                    _buildCircuitCard(context, index),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircuitCard(BuildContext context, int index) {
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
                onPressed: () => _openExercisePickerForCircuit(index),
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

  // -------- Picker — delegates to WES2 picker bottom sheet
  Future<void> _openExercisePickerForCircuit(int circuitIndex) async {
    // Whole-template exclusion: hide exercises already added anywhere
    final excludedIds = <String>{};
    for (final c in _circuits) {
      for (final ex in c.exercises) {
        if (ex.id.isNotEmpty) excludedIds.add(ex.id);
      }
    }

    final result = await showModalBottomSheet<
        ({String exerciseId, String name, int circuitIndex})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Wes2ExercisePicker(
        excludedIds: excludedIds,
        actingUid: userId,
        activeBlockId: _selectedBlockId ?? _activeBlockId,
        availableCircuits: List.generate(_circuits.length, (i) => i),
        initialCircuitIndex: circuitIndex,
        titleOverride: 'Add Exercise to Circuit ${circuitIndex + 1}',
      ),
    );

    if (!mounted || result == null) return;

    final targetIndex = result.circuitIndex.clamp(0, _circuits.length - 1);
    setState(() {
      _circuits[targetIndex].exercises.add(
        _EditableExercise(id: result.exerciseId, name: result.name),
      );
    });

    final blockId = _selectedBlockId ?? _activeBlockId;
    if (blockId != null && blockId.isNotEmpty) {
      unawaited(BlockExerciseDefaultsRepository.ensureExerciseDefaults(
        uid: userId,
        blockId: blockId,
        exerciseId: result.exerciseId,
      ));
    }
  }

  // ----- Save (uses your existing addTemplateToFirestore and navigation)
  Future<void> _submitTemplate() async {
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
          'exerciseId': ex.id,
          'name': exerciseName,
          'circuitIndex': circuitIndex,
        });
      }
    }

    if (exerciseMaps.isEmpty) {
      if (!mounted) return;
      showAppSnack('Please add at least one exercise');

      return;
    }

    final chosenBlockId = _selectedBlockId ?? _activeBlockId;
    final chosenBlockName = _selectedBlockName ??
        _blocks.firstWhere(
              (b) => b['id'] == chosenBlockId,
          orElse: () => {'name': 'Active Block'},
        )['name'];

    final payload = {
      'name': name,
      'exercises': exerciseMaps,
      'blockId': chosenBlockId,
      'blockAssignment': chosenBlockName,
      'createdAt': FieldValue.serverTimestamp(),
      'isKept': true, // manual templates survive regeneration
    };

    try {
      final uid = context.read<UserContext>().currentUid;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('templates')
          .doc(generatedId)
          .set(payload);


      if (!mounted) return;

      showAppSnack('Template created successfully');


      widget.onTemplateCreated();

      // ✅ Pop even if you're inside a nested navigator
      Navigator.of(context, rootNavigator: true).pop(true);
    } catch (e, st) {
      print('❌ [CreateTemplate] save failed: $e');
      print(st);

      if (!mounted) return;
      showAppSnack('Failed to create template: $e');

    }
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
  const _EditableExercise({this.id = '', this.name = ''});
  final String id;
  final String name;
}
