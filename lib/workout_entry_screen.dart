import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'set_details.dart';

class WorkoutPage extends StatefulWidget {
  final Template? initialTemplate;
  final Workout? workout;
  final bool isNewWorkout;

  const WorkoutPage({super.key, this.initialTemplate, this.workout, this.isNewWorkout = true});

  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> {
  final TextEditingController _workoutNameController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  final List<String> _selectedExercises = [];
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final List<List<TextEditingController>> _rirControllers = [];
  final int _defaultSets = 3;
  Workout? _currentWorkout;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _dateController.text = DateFormat('yMMMd').add_jm().format(_selectedDate);
    if (widget.workout != null) {
      _currentWorkout = widget.workout;
      _loadWorkout(widget.workout!);
    } else if (widget.initialTemplate != null) {
      _loadTemplate(widget.initialTemplate!);
    } else {
      _initializeControllers();
    }
  }

  void _loadWorkout(Workout workout) {
    _workoutNameController.text = workout.name;
    _selectedDate = workout.date;
    _dateController.text = DateFormat('yMMMd').add_jm().format(_selectedDate);
    _selectedExercises.clear();
    _selectedExercises.addAll(workout.exercises.map((exercise) => exercise.name));
    _initializeControllers();
  }

  void _loadTemplate(Template template) {
    setState(() {
      _workoutNameController.text = template.name;
      _selectedExercises.clear();
      _selectedExercises.addAll(template.exercises);
      _initializeControllers();
    });
  }

  void _initializeControllers() {
    _repsControllers.clear();
    _weightControllers.clear();
    _rirControllers.clear();

    for (int i = 0; i < _selectedExercises.length; i++) {
      _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (pickedDate != null && pickedDate != _selectedDate) {
      setState(() {
        _selectedDate = pickedDate;
        _dateController.text = DateFormat('yMMMd').add_jm().format(_selectedDate);
      });
    }
  }

  void _navigateToExerciseSelection() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseSelectionScreen(
          selectedExercises: _selectedExercises,
        ),
      ),
    ).then((selectedExercises) {
      if (selectedExercises != null && selectedExercises is List<String>) {
        setState(() {
          _selectedExercises.clear();
          _selectedExercises.addAll(selectedExercises);
          _initializeControllers();
        });
      }
    });
  }

  void _navigateToTemplateSelection() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const TemplatesScreen(fromWorkoutPage: true),
      ),
    ).then((selectedTemplate) {
      if (selectedTemplate != null && selectedTemplate is Template) {
        _loadTemplate(selectedTemplate);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () {},
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _workoutNameController,
              decoration: const InputDecoration(
                labelText: 'Workout Name',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _dateController,
              readOnly: true,
              decoration: InputDecoration(
                labelText: 'Date',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_drop_down),
                  onPressed: () => _selectDate(context),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (_selectedExercises.isEmpty) ...[
              ListTile(
                title: const Text('Add Exercise'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: _navigateToExerciseSelection,
              ),
              ListTile(
                title: const Text('Load from Template'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: _navigateToTemplateSelection,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
