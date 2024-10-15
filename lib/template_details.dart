// template_details.dart
import 'package:flutter/material.dart';
import 'template_model.dart';

class TemplateDetailsScreen extends StatelessWidget {
  final Template template;
  final bool fromWorkoutPage;
  final Function(Template)? onLoadTemplate; // Callback function for loading the template

  const TemplateDetailsScreen({
    super.key,
    required this.template,
    this.fromWorkoutPage = false,
    this.onLoadTemplate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(template.name),
      ),
      body: Column(
        children: [
          Text('Day: ${template.day}'),
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
          if (fromWorkoutPage)
            ElevatedButton(
              onPressed: () {
                if (onLoadTemplate != null) {
                  onLoadTemplate!(template);  // Pass the selected template back
                }
                Navigator.pop(context, template); // Return the template to WorkoutPage
              },
              child: const Text('Load this template'),
            ),
        ],
      ),
    );
  }
}
