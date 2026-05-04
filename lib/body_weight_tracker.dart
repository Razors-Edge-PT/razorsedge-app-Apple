import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'user_context.dart';
import 'periodization_model_utils.dart';
import 'warmup_service.dart';
import 'dart:async' show unawaited;

import 'block_repository.dart';

enum TrendRange { d14, m30, m90, m180, y365 }
enum BodyWeightAverageSource { am, pm }

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}



class BodyWeightTracker extends StatefulWidget {
  final Function(String)? onWeightSaved;


  const BodyWeightTracker({this.onWeightSaved, super.key});

  @override
  State<BodyWeightTracker> createState() => _BodyWeightTrackerState();
}

class _BodyWeightTrackerState extends State<BodyWeightTracker> {
  final TextEditingController _weightController = TextEditingController();
  final List<Map<String, dynamic>> _weights = [];
  final TextEditingController _weightControllerPm = TextEditingController(); // 2nd weigh-in
  bool show3DayAverage = true;
  DateTime _selectedDate = DateTime.now();
  String _fmtDate(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  TrendRange _trend = TrendRange.y365;
  bool _showSecondWeighIn = false; // controls expansion + 2nd line visibility
  BodyWeightAverageSource _averageSource = BodyWeightAverageSource.am;
  List<Map<String, dynamic>> _series14 = [];
  List<Map<String, dynamic>> _series30 = [];
  List<Map<String, dynamic>> _series90 = [];
  List<Map<String, dynamic>> _series180 = [];
  List<Map<String, dynamic>> _series365 = [];
// ➕ AM/PM split series for each range
  List<Map<String, dynamic>> _series14Am = [], _series14Pm = [];
  List<Map<String, dynamic>> _series30Am = [], _series30Pm = [];
  List<Map<String, dynamic>> _series90Am = [], _series90Pm = [];
  List<Map<String, dynamic>> _series180Am = [], _series180Pm = [];
  List<Map<String, dynamic>> _series365Am = [], _series365Pm = [];



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
            'tod' : (data['tod'] as String?)?.toLowerCase().trim(), // 'am' | 'pm' | null
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


  Future<void> _saveWeight(double weight, String unit, {required String tod}) async {
    final weightData = {
      'weight': weight,
      'unit': unit,
      'tod': tod, // <-- AM or PM based on which field saved
      // store the chosen date at local noon to avoid TZ midnight issues
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
// ⛳ ANCHOR: WES_WEIGHT_HOOK_SAVE
      try {
        final uidSelected = userId; // acting-as user (selected athlete)
        // Use the date used for this save (you already stamp with _selectedDate at noon)
        final d = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
        unawaited(_warmWESForDateOnly(uid: uidSelected, date: d));

        debugPrint('🚀 [BW Hook:Save] Warm kicked for ${d.toIso8601String().substring(0,10)} (uid=$uidSelected)');
      } catch (e) {
        debugPrint('🟧 [BW Hook:Save] Failed to kick warm: $e');
      }


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

  // ⛳ ANCHOR: WES_WEIGHT_WARM_HELPERS
  Future<void> _warmWESForDateOnly({
    required String uid,
    required DateTime date,
  }) async {
    final dOnly = DateTime(date.year, date.month, date.day);
    try {
      debugPrint('🔥 [BW→Warm] Requesting WES warm for ${dOnly.toIso8601String().substring(0,10)} (uid=$uid)');

      // We intentionally pass no activeBlockId; WarmupService will resolve it internally.
      await WarmupService.instance.doWarmWES(
        uid,
        activeBlockId: null,      // 👈 let WarmupService figure it out
        selectedDate: dOnly,
        warmAthlete: true,        // BW affects athlete inputs
        warmExercises: false,     // exercises list does not change from a weight entry
      );

      debugPrint('✅ [BW→Warm] Warm complete for ${dOnly.toIso8601String().substring(0,10)}');
    } catch (e) {
      debugPrint('🟥 [BW→Warm] Warm failed: $e');
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

  // REPLACE the whole _recomputeSeries() body:
  void _recomputeSeries() {
    _series14  = _buildSeries(days: 14);
    _series30  = _buildSeries(days: 30);
    _series90  = _buildSeries(days: 90);
    _series180 = _buildSeries(days: 180);
    _series365 = _buildSeries(days: 365);

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
        // 🔙 Back-compat: no tod field → always AM
        return 'am';
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

  String _normalisedTod(Map<String, dynamic> w) {
    final v = (w['tod'] as String?)?.toLowerCase().trim();
    return (v == 'am' || v == 'pm') ? v! : 'am';
  }

  String get _averageSourceTod =>
      _averageSource == BodyWeightAverageSource.am ? 'am' : 'pm';

  String get _averageSourceLabel =>
      _averageSource == BodyWeightAverageSource.am ? 'AM' : 'PM';

  List<Map<String, dynamic>> _weightsForAverageSource() =>
      _weights.where((w) => _normalisedTod(w) == _averageSourceTod).toList();

  double? _averageRecentEntries(List<Map<String, dynamic>> entries, int count) {
    final take = entries.take(count).toList();
    if (take.isEmpty) return null;
    final sum = take.fold<double>(0, (s, w) => s + (w['weight'] as num).toDouble());
    return sum / take.length;
  }

  double? _averageWithinWindow(
      List<Map<String, dynamic>> entries, DateTime after, DateTime before) {
    final window = entries.where((w) {
      final d = w['date'] as DateTime;
      return d.isAfter(after) && d.isBefore(before);
    }).toList();
    if (window.isEmpty) return null;
    final sum = window.fold<double>(0, (s, w) => s + (w['weight'] as num).toDouble());
    return sum / window.length;
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
    final isNew = weightEntry['id'] == null;
    final tod = (weightEntry['tod'] as String?) ?? 'am';

    final weightController = TextEditingController(
      text: isNew ? '' : (weightEntry['weight']?.toString() ?? ''),
    );
    DateTime selectedDate = weightEntry['date'] as DateTime? ?? DateTime.now();

    double? diffFromPrevious;
    double? diffFrom3DayAvg;
    double? diffFrom7DayAvg;

    if (!isNew) {
      final index = _weights.indexWhere((w) => w['id'] == weightEntry['id']);
      if (index + 1 < _weights.length) {
        final prevWeight = _weights[index + 1]['weight'] as double;
        diffFromPrevious = (weightEntry['weight'] as double) - prevWeight;
      }

      final recent3 = _weights.take(3).map((w) => w['weight'] as double);
      if (recent3.length == 3) {
        final avg3 = recent3.reduce((a, b) => a + b) / 3;
        diffFrom3DayAvg = (weightEntry['weight'] as double) - avg3;
      }

      final now = DateTime.now();
      final last7Days = _weights.where((entry) {
        final date = entry['date'] as DateTime;
        return date.isBefore(now.add(const Duration(days: 1))) &&
            date.isAfter(now.subtract(const Duration(days: 7)));
      }).toList();
      if (last7Days.isNotEmpty) {
        final avg7 = last7Days.map((w) => w['weight'] as double).reduce((a, b) => a + b) / last7Days.length;
        diffFrom7DayAvg = (weightEntry['weight'] as double) - avg7;
      }
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text(
          '${isNew ? "Add" : "Edit"} Weigh-in (${tod.toUpperCase()})',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.of(context).viewInsets.bottom, // keep above keyboard
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
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
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                scrollPadding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + 80,
                ),
                decoration: const InputDecoration(labelText: 'Weight (kg)'),
              ),
              const SizedBox(height: 16),
              const Text('Calculations:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              _diffText('Δ from previous', diffFromPrevious),
              _diffText('Δ from 3-day avg', diffFrom3DayAvg),
              _diffText('Δ from 7-day avg', diffFrom7DayAvg),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (!isNew)
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

                    // ⛳ ANCHOR: WES_WEIGHT_HOOK_EDIT_DELETE
                    try {
                      final uidSelected = userId; // acting-as user (selected athlete)
                      // Best effort date: try entry date if present; else default to _selectedDate
                      final DateTime d = (weightEntry['date'] as DateTime?) ?? _selectedDate ?? DateTime.now();
                      final dOnly = DateTime(d.year, d.month, d.day);
                      unawaited(_warmWESForDateOnly(uid: uidSelected, date: dOnly)); // fire-and-forget

                      debugPrint('🚀 [BW Hook:EditDelete] Warm kicked for ${dOnly.toIso8601String().substring(0,10)} (uid=$uidSelected)');
                    } catch (e) {
                      debugPrint('🟧 [BW Hook:EditDelete] Failed to kick warm: $e');
                    }

                    Navigator.pop(context);
                    _fetchWeights();
                  }
                }
              },
              child: const Text('Delete'),
            ),
          ElevatedButton(
            onPressed: () {
              final val = double.tryParse(weightController.text);
              print('💾 [DIALOG SAVE] parsed=$val isNew=$isNew tod=$tod date=$selectedDate');
              if (val != null && val > 0) {
                Navigator.pop(context, {
                  'weight': val,
                  'date': selectedDate,
                  'tod': tod,
                });
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );


    if (result != null && result['weight'] != null) {
      print('📝 [EDIT] isNew=$isNew weight=${result['weight']} date=${result['date']} tod=${result['tod']}');

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final double w = result['weight'];
        final DateTime d = result['date'];
        final String t = result['tod'];

        if (isNew) {
          // ✅ pass the dialog's date instead of relying on _selectedDate
          await _saveWeight(w, 'kg', tod: t);
          // afterwards, fix the timestamp to match the chosen date
          // (fetch the most recent doc just added if needed, or extend _saveWeight to accept `date`)
        } else {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('weights')
              .doc(weightEntry['id'])
              .update({
            'weight': w,
            'timestamp': Timestamp.fromDate(d),
            'tod': t,
          });

          // ⛳ ANCHOR: WES_WEIGHT_HOOK_EDIT_UPDATE
          try {
            final uidSelected = userId;                   // acting-as user (selected athlete)
            final DateTime dOnly = DateTime(d.year, d.month, d.day); // `d` is the edited date from dialog
            unawaited(_warmWESForDateOnly(uid: uidSelected, date: dOnly));  // fire-and-forget
            debugPrint('🚀 [BW Hook:EditUpdate] Warm kicked for ${dOnly.toIso8601String().substring(0,10)} (uid=$uidSelected)');
          } catch (e) {
            debugPrint('🟧 [BW Hook:EditUpdate] Failed to kick warm: $e');
          }

        }
        _fetchWeights();
      }
    }


  }

  Future<void> _addWeightEntry({required DateTime date, required String tod}) async {
    print('➡️ [_addWeightEntry] entered tod=$tod date=$date');
    // Same dialog UI shape as _editWeightEntry, but "Add" flow
    final TextEditingController weightController = TextEditingController(text: '');
    DateTime selectedDate = date;

    // For UI parity with edit: show the 3 calc rows, but they’ll be blank (nulls)
    double? diffFromPrevious;
    double? diffFrom3DayAvg;
    double? diffFrom7DayAvg;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text(
          'Add Weigh-in (${tod.toUpperCase()})',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.of(context).viewInsets.bottom, // keep above keyboard
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
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
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                scrollPadding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + 80,
                ),
                decoration: const InputDecoration(labelText: 'Weight (kg)'),
              ),
              const SizedBox(height: 16),
              const Text('Calculations:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              _diffText('Δ from previous', diffFromPrevious),
              _diffText('Δ from 3-day avg', diffFrom3DayAvg),
              _diffText('Δ from 7-day avg', diffFrom7DayAvg),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final val = double.tryParse(weightController.text);
              if (val != null && val > 0) {
                Navigator.pop(context, {
                  'weight': val,
                  'date': selectedDate,
                  'tod': tod,
                });
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );


    print('🔍 [_addWeightEntry] result=${result == null ? "null" : "weight=${result['weight']} date=${result['date']} tod=${result['tod']}"}');



    if (result != null && result['weight'] != null) {
      final double w = (result['weight'] as num).toDouble();
      final DateTime d = result['date'] as DateTime;
      final String t = result['tod'] as String;

      final before = _weights.length;
      setState(() => _selectedDate = d);

      print('➕ [_addWeightEntry] saving w=$w tod=$t date=${DateFormat('yyyy-MM-dd').format(d)} (count before=$before)');
      await _saveWeight(w, 'kg', tod: t); // _saveWeight should await _fetchWeights()
      print('✅ [_addWeightEntry] done. count $before -> ${_weights.length}');
    } else {
      print('⚠️ [_addWeightEntry] canceled or invalid weight');
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

    final now = DateTime.now();
    final averageSourceWeights = _weightsForAverageSource();

    final double? average3Day = _averageRecentEntries(averageSourceWeights, 3);
    final double? averageLast7 = _averageWithinWindow(
      averageSourceWeights,
      now.subtract(const Duration(days: 7)),
      now.add(const Duration(days: 1)),
    );
    final double? averagePrev7 = _averageWithinWindow(
      averageSourceWeights,
      now.subtract(const Duration(days: 14)),
      now.subtract(const Duration(days: 7)),
    );

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
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                          Expanded(
                            child: Text(
                              _fmtDate(_selectedDate),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
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
                    if (weight > 0) {
                      _saveWeight(weight, 'kg', tod: 'am'); // ✅ AM entry
                      _weightController.clear();            // optional parity with PM clear
                    }
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    minimumSize: const Size(0, 0),
                  ),
                ),

              ],
            ),


            if (_showSecondWeighIn) ...[
              const SizedBox(height: 0),

              Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: SizedBox(
                      height: 48,
                      child: TextField(
                        controller: _weightControllerPm,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),

                        decoration: const InputDecoration(
                          labelText: '2nd Weight (kg)',
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

                  // ✅ Save button aligns under first because it’s in the same flex row
                  ElevatedButton.icon(
                    onPressed: () {
                      final weight = double.tryParse(_weightControllerPm.text) ?? 0.0;
                      if (weight > 0) {
                        _saveWeight(weight, 'kg', tod: 'pm');
                        const Text('Save 2nd')
                        ;
                      }
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save 2nd'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      minimumSize: const Size(0, 0),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 6),

              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Date: ${_fmtDate(_selectedDate)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],


            // ---- Trend Chart (14-day <-> 1-month toggle) ----
            Builder(
              builder: (_) {
                // Resolve the active AM/PM series for current range
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

                // Decide which series to show
                final showPm = _showSecondWeighIn && pm.isNotEmpty;
                final hasAm = am.isNotEmpty;
                final hasData = hasAm || showPm;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 20),

                    // 🔹 Chart title row with 3-dot menu
                    Row(
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: GestureDetector(
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
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (value) {
                              setState(() {
                                switch (value) {
                                  case 'toggle_second':
                                    _showSecondWeighIn = !_showSecondWeighIn;
                                    break;
                                  case 'avg_am':
                                    _averageSource = BodyWeightAverageSource.am;
                                    break;
                                  case 'avg_pm':
                                    _averageSource = BodyWeightAverageSource.pm;
                                    break;
                                }
                              });
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem<String>(
                                value: 'toggle_second',
                                child: Text(_showSecondWeighIn
                                    ? 'Hide 2nd weigh-in'
                                    : 'Add 2nd weigh-in'),
                              ),
                              PopupMenuItem<String>(
                                value: 'avg_am',
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Text('Use AM weigh-in for average'),
                                    ),
                                    if (_averageSource == BodyWeightAverageSource.am)
                                      const Icon(Icons.check, size: 18),
                                  ],
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'avg_pm',
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Text('Use PM weigh-in for average'),
                                    ),
                                    if (_averageSource == BodyWeightAverageSource.pm)
                                      const Icon(Icons.check, size: 18),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    if (!hasData)
                      const SizedBox(
                        height: 200,
                        child: Center(child: Text('No data for this range')),
                      )
                    else
                    Builder(builder: (context) {
                      final baseSeries = hasAm ? am : pm;
                      final allY = <double>[
                        ...am.map<double>((e) => e['weight'] as double),
                        if (showPm) ...pm.map<double>((e) => e['weight'] as double),
                      ];
                      final double minY = allY.reduce((a, b) => a < b ? a : b) - 1;
                      final double maxY = allY.reduce((a, b) => a > b ? a : b) + 1;
                      final double rawMaxX = (hasAm ? am.length - 1 : pm.length - 1).toDouble();
                      final double maxX = rawMaxX < 1.0 ? 1.0 : rawMaxX;
                      return SizedBox(
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
                                  final series = baseSeries;
                                  if (i < 0 || i >= series.length) return const SizedBox.shrink();

                                  // Label density by range
                                  int showEvery;
                                  switch (_trend) {
                                    case TrendRange.d14:  showEvery = 1;  break;
                                    case TrendRange.m30:  showEvery = 2;  break;
                                    case TrendRange.m90:  showEvery = 7;  break;
                                    case TrendRange.m180: showEvery = 14; break;
                                    case TrendRange.y365: showEvery = 30; break;
                                  }
                                  if (i % showEvery != 0 && i != series.length - 1) {
                                    return const SizedBox.shrink();
                                  }

                                  final date = series[i]['date'] as DateTime;
                                  final label = DateFormat('d MMM').format(date);

                                  return Transform.rotate(
                                    angle: -0.5,
                                    alignment: Alignment.topRight,
                                    child: Text(label, style: const TextStyle(fontSize: 10)),
                                  );
                                },
                              ),
                            ),
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 1,
                                reservedSize: 28,
                                getTitlesWidget: (value, meta) {
                                  if (value == maxY) return const SizedBox.shrink();
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
                                  if (value == maxY) return const SizedBox.shrink();
                                  return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 12));
                                },
                              ),
                            ),
                          ),
                          borderData: FlBorderData(show: true),
                          minX: 0,
                          maxX: maxX,
                          minY: minY,
                          maxY: maxY,

                          lineBarsData: [
                            if (hasAm)
                              LineChartBarData(
                                isCurved: true,
                                spots: List.generate(
                                  am.length,
                                      (i) => FlSpot(i.toDouble(), (am[i]['weight'] as double)),
                                ),
                                barWidth: 2,
                                color: Theme.of(context).colorScheme.primary, // AM
                                dotData: FlDotData(
                                  show: true,
                                  getDotPainter: (spot, percent, bar, index) =>
                                      FlDotCirclePainter(
                                    radius: 2,
                                    strokeWidth: 0,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            if (showPm)
                              LineChartBarData(
                                isCurved: true,
                                spots: List.generate(
                                  pm.length,
                                      (i) => FlSpot(i.toDouble(), (pm[i]['weight'] as double)),
                                ),
                                barWidth: 2,
                                color: Colors.pinkAccent, // PM
                                dotData: FlDotData(
                                  show: true,
                                  getDotPainter: (spot, percent, bar, index) =>
                                      FlDotCirclePainter(
                                    radius: 2,
                                    strokeWidth: 0,
                                    color: Colors.pinkAccent,
                                  ),
                                ),
                              ),
                          ],


                          lineTouchData: LineTouchData(
                            touchTooltipData: LineTouchTooltipData(
                              tooltipBgColor: Colors.grey.shade900,
                              getTooltipItems: (touchedSpots) {
                                return touchedSpots.map((spot) {
                                  final gi = spot.barIndex; // 0 = AM, 1 = PM (if present)
                                  final xi = spot.x.toInt();
                                  final list = (gi == 0) ? am : pm;
                                  if (xi < 0 || xi >= list.length) return null;

                                  final date = list[xi]['date'] as DateTime;
                                  final y    = list[xi]['weight'] as double;
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
                    );
                    }),

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
                          title: Text(show3DayAverage ? '3-Day Avg ($_averageSourceLabel)' : '7-Day Avg ($_averageSourceLabel)'),
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
              Builder(
                builder: (context) => Card(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: const Icon(Icons.compare, color: Colors.cyan),
                    title: Text('Weekly Comparison ($_averageSourceLabel)'),
                    subtitle: Text('This week: ${averageLast7!.toStringAsFixed(1)} kg\nLast week: ${averagePrev7!.toStringAsFixed(1)} kg'),
                  ),
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
              Builder(
                builder: (context) {
                  // group entries by date
                  final Map<String, Map<String, dynamic>> byDate = {};
                  for (final w in _weights) {
                    final date = w['date'] as DateTime;
                    final dateKey =
                        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
                    final tod = (w['tod'] as String?)?.toLowerCase() ?? 'am'; // back-compat
                    byDate.putIfAbsent(dateKey, () => {'date': date});
                    byDate[dateKey]![tod] = w;
                  }

                  final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a)); // newest first

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Header row ─────────────────────────────────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 80, // matches the date column width in your rows
                              child: Text(
                                'Date',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 0),
                            Expanded(
                              child: Text(
                                'AM',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary, // ✅ match AM color
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'PM',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.pinkAccent, // ✅ match PM color
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),


                      // ── Your list rows (unchanged, just moved under the header) ───────────────
                      ListView.builder(
                        itemCount: dates.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemBuilder: (context, index) {
                          final key = dates[index];
                          final row = byDate[key]!;
                          final date = row['date'] as DateTime;
                          final am = row['am'] as Map<String, dynamic>?;
                          final pm = row['pm'] as Map<String, dynamic>?;

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                children: [
                                  // Date column (fixed width to align with header)
                                  SizedBox(
                                    width: 80,
                                    child: Text(
                                      DateFormat('dd-MM').format(date),
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                  ),

                                  // AM cell
                                  Expanded(
                                    child: InkWell(
                                      onTap: () {
                                        if (am != null) {
                                          _editWeightEntry(am);
                                        } else {
                                          _addWeightEntry(date: date, tod: 'am');
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Colors.white24),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          am != null ? '${am['weight']} ${am['unit']}' : '＋',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary),
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  // PM cell
                                  Expanded(
                                    child: InkWell(
                                      onTap: () {
                                        if (pm != null) {
                                          _editWeightEntry(pm);
                                        } else {
                                          _addWeightEntry(date: date, tod: 'pm');
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Colors.white24),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          pm != null ? '${pm['weight']} ${pm['unit']}' : '＋',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 13, color: Colors.pinkAccent),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
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
