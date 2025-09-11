import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'user_context.dart';
import 'periodization_model_utils.dart';


enum TrendRange { d14, m30, m90, m180, y365 }


class BodyWeightTracker extends StatefulWidget {
  final Function(String)? onWeightSaved;


  const BodyWeightTracker({this.onWeightSaved, super.key});

  @override
  State<BodyWeightTracker> createState() => _BodyWeightTrackerState();
}

class _BodyWeightTrackerState extends State<BodyWeightTracker> {
  final TextEditingController _weightController = TextEditingController();
  // ➕ PM entry UI state
  final TextEditingController _pmWeightController = TextEditingController();
  DateTime _pmSelectedDate = DateTime.now();
  bool _showPmEntry = false;

  final List<Map<String, dynamic>> _weights = [];
  bool show3DayAverage = true;
  DateTime _selectedDate = DateTime.now();
  String _fmtDate(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  TrendRange _trend = TrendRange.d14;
  List<Map<String, dynamic>> _series14 = [];
  List<Map<String, dynamic>> _series30 = [];
  List<Map<String, dynamic>> _series90 = [];
  List<Map<String, dynamic>> _series180 = [];
  List<Map<String, dynamic>> _series365 = [];
  // ➕ AM/PM split series for each range
  List<Map<String, dynamic>> _series14Am = [];
  List<Map<String, dynamic>> _series14Pm = [];
  List<Map<String, dynamic>> _series30Am = [];
  List<Map<String, dynamic>> _series30Pm = [];
  List<Map<String, dynamic>> _series90Am = [];
  List<Map<String, dynamic>> _series90Pm = [];
  List<Map<String, dynamic>> _series180Am = [];
  List<Map<String, dynamic>> _series180Pm = [];
  List<Map<String, dynamic>> _series365Am = [];
  List<Map<String, dynamic>> _series365Pm = [];


// Per-range “did we trim outliers?” flag (for the small note under the chart)
  final Map<TrendRange, bool> _trimmed = {
    TrendRange.d14: false,
    TrendRange.m30: false,
    TrendRange.m90: false,
    TrendRange.m180: false,
    TrendRange.y365: false,
  };



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

  Future<void> _saveWeightWithTod({
    required double weight,
    required String unit,
    required String tod, // "am" | "pm"
    required DateTime selectedDate,
  }) async {
    // Capture the *current* time-of-day to preserve exact time the user logs,
    // but attach it to the *selected date* to avoid TZ/midnight issues.
    final now = DateTime.now();
    final ts = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      now.hour,
      now.minute,
      now.second,
      now.millisecond,
      now.microsecond,
    );

    final weightData = {
      'weight': weight,
      'unit': unit,
      'timestamp': Timestamp.fromDate(ts),
      'tod': tod, // explicit AM/PM for clarity
    };

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('weights')
          .add(weightData);

      if (tod == 'am') {
        _weightController.clear();
      } else {
        _pmWeightController.clear();
      }
      FocusScope.of(context).unfocus();
      if (widget.onWeightSaved != null) {
        widget.onWeightSaved!('${weight.toString()} $unit');
      }
      await _fetchWeights();
    } catch (e) {
      debugPrint('❌ _saveWeightWithTod failed: $e');
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
    // Existing unified series (keep as-is if you want)
    _series14  = _buildSeries(days: 14);
    _series30  = _buildSeries(days: 30);
    _series90  = _buildSeries(days: 90);
    _series180 = _buildSeries(days: 180);
    _series365 = _buildSeries(days: 365);

    // ➕ AM/PM split series
    _series14Am   = _buildSeriesByTod(days: 14,  tod: 'am');
    _series14Pm   = _buildSeriesByTod(days: 14,  tod: 'pm');
    _series30Am   = _buildSeriesByTod(days: 30,  tod: 'am');
    _series30Pm   = _buildSeriesByTod(days: 30,  tod: 'pm');
    _series90Am   = _buildSeriesByTod(days: 90,  tod: 'am');
    _series90Pm   = _buildSeriesByTod(days: 90,  tod: 'pm');
    _series180Am  = _buildSeriesByTod(days: 180, tod: 'am');
    _series180Pm  = _buildSeriesByTod(days: 180, tod: 'pm');
    _series365Am  = _buildSeriesByTod(days: 365, tod: 'am');
    _series365Pm  = _buildSeriesByTod(days: 365, tod: 'pm');
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
  List<Map<String, dynamic>> _buildSeriesByTod({
    required int days,
    required String tod, // "am" or "pm"
  }) {
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: days - 1));

