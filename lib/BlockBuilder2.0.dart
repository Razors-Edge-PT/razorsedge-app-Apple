import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class BlockBuilder2 extends StatefulWidget {
  const BlockBuilder2({super.key});

  @override
  State<BlockBuilder2> createState() => _BlockBuilder2State();
}

class _BlockBuilder2State extends State<BlockBuilder2> {
  final int initialWeeks = 12;
  final int exercisesPerDay = 11;

  late DateTime selectedWeekMonday;
  late DateTime blockStartDate;

  List<int> weekIndices = [];

  @override
  void initState() {
    super.initState();
    selectedWeekMonday = _getMostRecentMonday();
    blockStartDate = _getMostRecentMonday();

    weekIndices = List.generate(initialWeeks, (index) => index);
  }

  DateTime _getMostRecentMonday() {
    DateTime now = DateTime.now();
    int diff = now.weekday - DateTime.monday;
    return now.subtract(Duration(days: diff < 0 ? 7 + diff : diff));
  }

  void _addWeek() {
    setState(() {
      weekIndices.add(weekIndices.length);
    });
  }

  String _getDayLabel(int weekIndex, int dayOffset) {
    DateTime date = blockStartDate.add(Duration(days: weekIndex * 7 + dayOffset));
    return DateFormat('EEE d MMM yyyy').format(date);
  }



  Widget _inputBox({required String hint, int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Container(
        margin: const EdgeInsets.all(2),
        height: 36,
        child: TextField(
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
          ),
        ),
      ),
    );
  }

  Widget _textBox(String text, {int flex = 1, bool readOnly = false}) {
    return Expanded(
      flex: flex,
      child: Container(
        margin: const EdgeInsets.all(2),
        height: 36,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
        ),
        alignment: Alignment.center,
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildExerciseRow(int weekIndex, int dayIndex, int rowIndex) {
    return Row(
      children: const [
        Expanded(flex: 3, child: Text("Exercise Placeholder")),
        Expanded(flex: 2, child: Text("Weight")),
        Expanded(flex: 1, child: Text("Reps")),
        Expanded(flex: 1, child: Text("RIR")),
        Expanded(flex: 2, child: Text("E1RM")),
      ],
    );
  }



  Widget _buildDay(int weekIndex, int dayIndex) {
    final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
    final dayLabel = DateFormat('E d MMM y').format(date); // e.g., "Mon 25 Mar 2025"

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      color: Colors.blueGrey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🟡 Day Header Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Date label
                Text(
                  dayLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // Buttons: Template, Notes, Workout
                Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {},
                        child: const Text("Template", style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {},
                        child: const Text("Notes", style: TextStyle(fontSize: 11)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 0),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {},
                        child: const Text("Workout", style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ],

                ),

              ],
            ),
            const SizedBox(height: 6),

            // 🟡 Table Header
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              color: Colors.blueGrey.shade200,
              child: Row(
                children: const [
                  Expanded(flex: 3, child: Text("Exercise", textAlign: TextAlign.center)),
                  Expanded(flex: 2, child: Text("Weight", textAlign: TextAlign.center)),
                  Expanded(flex: 1, child: Text("Reps", textAlign: TextAlign.center)),
                  Expanded(flex: 1, child: Text("RIR", textAlign: TextAlign.center)),
                  Expanded(flex: 2, child: Text("E1RM", textAlign: TextAlign.center)),
                ],
              ),
            ),

            // 🟡 Exercise Rows
            Column(
              children: List.generate(
                exercisesPerDay,
                    (row) => _buildExerciseRow(weekIndex, dayIndex, row),
              ),
            ),
          ],
        ),
      ),
    );
  }



  Widget _buildWeek(int weekIndex) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(7, (dayIndex) => _buildDay(weekIndex, dayIndex)),
      ),
    );
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Block Builder 2.0")),
      body: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: weekIndices.map((i) => _buildWeek(i)).toList(),
          ),
        ),
      ),
    );
  }
}
