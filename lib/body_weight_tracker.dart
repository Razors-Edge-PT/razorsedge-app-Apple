import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

class BodyWeightTracker extends StatefulWidget {
  final Function(String)? onWeightSaved;

  const BodyWeightTracker({this.onWeightSaved, super.key});

  @override
  State<BodyWeightTracker> createState() => _BodyWeightTrackerState();
}

class _BodyWeightTrackerState extends State<BodyWeightTracker> {
  final TextEditingController _weightController = TextEditingController();
  final List<Map<String, dynamic>> _weights = [];
  bool show3DayAverage = true;

  @override
  void initState() {
    super.initState();
    _fetchWeights();
  }

  Future<void> _fetchWeights() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userId = user.uid;
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .get();

      _weights.clear();
      for (var doc in snapshot.docs) {
        final data = doc.data();
        _weights.add({
          'id': doc.id,
          'weight': data['weight'],
          'unit': data['unit'],
          'date': (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
        });
      }
      setState(() {});
    }
  }

  void _saveWeight(double weight, String unit) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userId = user.uid;
      final weightData = {
        'weight': weight,
        'unit': unit,
        'timestamp': FieldValue.serverTimestamp(),
      };

      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('weights')
            .add(weightData);

        _weightController.clear();
        FocusScope.of(context).unfocus();

        if (widget.onWeightSaved != null) {
          widget.onWeightSaved!('${weight.toString()} $unit');
        }

        await _fetchWeights();
      } catch (error) {
        print(error);
      }
    }
  }

  Future<void> _deleteAllWeights() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userId = user.uid;
      final batch = FirebaseFirestore.instance.batch();
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('weights')
          .get();

      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      setState(() {
        _weights.clear();
      });
    }
  }

  Widget _buildWeightCard(Map<String, dynamic> item) {
    final date = item['date'] as DateTime;
    final formattedDate = DateFormat('dd MMM').format(date);
    return GestureDetector(
      onTap: () => _editWeightEntry(item),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formattedDate, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              Text('${item['weight']} ${item['unit']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  void _editWeightEntry(Map<String, dynamic> weightEntry) async {
    final weightController = TextEditingController(text: weightEntry['weight'].toString());
    DateTime selectedDate = weightEntry['date'];

    double? diffFromPrevious;
    double? diffFrom3DayAvg;
    double? diffFrom7DayAvg;

    final index = _weights.indexWhere((w) => w['id'] == weightEntry['id']);
    if (index + 1 < _weights.length) {
      final prevWeight = _weights[index + 1]['weight'] as double;
      diffFromPrevious = weightEntry['weight'] - prevWeight;
    }

    final recent3 = _weights.take(3).map((w) => w['weight'] as double);
    if (recent3.length == 3) {
      final avg3 = recent3.reduce((a, b) => a + b) / 3;
      diffFrom3DayAvg = weightEntry['weight'] - avg3;
    }

    final now = DateTime.now();
    final last7Days = _weights.where((entry) {
      final date = entry['date'] as DateTime;
      return date.isBefore(now.add(const Duration(days: 1))) &&
          date.isAfter(now.subtract(const Duration(days: 7)));
    }).toList();
    if (last7Days.isNotEmpty) {
      final avg7 = last7Days.map((w) => w['weight'] as double).reduce((a, b) => a + b) / last7Days.length;
      diffFrom7DayAvg = weightEntry['weight'] - avg7;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 100),
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Date:'),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setState(() {
                          selectedDate = picked;
                        });
                      }
                    },
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(DateFormat('dd-MM-yyyy').format(selectedDate)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: weightController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Weight (kg)'),
                ),
                const SizedBox(height: 16),
                const Text('Calculations:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                _diffText('Δ from previous', diffFromPrevious),
                _diffText('Δ from 3-day avg', diffFrom3DayAvg),
                _diffText('Δ from 7-day avg', diffFrom7DayAvg),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        final confirmDelete = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Entry'),
                            content: const Text('Are you sure you want to delete this weight entry?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (confirmDelete == true) {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            await FirebaseFirestore.instance
                                .collection('users')
                                .doc(user.uid)
                                .collection('weights')
                                .doc(weightEntry['id'])
                                .delete();

                            Navigator.pop(context);
                            _fetchWeights();
                          }
                        }
                      },
                      child: const Text('Delete'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, {
                        'weight': double.tryParse(weightController.text),
                        'date': selectedDate,
                      }),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (result != null && result['weight'] != null) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('weights')
            .doc(weightEntry['id'])
            .update({
              'weight': result['weight'],
              'timestamp': Timestamp.fromDate(result['date']),
            });

        _fetchWeights();
      }
    }
  }

  Widget _diffText(String label, double? diff) {
    if (diff == null) return const SizedBox.shrink();
    final isPositive = diff >= 0;
    return Row(
      children: [
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
        Icon(
          isPositive ? Icons.arrow_upward : Icons.arrow_downward,
          color: isPositive ? Colors.red : Colors.green,
          size: 16,
        ),
        const SizedBox(width: 4),
        Text(
          '${diff.toStringAsFixed(1)} kg',
          style: TextStyle(color: isPositive ? Colors.red : Colors.green),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mostRecent = _weights.isNotEmpty ? _weights.first : null;

    double? average3Day;
    if (_weights.length >= 3) {
      final recent3 = _weights.take(3).map((w) => w['weight'] as double);
      average3Day = recent3.reduce((a, b) => a + b) / 3;
    }

    final now = DateTime.now();
    final last7Days = _weights.where((entry) {
      final date = entry['date'] as DateTime;
      return date.isBefore(now.add(const Duration(days: 1))) &&
          date.isAfter(now.subtract(const Duration(days: 7)));
    }).toList().reversed.toList();

    final lastWeek = _weights.where((entry) {
      final date = entry['date'] as DateTime;
      return date.isBefore(now.subtract(const Duration(days: 7))) &&
          date.isAfter(now.subtract(const Duration(days: 14)));
    }).toList();

    double? averageLast7;
    if (last7Days.isNotEmpty) {
      averageLast7 = last7Days.map((w) => w['weight'] as double).reduce((a, b) => a + b) / last7Days.length;
    }

    double? averagePrev7;
    if (lastWeek.isNotEmpty) {
      averagePrev7 = lastWeek.map((w) => w['weight'] as double).reduce((a, b) => a + b) / lastWeek.length;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Body Weight Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete All Entries'),
                  content: const Text('Are you sure you want to delete all weight entries?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (confirm == true) {
                await _deleteAllWeights();
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _weightController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Weight (kg)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    double weight = double.tryParse(_weightController.text) ?? 0.0;
                    _saveWeight(weight, 'kg');
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ],
            ),
            if (last7Days.length >= 2) ...[
              const SizedBox(height: 20),
              const Text('7-Day Trend', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              SizedBox(
                height: 200,
                child: LineChart(
                  LineChartData(
                    gridData: FlGridData(show: false),
                    titlesData: FlTitlesData(
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 32,
                          interval: 1,
                          getTitlesWidget: (value, meta) {
                            final index = value.toInt();
                            if (index >= 0 && index < last7Days.length) {
                              final date = last7Days[index]['date'] as DateTime;
                              return Text(DateFormat('E').format(date), style: const TextStyle(fontSize: 10));
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 1,
                          reservedSize: 28,
                          getTitlesWidget: (value, meta) {
                            return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10));
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: true),
                    minX: 0,
                    maxX: (last7Days.length - 1).toDouble(),
                    lineBarsData: [
                      LineChartBarData(
                        isCurved: true,
                        spots: List.generate(
                          last7Days.length,
                              (i) => FlSpot(i.toDouble(), (last7Days[i]['weight'] as double)),
                        ),
                        barWidth: 3,
                        color: Colors.blueAccent,
                        dotData: FlDotData(show: true),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (mostRecent != null) Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Card(
                    color: Colors.blueAccent.withOpacity(0.1),
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: const Icon(Icons.monitor_weight, color: Colors.blue),
                      title: const Text('Latest Weight'),
                      subtitle: Text(
                        '${mostRecent['weight']} ${mostRecent['unit']} on ${DateFormat('dd-MM-yyyy').format(mostRecent['date'])}',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        show3DayAverage = !show3DayAverage;
                      });
                    },
                    child: Card(
                      color: Colors.greenAccent.withOpacity(0.1),
                      elevation: 3,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(12),
                        leading: const Icon(Icons.trending_up, color: Colors.green),
                        title: Text(show3DayAverage ? '3-Day Avg' : '7-Day Avg'),
                        subtitle: Text(
                          show3DayAverage
                              ? (average3Day != null ? '${average3Day.toStringAsFixed(1)} ${mostRecent['unit']}' : 'Not enough data')
                              : (averageLast7 != null ? '${averageLast7.toStringAsFixed(1)} ${mostRecent['unit']}' : 'Not enough data'),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (averageLast7 != null && averagePrev7 != null)
              Card(
                color: Colors.orangeAccent.withOpacity(0.1),
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: const Icon(Icons.compare, color: Colors.orange),
                  title: const Text('Weekly Comparison'),
                  subtitle: Text('This week: ${averageLast7.toStringAsFixed(1)} kg\nLast week: ${averagePrev7.toStringAsFixed(1)} kg'),
                ),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: _weights.isEmpty
                  ? const Center(child: Text('No weights logged yet.'))
                  : ListView.builder(
                itemCount: _weights.length,
                itemBuilder: (context, index) {
                  final item = _weights[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: const Icon(Icons.fitness_center),
                      title: Text('${item['weight']} ${item['unit']}'),
                      subtitle: Text(DateFormat('dd-MM-yyyy').format(item['date'])),
                      onTap: () => _editWeightEntry(item),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