    // Newest-first in _weights; collapse to 1 per day for the requested TOD bucket
    final Map<String, Map<String, dynamic>> byDay = {};
    for (final w in _weights) {
      final DateTime d = w['date'] as DateTime;
      if (d.isBefore(cutoff)) continue;

      // Determine AM/PM for this record
      final String recTod = () {
        final storedTod = (w['tod'] as String?)?.toLowerCase().trim();
        if (storedTod == 'am' || storedTod == 'pm') return storedTod!;
        // Back-compat: infer from hour if no 'tod' present
        final hour = d.hour; // from timestamp
        return (hour < 12) ? 'am' : 'pm';
      }();

      if (recTod != tod) continue;

      final key = "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
      byDay.putIfAbsent(key, () => {
        'date': DateTime(d.year, d.month, d.day),
        'weight': (w['weight'] as num).toDouble(),
      });
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
                    _saveWeightWithTod(
                      weight: weight,
                      unit: 'kg',
                      tod: 'am',
                      selectedDate: _selectedDate,
                    );
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
            // ➕ PM weigh-in (collapsed by default)
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                setState(() {
                  _showPmEntry = !_showPmEntry;
                  if (_showPmEntry) {
                    // Default PM date to match the currently selected AM date
                    _pmSelectedDate = _selectedDate;
                  }
                });
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_showPmEntry ? Icons.expand_less : Icons.expand_more, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    _showPmEntry ? 'Hide PM weigh-in' : 'Add PM weigh-in',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: !_showPmEntry
                  ? const SizedBox.shrink()
                  : Padding(
                key: const ValueKey('pm_row'),
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  children: [
                    // PM Weight field
                    Flexible(
                      flex: 3,
                      child: SizedBox(
                        height: 48,
                        child: TextField(
                          controller: _pmWeightController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'PM Weight (kg)',
                            border: OutlineInputBorder(),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white70),
                            ),
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // PM Date picker (tap to change)
                    Flexible(
                      flex: 3,
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _pmSelectedDate,
                            firstDate: DateTime(2010),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setState(() => _pmSelectedDate = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            border: OutlineInputBorder(
                              borderSide: BorderSide(color: Theme.of(context).colorScheme.primary),
                            ),
                            enabledBorder: const OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white70),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.calendar_today,
                                  size: 18, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 4),
                              Text(
                                _fmtDate(_pmSelectedDate),
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

                    // PM Save
                    ElevatedButton.icon(
                      onPressed: () {
                        final weight = double.tryParse(_pmWeightController.text) ?? 0.0;
                        _saveWeightWithTod(
                          weight: weight,
                          unit: 'kg',
                          tod: 'pm',
                          selectedDate: _pmSelectedDate,
                        );
                      },
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        minimumSize: const Size(0, 0),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 6),

            // ---- Trend Chart (14-day <-> 1-month toggle) ----
            Builder(
              builder: (_) {
                // Choose AM/PM series for the active range
                List<Map<String, dynamic>> am, pm;
                switch (_trend) {
                  case TrendRange.d14:
                    am = _series14Am; pm = _series14Pm; break;
                  case TrendRange.m30:
                    am = _series30Am; pm = _series30Pm; break;
                  case TrendRange.m90:
                    am = _series90Am; pm = _series90Pm; break;
                  case TrendRange.m180:
                    am = _series180Am; pm = _series180Pm; break;
                  case TrendRange.y365:
                    am = _series365Am; pm = _series365Pm; break;
                }

                // Use whichever series has more points for X-axis labels
                final seriesForLabels = (am.length >= pm.length) ? am : pm;

                if ((am.length + pm.length) < 2) {
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
                          _trend = () {
                            switch (_trend) {
                              case TrendRange.d14:  return TrendRange.m30;
                              case TrendRange.m30:  return TrendRange.m90;
                              case TrendRange.m90:  return TrendRange.m180;
                              case TrendRange.m180: return TrendRange.y365;
                              case TrendRange.y365: return TrendRange.d14;
                            }
                          }();
                        });
                      },

                      child: Text(
                            () {
                          switch (_trend) {
                            case TrendRange.d14:  return '14-Day Trend';
                            case TrendRange.m30:  return '1-Month Trend';
                            case TrendRange.m90:  return '3-Month Trend';
                            case TrendRange.m180: return '6-Month Trend';
                            case TrendRange.y365: return '1-Year Trend';
                          }
                        }(),

                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold, // optional to show it's tappable
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                    const SizedBox(height: 10),
                    // Minimal legend
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(width: 12, height: 12, color: Colors.blueAccent),
                        const SizedBox(width: 6),
                        const Text('AM', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 16),
                        Container(width: 12, height: 12, color: Colors.tealAccent),
                        const SizedBox(width: 6),
                        const Text('PM', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 6),


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
                                  if (i < 0 || i >= seriesForLabels.length) return const SizedBox.shrink();

                                  int showEvery;
                                  switch (_trend) {
                                    case TrendRange.d14:  showEvery = 1;  break;
                                    case TrendRange.m30:  showEvery = 2;  break;
                                    case TrendRange.m90:  showEvery = 7;  break;
                                    case TrendRange.m180: showEvery = 14; break;
                                    case TrendRange.y365: showEvery = 30; break;
                                  }
                                  if (i % showEvery != 0 && i != seriesForLabels.length - 1) {
                                    return const SizedBox.shrink();
                                  }


                                  final date = seriesForLabels[i]['date'] as DateTime;
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
                                  final all = [...am, ...pm];
                                  if (all.isEmpty) return const SizedBox.shrink();

                                  final maxY = all.map((e) => e['weight'] as double).reduce((a, b) => a > b ? a : b) + 1;
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
                                  final all = [...am, ...pm];
                                  if (all.isEmpty) return const SizedBox.shrink();

                                  final maxY = all.map((e) => e['weight'] as double).reduce((a, b) => a > b ? a : b) + 1;
                                  if (value == maxY) return const SizedBox.shrink(); // ❌ hide top label
                                  return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 12));
                                },
                              ),
                            ),

                          ),

