import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'create_template_screen.dart';
import 'template_model.dart';

class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key, this.fromWorkoutPage = false});

  final bool fromWorkoutPage;

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<Template> templates = [];
  List<Template> filteredTemplates = [];
  bool isLoading = true;
  String searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchTemplates();
  }

  Future<void> _fetchTemplates() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final snapshot = await userDoc.collection('templates').get();

      final templateList = snapshot.docs.map((doc) => Template(
        id: doc.id,
        name: doc.get('name'),
        day: doc.get('day'),
        exercises: List<String>.from(doc.get('exercises')),
      )).toList();

      setState(() {
        templates = templateList;
        filteredTemplates = templateList;
        isLoading = false;
      });
    }
  }

  void _filterTemplates(String query) {
    setState(() {
      searchQuery = query;
      filteredTemplates = templates.where((template) {
        return template.name.toLowerCase().contains(query.toLowerCase());
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Templates'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CreateTemplateScreen(onTemplateCreated: _fetchTemplates),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search Templates',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _filterTemplates,
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
              itemCount: filteredTemplates.length,
              itemBuilder: (context, index) {
                final template = filteredTemplates[index];
                return ExpansionTile(
                  title: Text(template.name),
                  subtitle: Text('Day: ${template.day}'),
                  children: [
                    Column(
                      children: template.exercises
                          .map((exercise) => ListTile(
                        title: Text(exercise),
                        leading: const Icon(Icons.fitness_center),
                      ))
                          .toList(),
                    ),
                    if (widget.fromWorkoutPage)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(context, template),
                          child: const Text('Select Template'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
