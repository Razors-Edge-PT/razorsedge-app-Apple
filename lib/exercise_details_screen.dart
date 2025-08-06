import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';

class ExerciseDetailsScreen extends StatelessWidget {
  final String exerciseName;
  final List<Workout> recentWorkouts;

  const ExerciseDetailsScreen({
    super.key,
    required this.exerciseName,
    required this.recentWorkouts,
  });

  double calculateE1RM(double weight, double reps, double rir) {
    final totalReps = reps + rir;
    return (totalReps <= 6)
        ? (weight * (36 / (37 - totalReps)))
        : (weight * (1 + (0.0333 * totalReps)));
  }

  @override
  Widget build(BuildContext context) {
    final List<Workout> sortedWorkouts = [...recentWorkouts]..sort((a, b) => a.date.compareTo(b.date));

    final List<FlSpot> e1rmSpots = [];
    final List<String> dateLabels = [];

    for (int i = 0; i < sortedWorkouts.length; i++) {
      final workout = sortedWorkouts[i];
      final exercise = workout.exercises.firstWhere(
            (ex) => ex.name == exerciseName,
        orElse: () => Exercise(name: '', sets: []),
      );

      if (exercise.sets.isNotEmpty) {
        final topSet = exercise.sets.reduce((a, b) {
          final aE1 = calculateE1RM(a.weight ?? 0.0, (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
          final bE1 = calculateE1RM(b.weight ?? 0.0, (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
          return aE1 > bE1 ? a : b;
        });

        final e1rm = calculateE1RM(topSet.weight ?? 0.0, (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0);
        e1rmSpots.add(FlSpot(i.toDouble(), e1rm));
        dateLabels.add(DateFormat('dd MMM').format(workout.date));
      }
    }
    final double maxE1RM = e1rmSpots.map((spot) => spot.y).fold<double>(0, (prev, y) => y > prev ? y : prev);
    final double adjustedMaxY = (maxE1RM * 1.018).clamp(100.0, double.infinity);


    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('E1RM Trend: $exerciseName'),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          // 🔥 Graph
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: AspectRatio(
              aspectRatio: 1.7,
              child: LineChart(
                LineChartData(
                  minX: -0.3, // ✅ Add some padding to the left
                  maxX: e1rmSpots.length.toDouble() - 0.7, // ✅ Add right padding so final label/point isn't clipped
                  maxY: adjustedMaxY, // ✅ Use your computed value here

                  gridData: FlGridData(
                    show: true,
                    getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        getTitlesWidget: (value, _) => Text(
                          '${value.toInt()}',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 2,
                        getTitlesWidget: (value, _) {
                          final index = value.toInt();
                          return SideTitleWidget(
                            axisSide: AxisSide.bottom,
                            child: Transform.rotate(
                              angle: -0.5, // ~ -28.6 degrees
                              child: Text(
                                index >= 0 && index < dateLabels.length ? dateLabels[index] : '',
                                style: const TextStyle(color: Colors.white, fontSize: 10),
                              ),
                            ),
                          );
                        },

                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: e1rmSpots,
                      isCurved: true,
                      color: Colors.cyanAccent,
                      dotData: FlDotData(show: true),
                      belowBarData: BarAreaData(show: true, color: Colors.cyanAccent.withOpacity(0.1)),
                    )
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Colors.grey[900]!,

                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final e1rm = spot.y.toStringAsFixed(1);
                          final date = dateLabels[spot.x.toInt()];
                          return LineTooltipItem('E1RM: $e1rm kg\n$date', const TextStyle(color: Colors.white));
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),

          const Divider(color: Colors.white24),

          // 📋 Top Sets List
          const Padding(
            padding: EdgeInsets.only(left: 16, top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Top Sets:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: sortedWorkouts.length,
              itemBuilder: (context, index) {
                final workout = sortedWorkouts[index];
                final exercise = workout.exercises.firstWhere(
                      (ex) => ex.name == exerciseName,
                  orElse: () => Exercise(name: '', sets: []),
                );

                if (exercise.sets.isEmpty) return const SizedBox.shrink();

                final topSet = exercise.sets.reduce((a, b) {
                  final aE1 = calculateE1RM(a.weight ?? 0.0, (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
                  final bE1 = calculateE1RM(b.weight ?? 0.0, (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
                  return aE1 > bE1 ? a : b;
                });

                final e1rm = calculateE1RM(topSet.weight ?? 0.0, (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0);

                return ListTile(
                  title: Text(
                    DateFormat('dd-MM-yyyy').format(workout.date),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  subtitle: Text(
                    '${topSet.weight} kg × ${topSet.reps}, RIR ${topSet.rir} → E1RM: ${e1rm.toStringAsFixed(1)} kg',
                    style: const TextStyle(color: Colors.cyanAccent),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