                          borderData: FlBorderData(show: true),
                          minX: 0,
                          maxX: (seriesForLabels.length - 1).toDouble(),
                          minY: (() {
                            final all = [...am, ...pm];
                            if (all.isEmpty) return 0.0;
                            final minVal = all.map((e) => (e['weight'] as double)).reduce((a, b) => a < b ? a : b);
                            return minVal - 1;
                          })(),
                          maxY: (() {
                            final all = [...am, ...pm];
                            if (all.isEmpty) return 0.0;
                            final maxVal = all.map((e) => (e['weight'] as double)).reduce((a, b) => a > b ? a : b);
                            return maxVal + 1;
                          })(),

                          lineBarsData: [
                            // AM line
                            LineChartBarData(
                              isCurved: true,
                              spots: List.generate(
                                am.length,
                                    (i) => FlSpot(i.toDouble(), (am[i]['weight'] as double)),
                              ),
                              barWidth: 2,
                              color: Colors.blueAccent,
                              dotData: FlDotData(show: true),
                            ),

                            // PM line
                            LineChartBarData(
                              isCurved: true,
                              spots: List.generate(
                                pm.length,
                                    (i) => FlSpot(i.toDouble(), (pm[i]['weight'] as double)),
                              ),
                              barWidth: 2,
                              color: Colors.tealAccent,
                              dotData: FlDotData(show: true),
                            ),
                          ],
                          lineTouchData: LineTouchData(
                            touchTooltipData: LineTouchTooltipData(
                              tooltipBgColor: Colors.grey.shade900,
                              getTooltipItems: (touchedSpots) {
                                return touchedSpots.map((spot) {
                                  final gi = spot.barIndex;   // 0 = AM, 1 = PM
                                  final xi = spot.x.toInt();

                                  final list = (gi == 0) ? am : pm;
                                  if (xi < 0 || xi >= list.length) return null;

                                  final date = list[xi]['date'] as DateTime;
                                  final y = list[xi]['weight'] as double;

                                  final todLabel = (gi == 0) ? 'AM' : 'PM';
                                  final dateStr = DateFormat('d MMM yyyy').format(date);

                                  return LineTooltipItem(
                                    '$dateStr\n$todLabel • ${y.toStringAsFixed(1)} kg',
                                    const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                                  );
                                }).whereType<LineTooltipItem>().toList();
                              },
                            ),
                          ),

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

            if (_trimmed[_trend] == true) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '⚠️ extremes trimmed for clarity',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.amber[300]),
                ),
              ),
            ],

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
