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

  Future<void> _saveTemplateExercises(String templateId, List<Map<String, dynamic>> exercises) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.collection('templates').doc(templateId).update({
      'exercises': exercises,
    });
  }

  void _moveExercise({
    required String targetTemplateId,
    required int targetIndex,
    required _DraggedExercise dragged,
  }) {
    setState(() {
      // 1) find source + target
      final sourceTemplate = templates.firstWhere((t) => t.id == dragged.sourceTemplateId);
      final targetTemplate = templates.firstWhere((t) => t.id == targetTemplateId);

      // 2) take the exercise out of source
      final movedExercise = sourceTemplate.exercises.removeAt(dragged.sourceIndex);

      // 3) if moving within same template, adjust index if needed
      int insertIndex = targetIndex;
      if (dragged.sourceTemplateId == targetTemplateId && dragged.sourceIndex < targetIndex) {
        insertIndex = targetIndex - 1;
      }

      // clamp
      if (insertIndex < 0) insertIndex = 0;
      if (insertIndex > targetTemplate.exercises.length) {
        insertIndex = targetTemplate.exercises.length;
      }

      // 4) insert
      targetTemplate.exercises.insert(insertIndex, movedExercise);

      // 5) clear highlight
      _draggingOverTemplateId = null;

      // 6) persist both if different
      _saveTemplateExercises(sourceTemplate.id, List<Map<String, dynamic>>.from(sourceTemplate.exercises));
      if (sourceTemplate.id != targetTemplate.id) {
        _saveTemplateExercises(targetTemplate.id, List<Map<String, dynamic>>.from(targetTemplate.exercises));
      }
    });
  }

  Widget _buildDraggableExerciseChip({
    required Template template,
    required int exerciseIndex,
  }) {
    final exercise = template.exercises[exerciseIndex];
    final name = (exercise['name'] ?? '').toString();

    // a drop *before* this chip
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
        _moveExercise(
          targetTemplateId: template.id,
          targetIndex: exerciseIndex,
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
  Widget _buildEndDropZone(Template template) {
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
        _moveExercise(
          targetTemplateId: template.id,
          targetIndex: template.exercises.length,
          dragged: data,
        );
      },
      builder: (context, candidate, rejected) {
        final isActive = _draggingOverTemplateId == template.id && candidate.isNotEmpty;
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          margin: const EdgeInsets.only(right: 6, bottom: 4, top: 2),
          decoration: BoxDecoration(
            color: isActive ? Colors.blueGrey.shade300.withOpacity(0.5) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: isActive
                ? Border.all(color: Colors.white54, width: 1)
                : Border.all(color: Colors.white24, width: 0.5),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            isActive ? 'Drop to add here' : '+ drop exercise',
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
                                trailing: IconButton(
                                  icon: Icon(
                                    _expandedTemplateIds.contains(template.id)
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                  onPressed: () => _toggleExpanded(template.id),
                                ),
                                onTap: () => _navigateToTemplateDetails(context, template),
                              ),

                              // EXPANDED EXERCISES
                              if (_expandedTemplateIds.contains(template.id))
                                Padding(
                                  padding: const EdgeInsets.only(left: 12, right: 8, bottom: 8),
                                  child: Wrap(
                                    spacing: 0,
                                    runSpacing: 0,
                                    children: [
                                      for (int exIndex = 0; exIndex < template.exercises.length; exIndex++)
                                        _buildDraggableExerciseChip(
                                          template: template,
                                          exerciseIndex: exIndex,
                                        ),
                                      _buildEndDropZone(template),
                                    ],
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