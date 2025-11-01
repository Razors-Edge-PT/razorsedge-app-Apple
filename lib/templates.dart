import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// Import the shared methods
import 'create_template_screen.dart';
import 'template_details.dart';
import 'template_model.dart'; // Import Exercise model
import 'package:provider/provider.dart';
import 'user_context.dart';

class _DraggedExercise {
  final String sourceTemplateId;
  final int sourceIndex;

  _DraggedExercise({
    required this.sourceTemplateId,
    required this.sourceIndex,
  });
}

class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key, this.fromWorkoutPage = false});

  final bool
      fromWorkoutPage; // Add flag to determine if navigated from WorkoutPage

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<Template> templates = [];
  QuerySnapshot<Map<String, dynamic>>? templateSnapshot;

  // which template cards are currently expanded
  final Set<String> _expandedTemplateIds = {};

  // when you hover/drop we can give a little highlight
  String? _draggingOverTemplateId;
  // template.id -> extra circuit indices that have no exercises yet
  final Map<String, Set<int>> _extraEmptyCircuits = {};


  final _formKey = GlobalKey<FormState>();
  final String _templateName = '';
  final String _templateDay = '';
  final List<String> _selectedExercises = []; // List of selected exercise IDs
  Template? _lastDeletedTemplate;

  String get userId => UserContext.of(context, listen: false).currentUid;




  @override
  void initState() {
    super.initState();
    _fetchTemplates();
  }

  void _createTemplate() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateTemplateScreen(
          onTemplateCreated: _fetchTemplates, // Pass the refresh function
        ),
      ),
    );
  }

  Future<void> _fetchTemplates() async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    templateSnapshot = await userDoc.collection('templates').get();

    if (templateSnapshot != null) {
      print("📦 Raw Firestore template snapshot: ${templateSnapshot!.docs.length} templates");

      final templateList = templateSnapshot!.docs.map((doc) {
        final rawExercises = doc.get('exercises');

        final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
            ? (rawExercises.first is Map
            ? List<Map<String, dynamic>>.from(rawExercises)
            : List<Map<String, dynamic>>.from(
            (rawExercises).map((e) => {'name': e, 'circuitIndex': 0})))
            : <Map<String, dynamic>>[];

        return Template(
          id: doc.id,
          name: doc.get('name') ?? 'Unnamed',
          day: doc.data().containsKey('day') ? doc.get('day') : null,
          exercises: parsedExercises,
        );
      }).toList();

      setState(() {
        templates = templateList;
        print("✅ Parsed templates: ${templates.length}");
      });
    }
  }

  void _toggleExpanded(String templateId) {
    setState(() {
      if (_expandedTemplateIds.contains(templateId)) {
        _expandedTemplateIds.remove(templateId);
      } else {
        _expandedTemplateIds.add(templateId);
      }
    });
  }

  // collect all circuit indices used in this template, sorted
  List<int> _getCircuitIndices(Template template) {
    final set = <int>{};
    for (final ex in template.exercises) {
      final ci = (ex['circuitIndex'] ?? 0) as int;
      set.add(ci);
    }

    // also include explicit empty circuits we created via "+ Add circuit"
    final extra = _extraEmptyCircuits[template.id];
    if (extra != null) {
      set.addAll(extra);
    }

    final list = set.toList()..sort();
    return list.isEmpty ? [0] : list;
  }

  bool _isCircuitEmpty(Template template, int circuitIndex) {
    // if any real exercise uses this circuit, it's not empty
    final hasExercise = template.exercises.any(
          (ex) => (ex['circuitIndex'] ?? 0) == circuitIndex,
    );
    if (hasExercise) return false;

    // if it's one of our extra circuits, and has no exercises → it's empty
    final extra = _extraEmptyCircuits[template.id];
    if (extra != null && extra.contains(circuitIndex)) {
      return true;
    }

    return false;
  }

  void _removeEmptyCircuitForTemplate(Template template, int circuitIndex) {
    setState(() {
      final extra = _extraEmptyCircuits[template.id];
      if (extra != null) {
        extra.remove(circuitIndex);
        if (extra.isEmpty) {
          _extraEmptyCircuits.remove(template.id);
        }
      }
      // no Firestore write needed – there were no exercises to persist
    });
  }



  // given a GLOBAL index (position in template.exercises), tell me this exercise's position INSIDE its circuit
  int _positionInCircuit(Template template, int circuitIndex, int globalIndex) {
    int count = 0;
    for (int i = 0; i < template.exercises.length; i++) {
      final ex = template.exercises[i];
      if ((ex['circuitIndex'] ?? 0) == circuitIndex) {
        if (i == globalIndex) return count;
        count++;
      }
    }
    return count;
  }

  // find the GLOBAL index where we should insert something into the given circuit at the given circuit-position
  int _findGlobalInsertIndexForCircuit(
      Template template, {
        required int circuitIndex,
        required int positionInCircuit,
      }) {
    int seen = 0;
    for (int i = 0; i < template.exercises.length; i++) {
      final ex = template.exercises[i];
      final ci = (ex['circuitIndex'] ?? 0) as int;
      if (ci != circuitIndex) continue;

      // we've reached the correct spot inside this circuit
      if (seen == positionInCircuit) {
        return i;
      }
      seen++;
    }

    // if we got here: we want to append to the END of that circuit
    final lastIndexOfCircuit = template.exercises.lastIndexWhere(
          (ex) => (ex['circuitIndex'] ?? 0) == circuitIndex,
    );

    if (lastIndexOfCircuit == -1) {
      // circuit is currently empty → just dump at end of whole list
      return template.exercises.length;
    }

    return lastIndexOfCircuit + 1;
  }

  void _addEmptyCircuitForTemplate(Template template) {
    setState(() {
      final existing = _getCircuitIndices(template);
      final newCircuitIndex = (existing.isEmpty ? 0 : (existing.last + 1));
      _extraEmptyCircuits.putIfAbsent(template.id, () => <int>{}).add(newCircuitIndex);
      // no Firestore write yet — we persist when an exercise is dropped/added
    });
  }

  void _deleteExerciseFromDragged(_DraggedExercise dragged) {
    setState(() {
      final sourceTemplate = templates.firstWhere((t) => t.id == dragged.sourceTemplateId);
      if (dragged.sourceIndex < 0 || dragged.sourceIndex >= sourceTemplate.exercises.length) {
        return;
      }
      sourceTemplate.exercises.removeAt(dragged.sourceIndex);

      // persist
      _saveTemplateExercises(
        sourceTemplate.id,
        List<Map<String, dynamic>>.from(sourceTemplate.exercises),
      );
    });
  }


  Future<void> _showExercisePickerDialogForTemplate(Template template) async {
    // 1) load all exercises
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();
    final allExercises = snapshot.docs.map((doc) {
      return {
        'id': doc.id,
        'name': doc['name'] as String,
        'category': (doc.data().containsKey('category') ? doc['category'] as String : ''),
      };
    }).toList()
      ..sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));

    final List<Map<String, String>>? selected = await showDialog<List<Map<String, String>>>(
      context: context,
      builder: (ctx) {
        String search = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final filtered = search.trim().isEmpty
                ? allExercises
                : allExercises
                .where((ex) => ex['name']!.toLowerCase().contains(search.toLowerCase()))
                .toList();
            return AlertDialog(
              backgroundColor: Colors.blueGrey.shade900,
              title: const Text(
                'Select exercises',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      onChanged: (v) => setLocal(() => search = v),
                      decoration: InputDecoration(
                        hintText: 'Search...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.search, color: Colors.white70, size: 18),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final ex = filtered[i];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                            title: Text(
                              ex['name']!,
                              style: const TextStyle(color: Colors.white),
                            ),
                            onTap: () {
                              Navigator.pop(ctx, [ex]);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected == null || selected.isEmpty) return;

    // 2) figure out the last circuit for this template
    final circuits = _getCircuitIndices(template);
    final lastCircuit = circuits.isEmpty ? 0 : circuits.last;

    // 3) append to template + persist
    setState(() {
      for (final ex in selected) {
        template.exercises.add({
          'id': ex['id'],
          'name': ex['name'],
          'category': ex['category'] ?? '',
          'circuitIndex': lastCircuit,
        });
      }
    });

    await _saveTemplateExercises(
      template.id,
      List<Map<String, dynamic>>.from(template.exercises),
    );
  }




  Future<void> _saveTemplateExercises(String templateId, List<Map<String, dynamic>> exercises) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.collection('templates').doc(templateId).update({
      'exercises': exercises,
    });
  }

  void _moveExerciseToCircuit({
    required String targetTemplateId,
    required int targetCircuitIndex,
    required int targetPositionInCircuit,
    required _DraggedExercise dragged,
  }) {
    setState(() {
      // 1) source template + exercise
      final sourceTemplate = templates.firstWhere((t) => t.id == dragged.sourceTemplateId);
      final movedExercise = sourceTemplate.exercises.removeAt(dragged.sourceIndex);

      // 2) target template
      final targetTemplate = templates.firstWhere((t) => t.id == targetTemplateId);

      // 3) change the exercise's circuit to the target circuit
      movedExercise['circuitIndex'] = targetCircuitIndex;

      // 4) find CORRECT global insertion index inside target template
      final insertAt = _findGlobalInsertIndexForCircuit(
        targetTemplate,
        circuitIndex: targetCircuitIndex,
        positionInCircuit: targetPositionInCircuit,
      );

      targetTemplate.exercises.insert(insertAt, movedExercise);

      // 5) clear highlight
      _draggingOverTemplateId = null;

      // 6) persist
      _saveTemplateExercises(
        sourceTemplate.id,
        List<Map<String, dynamic>>.from(sourceTemplate.exercises),
      );

      // if moved across templates, persist target too
      if (sourceTemplate.id != targetTemplate.id) {
        _saveTemplateExercises(
          targetTemplate.id,
          List<Map<String, dynamic>>.from(targetTemplate.exercises),
        );
      } else {
        // same template but order changed
        _saveTemplateExercises(
          targetTemplate.id,
          List<Map<String, dynamic>>.from(targetTemplate.exercises),
        );
      }
    });
  }


  Widget _buildDraggableExerciseChip({
    required Template template,
    required int exerciseIndex, // GLOBAL index in template.exercises
  }) {
    final exercise = template.exercises[exerciseIndex];
    final name = (exercise['name'] ?? '').toString();
    final circuitIndex = (exercise['circuitIndex'] ?? 0) as int;

    // how far down in THIS circuit is this exercise?
    final positionInCircuit = _positionInCircuit(template, circuitIndex, exerciseIndex);

    return DragTarget<_DraggedExercise>(
      onWillAccept: (data) {
        setState(() {
          _draggingOverTemplateId = template.id;
        });
        return true;
      },
      onLeave: (_) {
        setState(() {
          _draggingOverTemplateId = null;
        });
      },
      onAccept: (data) {
        _moveExerciseToCircuit(
          targetTemplateId: template.id,
          targetCircuitIndex: circuitIndex,
          targetPositionInCircuit: positionInCircuit,
          dragged: data,
        );
      },
      builder: (context, candidate, rejected) {
        return LongPressDraggable<_DraggedExercise>(
          data: _DraggedExercise(
            sourceTemplateId: template.id,
            sourceIndex: exerciseIndex,
          ),
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                name,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: _exerciseChipBody(name),
          ),
          child: _exerciseChipBody(name),
        );
      },
    );
  }


  Widget _exerciseChipBody(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      margin: const EdgeInsets.only(right: 6, bottom: 6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade500,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          height: 1.1,
        ),
      ),
    );
  }
  Widget _buildEndDropZone(Template template, {required int circuitIndex}) {
    return DragTarget<_DraggedExercise>(
      onWillAccept: (data) {
        setState(() {
          _draggingOverTemplateId = template.id;
        });
        return true;
      },
      onLeave: (_) {
        setState(() {
          _draggingOverTemplateId = null;
        });
      },
      onAccept: (data) {
        // drop to END of this circuit
        final pos = 9999; // big number → _findGlobalInsertIndexForCircuit will append
        _moveExerciseToCircuit(
          targetTemplateId: template.id,
          targetCircuitIndex: circuitIndex,
          targetPositionInCircuit: pos,
          dragged: data,
        );
      },
      builder: (context, candidate, rejected) {
        final isActive = _draggingOverTemplateId == template.id && candidate.isNotEmpty;
        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          margin: const EdgeInsets.only(right: 6, bottom: 4, top: 2),
          decoration: BoxDecoration(
            color: isActive ? Colors.blueGrey.shade300.withOpacity(0.5) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive ? Colors.white54 : Colors.white24,
              width: isActive ? 1 : 0.5,
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            isActive ? 'Drop to add here' : '+ add to circuit',
            style: TextStyle(
              fontSize: 10,
              color: isActive ? Colors.white : Colors.white38,
            ),
          ),
        );
      },
    );
  }


  Future<void> _undoDeleteTemplate() async {
    if (_lastDeletedTemplate == null) return;

    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.collection('templates').doc(_lastDeletedTemplate!.id).set({
      'name': _lastDeletedTemplate!.name,
      'exercises': _lastDeletedTemplate!.exercises,
      if (_lastDeletedTemplate!.day != null) 'day': _lastDeletedTemplate!.day,
    });

    setState(() {
      templates.add(_lastDeletedTemplate!);
      _lastDeletedTemplate = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Template restored')),
    );
  }

  Future<bool> _confirmDeleteTemplate(BuildContext context, String templateId) async {
    final shouldDelete = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Are you sure you want to delete the template "${findTemplateName(templateId)}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete == true) {
      final deletedTemplate = templates.firstWhere((t) => t.id == templateId);
      _lastDeletedTemplate = deletedTemplate; // ✅ Save for undo
      await _deleteTemplateFromFirestore(templateId);
      setState(() {
        templates.removeWhere((t) => t.id == templateId);
      });
    }
    return shouldDelete ?? false;
  }

  Future<void> _confirmAndDeleteAllTemplates() async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Templates?'),
        content: const Text('This will permanently remove all saved templates. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      final batch = FirebaseFirestore.instance.batch();
      final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
      final templatesRef = userDoc.collection('templates');

      final snapshot = await templatesRef.get();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();

      setState(() {
        templates.clear();
        _lastDeletedTemplate = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('All templates deleted.'),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }




  String findTemplateName(String templateId) {
    // Find the template document using the doc ID from Firestore
    final matchingDoc =
        templateSnapshot?.docs.firstWhere((doc) => doc.id == templateId);

    // If a matching document is found, return the name
    if (matchingDoc != null) {
      return matchingDoc.get('name') as String;
    } else {
      // Handle missing template, return 'Unknown Template'
      return 'Unknown Template';
    }
  }

  Future<void> _deleteTemplateFromFirestore(String templateId) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    final templateRef = userDoc.collection('templates').doc(templateId);
    await templateRef.delete();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(

        title: const Text('Workout Planner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo Delete',
            onPressed: _lastDeletedTemplate != null ? _undoDeleteTemplate : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: 'Delete All Templates',
            onPressed: _confirmAndDeleteAllTemplates,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Template',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CreateTemplateScreen(
                    onTemplateCreated: _fetchTemplates,
                  ),
                ),
              );
            },
          ),
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 8),
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Create New Workout"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueGrey.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _createTemplate,
            ),
          ),
          const SizedBox(height: 16),

          if (templates.isEmpty)
            const Text(
              'No workouts created yet,\ntap Create New Workout to get started',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontStyle: FontStyle.italic,
              ),
            ),

          if (templates.isNotEmpty)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ReorderableListView.builder(
                itemCount: templates.length,
    onReorder: (oldIndex, newIndex) {
    setState(() {
    if (newIndex > oldIndex) newIndex--;
    final moved = templates.removeAt(oldIndex);
    templates.insert(newIndex, moved);
    });
    },
    buildDefaultDragHandles: false,
                  itemBuilder: (context, index) {
                    final template = templates[index];

                    return ReorderableDelayedDragStartListener(
                      index: index,
                      key: ValueKey(template.id),
                      child: Dismissible(
                        key: ValueKey('dismiss_${template.id}'),
                        direction: DismissDirection.endToStart,
                        confirmDismiss: (DismissDirection direction) async {
                          return await _confirmDeleteTemplate(context, template.id);
                        },
                        background: Container(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          color: Colors.red,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade700,
                            borderRadius: BorderRadius.circular(8),
                            border: _draggingOverTemplateId == template.id
                                ? Border.all(color: Colors.white60, width: 1)
                                : null,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // HEADER ROW
                              ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                title: Text(
                                  template.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                subtitle: template.day != null
                                    ? Text(
                                  template.day!,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white70,
                                  ),
                                )
                                    : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_expandedTemplateIds.contains(template.id))
                                      TextButton(
                                        onPressed: () => _showExercisePickerDialogForTemplate(template),
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text(
                                          '+ add exercise',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    IconButton(
                                      icon: Icon(
                                        _expandedTemplateIds.contains(template.id)
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        color: Colors.white70,
                                        size: 20,
                                      ),
                                      onPressed: () => _toggleExpanded(template.id),
                                    ),
                                  ],
                                ),

                                onTap: () => _navigateToTemplateDetails(context, template),
                              ),

                              // EXPANDED EXERCISES (circuit view)
                              if (_expandedTemplateIds.contains(template.id))
                                Padding(
                                  padding: const EdgeInsets.only(left: 12, right: 8, bottom: 8),
                                  child: Builder(
                                    builder: (context) {
                                      final circuitIndices = _getCircuitIndices(template);
                                      final circuitCount = circuitIndices.length;

                                      // 💡 rule:
                                      // - 1 → act like 2 → 165
                                      // - 2 → 165
                                      // - 3+ → 110
                                      const totalWidth = 320.0;
                                      final divisor = circuitCount == 1
                                          ? 2
                                          : (circuitCount >= 3 ? 3 : circuitCount); // 1→2, 2→2, 3+→3
                                      final columnWidth = totalWidth / divisor; // will be 165 or 110

                                      return SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            for (int i = 0; i < circuitIndices.length; i++)
                                              SizedBox(
                                                width: columnWidth,
                                                child: Builder(
                                                  builder: (context) {
                                                    final circuitIndex = circuitIndices[i];
                                                    final isLast = i == circuitIndices.length - 1;

                                                    return Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        // HEADER ROW for this circuit
                                                        Row(
                                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                          children: [
                                                            Row(
                                                              mainAxisSize: MainAxisSize.min,
                                                              children: [
                                                                if (_isCircuitEmpty(template, circuitIndex))
                                                                  InkWell(
                                                                    onTap: () => _removeEmptyCircuitForTemplate(
                                                                      template,
                                                                      circuitIndex,
                                                                    ),
                                                                    child: const Padding(
                                                                      padding: EdgeInsets.only(right: 4.0),
                                                                      child: Text(
                                                                        ' - ',
                                                                        style: TextStyle(
                                                                          fontSize: 11,
                                                                          color: Colors.white54,
                                                                          fontWeight: FontWeight.w500,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                Text(
                                                                  'Circuit ${circuitIndex + 1}',
                                                                  style: const TextStyle(
                                                                    fontSize: 11,
                                                                    fontWeight: FontWeight.w600,
                                                                    color: Colors.white70,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                            if (isLast)
                                                              InkWell(
                                                                onTap: () => _addEmptyCircuitForTemplate(template),
                                                                child: const Padding(
                                                                  padding: EdgeInsets.only(left: 6.0),
                                                                  child: Text(
                                                                    '+ circuit',
                                                                    style: TextStyle(
                                                                      fontSize: 10,
                                                                      color: Colors.white70,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                        const SizedBox(height: 4),

                                                        // exercises in this circuit
                                                        for (final entry in template.exercises.asMap().entries)
                                                          if ((entry.value['circuitIndex'] ?? 0) == circuitIndex)
                                                            _buildDraggableExerciseChip(
                                                              template: template,
                                                              exerciseIndex: entry.key,
                                                            ),

                                                        // drop zone
                                                        _buildEndDropZone(
                                                          template,
                                                          circuitIndex: circuitIndex,
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),

                            ],
                          ),
                        ),
                      ),
                    );
                  },

                ),
      ),

    ),
    ],
    ),
    );
  }

  void _navigateToTemplateDetails(BuildContext context, Template template) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TemplateDetailsScreen(
          template: template,
          //fromWorkoutPage: widget.fromWorkoutPage, // Pass the flag
          onLoadTemplate: (selectedTemplate) {
            Navigator.pop(context,
                selectedTemplate); // Pass the template back to WorkoutPage
          },
        ),
      ),
    );
  }
}