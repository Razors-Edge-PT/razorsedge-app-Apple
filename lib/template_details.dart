import 'package:flutter/material.dart';
import 'template_model.dart';
import 'workout_entry_screen.dart';
import 'workout_model.dart';

class TemplateDetailsScreen extends StatelessWidget {
  final Template template;
  final Function(Workout)? onLoadTemplate; // Callback to create a workout

  const TemplateDetailsScreen({
    super.key,
    required this.template,
    this.onLoadTemplate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          template.name,
          style: const TextStyle(color: Colors.black),
        ),
        backgroundColor: Colors.grey[200], // Pale grey background
        iconTheme: const IconThemeData(color: Colors.black), // Black icons
        elevation: 1,
        actions: [
          // Edit icon
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.black),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Edit template feature not implemented")),
              );
            },
            tooltip: 'Edit Template',
          ),
          // Load icon (arrow)
          IconButton(
            icon: const Icon(Icons.arrow_forward, color: Colors.black),
            onPressed: () {
              // Navigate to the workout entry screen with the selected template
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WorkoutPage(
                    initialTemplate: template, // Pass the template as an argument
                  ),
                ),
              );
            },
            tooltip: 'Load Template',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Day: ${template.day}'),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: template.exercises.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(template.exercises[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
