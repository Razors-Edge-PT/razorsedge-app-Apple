import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// Import the shared methods
import 'create_template_screen.dart';
import 'template_details.dart';
import 'template_model.dart'; // Import Exercise model

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

  // ... other variables

  final _formKey = GlobalKey<FormState>();
  final String _templateName = '';
  final String _templateDay = '';
  final List<String> _selectedExercises = []; // List of selected exercise IDs
  Template? _lastDeletedTemplate;


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
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      templateSnapshot = await userDoc.collection('templates').get();

      if (templateSnapshot != null) {
        print("📦 Raw Firestore template snapshot: ${templateSnapshot!.docs.length} templates");

        final templateList = templateSnapshot!.docs.map((doc) {
          final rawExercises = doc.get('exercises');

          final parsedExercises = rawExercises is List && rawExercises.isNotEmpty
              ? (rawExercises.first is Map
              ? List<Map<String, dynamic>>.from(rawExercises)
              : List<Map<String, dynamic>>.from(
              (rawExercises as List).map((e) => {'name': e, 'circuitIndex': 0})))
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
  }

  Future<void> _undoDeleteTemplate() async {
    if (_lastDeletedTemplate == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      await userDoc.collection('templates').doc(_lastDeletedTemplate!.id).set({
        'name': _lastDeletedTemplate!.name,
        'exercises': _lastDeletedTemplate!.exercises,
        if (_lastDeletedTemplate!.day != null) 'day': _lastDeletedTemplate!.day,
      });
    }

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
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      final templateRef = userDoc.collection('templates').doc(templateId);
      await templateRef.delete();
    }
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

      body: ListView.builder(
        itemCount: templates.length,
        itemBuilder: (context, index) {
          final template = templates[index];
          print('Building list item: ${template.name}');
          return Dismissible(
            key: Key(template.id),
            direction: DismissDirection.endToStart,
            confirmDismiss: (DismissDirection direction) async {
              return await _confirmDeleteTemplate(context, template.id);
            },
            child: ListTile(
              title: Text(
                template.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: template.day != null
                  ? Text('Day: ${template.day}', style: const TextStyle(fontSize: 12))
                  : null,
              onTap: () => _navigateToTemplateDetails(context, template),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white),
                tooltip: 'Delete Template',
                onPressed: () => _confirmDeleteTemplate(context, template.id),
              ),
            ),
          );
        },
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
