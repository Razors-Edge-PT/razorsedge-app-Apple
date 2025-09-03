import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'user_context.dart';
import 'periodization_model_utils.dart';


enum TrendRange { d14, m30 }

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
  DateTime _selectedDate = DateTime.now();
  String _fmtDate(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  TrendRange _trend = TrendRange.d14;
  List<Map<String, dynamic>> _series14 = [];
  List<Map<String, dynamic>> _series30 = [];


  // Use selected user (actingAsUid), not the logged-in user
  String get userId => UserContext.of(context, listen: false).currentUid;


  @override
  void initState() {
    super.initState();
    _fetchWeights();
  }

  Future<void> _fetchWeights() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // ✅ selected athlete
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .get();

      _weights
        ..clear()
        ..addAll(snapshot.docs.map((doc) {
          final data = doc.data();
          final ts = data['timestamp'];
          return {
            'id': doc.id,
            'weight': data['weight'],
            'unit': data['unit'],
            'date': (ts is Timestamp) ? ts.toDate() : DateTime.now(), // handle serverTimestamp()
          };
        }));

      // ➕ NEW: publish full history to PMU so asOf lookups work everywhere
      PeriodizationModelUtils.setBodyweightHistory(
        uid: userId,
        entries: _weights.map((w) => {
          'date': w['date'] as DateTime,
          'weight': (w['weight'] as num).toDouble(),
          'unit': (w['unit'] ?? 'kg').toString(),
        }).toList(),
      );


      _recomputeSeries();

      if (mounted) setState(() {});


    } catch (e) {
      debugPrint('❌ _fetchWeights failed: $e');
    }
  }


  Future<void> _saveWeight(double weight, String unit) async {
    final weightData = {
      'weight': weight,
      'unit': unit,
      // store the *chosen* date at local noon to avoid TZ midnight issues
      'timestamp': Timestamp.fromDate(
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, 12),
      ),
    };

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // uses actingAsUid
          .collection('weights')
          .add(weightData);

      _weightController.clear();
      FocusScope.of(context).unfocus();
      if (widget.onWeightSaved != null) {
        widget.onWeightSaved!('${weight.toString()} $unit');
      }
      await _fetchWeights();
    } catch (e) {
      debugPrint('❌ _saveWeight failed: $e');
    }
  }



  Future<void> _deleteAllWeights() async {
    try {
      final colRef = FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // ✅ selected athlete
          .collection('weights');

      final snapshot = await colRef.get();
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (mounted) {
        setState(() {
          _weights.clear();
        });
      }
    } catch (e) {
      debugPrint('❌ _deleteAllWeights failed: $e');
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  void _recomputeSeries() {
    _series14 = _buildSeries(days: 14);
    _series30 = _buildSeries(days: 30);
  }

  List<Map<String, dynamic>> _buildSeries({required int days}) {
    // Build one point per day (latest entry that day), chronological
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: days - 1));

    // Group by yyyy-mm-dd so multiple weigh-ins per day collapse to latest shown first
    final Map<String, Map<String, dynamic>> byDay = {};
    for (final w in _weights) {
      final DateTime d = w['date'] as DateTime;
      if (d.isBefore(cutoff)) continue;
      final key = "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
      // keep the first encountered (assuming _weights is newest-first), which is the latest that day
      byDay.putIfAbsent(key, () => {'date': DateTime(d.year, d.month, d.day), 'weight': (w['weight'] as num).toDouble()});
    }

    final list = byDay.values.toList()
      ..sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));

    return list;
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                // Weight field (slightly narrower)
                Flexible(
                  flex: 3,
                  child: SizedBox(
                    height: 48, // ✅ matches the date picker height
                    child: TextField(
                      controller: _weightController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Weight (kg)',
                        border: OutlineInputBorder(),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white70, // ✅ default state
                          ),
                        ),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Date picker (tap to change)
                Flexible(
                  flex: 3,
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary, // ✅ match old color
                          ),
                        ),
                        enabledBorder: const OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.white70, // ✅ default state
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: 18, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            _fmtDate(_selectedDate),
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Save (reduced padding & width)
                ElevatedButton.icon(
                  onPressed: () {
                    final weight = double.tryParse(_weightController.text) ?? 0.0;
                    _saveWeight(weight, 'kg');
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    minimumSize: const Size(0, 0), // let it shrink
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // ---- Trend Chart (14-day <-> 1-month toggle) ----
            Builder(
              builder: (_) {
                final series = _trend == TrendRange.d14 ? _series14 : _series30;
                if (series.length < 2) {
                  return const SizedBox.shrink();
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 20),

                    // 🔹 Title doubles as toggle
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _trend = _trend == TrendRange.d14 ? TrendRange.m30 : TrendRange.d14;
                        });
                      },
                      child: Text(
                        _trend == TrendRange.d14 ? '14-Day Trend' : '1-Month Trend',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold, // optional to show it's tappable
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

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
                                  final i = value.toInt();
                                  if (i < 0 || i >= series.length) return const SizedBox.shrink();

                                  // 🔹 Show more labels: every 1 for 14-day, every 2 for 30-day
                                  final showEvery = _trend == TrendRange.d14 ? 1 : 2;
                                  if (i % showEvery != 0 && i != series.length - 1) {
                                    return const SizedBox.shrink();
                                  }

                                  final date = series[i]['date'] as DateTime;
                                  final label = DateFormat('d MMM').format(date);

                                  return Transform.rotate(
                                    angle: -0.5,
                                    alignment: Alignment.topRight,
                                    child: Text(
                                      label,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  );
                                },
                              ),
                            ),
                            topTitles: AxisTitles(               // 🔹 disable top X axis titles
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 1,
                                reservedSize: 28,
                                getTitlesWidget: (value, meta) {
                                  final maxY = (series.map((e) => e['weight'] as double).reduce((a, b) => a > b ? a : b)) + 1;
                                  if (value == maxY) return const SizedBox.shrink(); // ❌ hide top label
                                  return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 12));
                                },
                              ),
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 1,
                                reservedSize: 28,
                                getTitlesWidget: (value, meta) {
                                  final maxY = (series.map((e) => e['weight'] as double).reduce((a, b) => a > b ? a : b)) + 1;
                                  if (value == maxY) return const SizedBox.shrink(); // ❌ hide top label
                                  return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 12));
                                },
                              ),
                            ),
                          ),

                          borderData: FlBorderData(show: true),
                          minX: 0,
                          maxX: (series.length - 1).toDouble(),
                          minY: (series.map((e) => e['weight'] as double).reduce((a, b) => a < b ? a : b)) - 1,
                          maxY: (series.map((e) => e['weight'] as double).reduce((a, b) => a > b ? a : b)) + 1,
                          lineBarsData: [
                            LineChartBarData(
                              isCurved: true,
                              spots: List.generate(
                                series.length,
                                    (i) => FlSpot(i.toDouble(), (series[i]['weight'] as double)),
                              ),
                              barWidth: 2,
                              color: Colors.blueAccent,
                              dotData: FlDotData(show: true),
                            ),
                          ],
                        ),

                      ),
                    ),
                  ],
                );
              },
            ),



            const SizedBox(height: 20),

            if (mostRecent != null)
              Row(
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
                color: Colors.blueGrey.withOpacity(0.1),
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: const Icon(Icons.compare, color: Colors.cyan),
                  title: const Text('Weekly Comparison'),
                  subtitle: Text('This week: ${averageLast7.toStringAsFixed(1)} kg\nLast week: ${averagePrev7.toStringAsFixed(1)} kg'),
                ),
              ),

            const SizedBox(height: 10),

            // 🔽 Weigh-ins list nested in main scroll (no Expanded here)
            if (_weights.isEmpty)
              const Center(child: Text('No weights logged yet.'))
            else
              ListView.builder(
                itemCount: _weights.length,
                shrinkWrap: true,                               // ✅ allow nesting
                physics: const NeverScrollableScrollPhysics(),  // ✅ parent scroll handles it
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

            const SizedBox(height: 24),
          ],
        ),
      ),


      //The above bracket is the end point for body:padding
    );
  }
}
