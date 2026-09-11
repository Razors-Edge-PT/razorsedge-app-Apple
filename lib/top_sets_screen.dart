import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';
import 'user_context.dart';
import 'package:google_fonts/google_fonts.dart';
import 'periodization_model_utils.dart';
import 'bodyweight_load.dart';

class TopSetsScreen extends StatefulWidget {
  final String exerciseName;
  final String? exerciseId;
  final List<Workout> recentWorkouts;

  const TopSetsScreen({
    super.key,
    required this.exerciseName,
    this.exerciseId,
    required this.recentWorkouts,
  });

  @override
  _TopSetsScreenState createState() => _TopSetsScreenState();
}


class _TopSetsScreenState extends State<TopSetsScreen> {

  bool _isLoading = true;

  final int _pageSize = 50;
  final ScrollController _scrollController = ScrollController();

  List<Workout> _workouts = [];             // replaces using widget.recentWorkouts
  DocumentSnapshot? _lastDoc;               // pagination anchor
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String _sortOption = 'date';
  int? _selectedRepTarget;

  String get userId => UserContext.of(context, listen: false).currentUid;

  @override
  void initState() {
    super.initState();
    _loadInitialWorkouts();
    _scrollController.addListener(_onScroll);
    final uid = userId;
    _primeBwHistory(uid).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _primeBwHistory(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .limit(1000)
          .get();
      final entries = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final data = d.data();
        final double? bw = (data['weight'] as num?)?.toDouble();
        final DateTime ts =
            (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        final String unit = (data['unit'] as String?) ?? 'kg';
        if (bw != null && bw > 0 && unit == 'kg') {
          entries.add({
            'date': ts,
            'weight': bw,
            'unit': 'kg',
            'tod': data['tod'],
            'id': d.id,
          });
        }
      }
      if (entries.isNotEmpty) {
        PeriodizationModelUtils.setBodyweightHistory(uid: uid, entries: entries);
      }
    } catch (e) {
      debugPrint('⚠️ [TopSets] BW history load failed: $e');
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }


  Future<void> _loadInitialWorkouts() async {
    setState(() => _isInitialLoading = true);


    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // 👈 selected user, not logged-in
          .collection('workouts')
          .orderBy('date', descending: true)
          .limit(_pageSize)
          .get();

      final docs = snap.docs;
      setState(() {
        _workouts = docs.map((d) => Workout.fromFirestore(d)).toList();
        _lastDoc = docs.isNotEmpty ? docs.last : null;
        _hasMore = docs.length == _pageSize;
        _isInitialLoading = false;
      });

      print('📊 [TopSets] (uid=$userId) Loaded initial ${_workouts.length} workouts.');
    } catch (e) {
      print('❌ [TopSets] Error loading initial workouts for uid=$userId: $e');
      setState(() => _isInitialLoading = false);
    }
  }


  Future<void> _loadMoreWorkouts() async {
    if (!_hasMore || _isLoadingMore || _lastDoc == null) return;

    setState(() => _isLoadingMore = true);

    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId) // 👈 selected user, not logged-in
          .collection('workouts')
          .orderBy('date', descending: true)
          .startAfterDocument(_lastDoc!)
          .limit(_pageSize)
          .get();

      final docs = snap.docs;
      setState(() {
        _workouts.addAll(docs.map((d) => Workout.fromFirestore(d)));
        _lastDoc = docs.isNotEmpty ? docs.last : _lastDoc;
        _hasMore = docs.length == _pageSize;
        _isLoadingMore = false;
      });

      print('📊 [TopSets] (uid=$userId) Loaded +${docs.length} more. Total=${_workouts.length}');
    } catch (e) {
      print('❌ [TopSets] Error loading more workouts for uid=$userId: $e');
      setState(() => _isLoadingMore = false);
    }
  }


  void _sortWorkouts() {
    setState(() {
      if (_sortOption == 'date') {
        _workouts.sort((a, b) => b.date.compareTo(a.date));
      } else if (_sortOption == 'e1rm') {
        final isBw = PeriodizationModelUtils.isBodyweightExercise(
          id: widget.exerciseId,
          name: widget.exerciseName,
        );
        if (isBw) {
          // Added E1RM of each set's TOTAL load at the bodyweight recorded on
          // or before that day (bodyweight_load.dart); unknown counts as 0.
          double topAddedE1rm(Workout w) {
            final double? bw = PeriodizationModelUtils
                .recordedBodyweightKgOnOrBefore(uid: userId, asOf: w.date);
            double best = 0.0;
            if (bw == null) return best;
            for (final ex in w.exercises) {
              if (ex.name != widget.exerciseName) continue;
              for (final s in ex.sets) {
                final double? total = s.bodyweightLoad(bw).totalKg;
                if (total == null) continue;
                final e = calculateE1RM(total, (s.reps ?? 0).toDouble(), s.rir ?? 0) - bw;
                if (e > best) best = e;
              }
            }
            return best;
          }
          _workouts.sort((a, b) => topAddedE1rm(b).compareTo(topAddedE1rm(a)));
        } else {
          double topE1rm(Workout w) => w.exercises
              .expand((e) => e.sets)
              .map((s) => calculateE1RM(s.weight ?? 0, (s.reps ?? 0).toDouble(), s.rir ?? 0))
              .fold(0.0, (p, c) => c > p ? c : p);
          _workouts.sort((a, b) => topE1rm(b).compareTo(topE1rm(a)));
        }
      }
    });
  }


// Trigger load-more when near the end of the list
  void _onScroll() {
    if (!_hasMore || _isLoadingMore) return;
    if (!_scrollController.hasClients) return;

    final threshold = 200.0; // px from bottom to trigger pagination
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <= threshold) {
      _loadMoreWorkouts();
    }
  }


  double calculateE1RM(double weight, double reps, double rir) {
    return PeriodizationModelUtils.calculateE1RM(weight, reps, rir);
  }





  void _showFilterDialog(BuildContext context) {
    TextEditingController repTargetController = TextEditingController();
    repTargetController.text = _selectedRepTarget?.toString() ?? '';

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Filter by Rep Target"),
          content: TextField(
            controller: repTargetController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Enter Rep Target",
              border: OutlineInputBorder(),
            ),
            onChanged: (input) {
              int? manualInput = int.tryParse(input);
              if (manualInput != null && manualInput > 0) {
                setState(() {
                  _selectedRepTarget = manualInput;
                });
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedRepTarget = null;
                });
                Navigator.pop(context);
              },
              child: const Text("Clear"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text("Apply"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.exerciseName} '),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SizedBox(width: 18), // Add spacing to move Sort closer to Filter
                Text(
                  'Top Sets by E1RM',
                  style: GoogleFonts.monda(
                    fontSize: 19, fontWeight: FontWeight.bold,
                    color: Colors.white,
                    // fontWeight: FontWeight.w700, // optional
                  ),
                ),
                SizedBox(width: 2), // Add spacing to move Sort closer to Filter

                PopupMenuButton<String>(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0), // Rounded edges for the dropdown
                  ),
                  onSelected: (String value) {
                    setState(() {
                      _sortOption = value;
                      _sortWorkouts();
                    });
                  },
                  itemBuilder: (BuildContext context) => [
                    const PopupMenuItem(value: 'date', child: Text('Sort by Date')),
                    const PopupMenuItem(value: 'e1rm', child: Text('Sort by Top E1RM')),
                  ],
                  child: ElevatedButton(
                    onPressed: null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.secondary, // Sort button color
                      disabledBackgroundColor: Theme.of(context).colorScheme.secondary,
                      disabledForegroundColor: Theme.of(context).colorScheme.secondary,
                      elevation: 0,
                    ),
                    child: const Text("Sort", style: TextStyle(color: Colors.white)),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => _showFilterDialog(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:  Theme.of(context).colorScheme.secondary,// Filter button color
                  ),
                  child: const Text("Filters", style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isInitialLoading
                ? const Center(child: CircularProgressIndicator())
                : _workouts.isEmpty
                ? const Center(child: Text("No previous workouts found."))
                : ListView.builder(
              controller: _scrollController,
              itemCount: _workouts.length + 1, // +1 for footer
              itemBuilder: (context, index) {
                // Footer row for load more / spinner / end
                if (index == _workouts.length) {
                  if (_isLoadingMore) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (_hasMore) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: TextButton(
                          onPressed: _loadMoreWorkouts,
                          child: const Text('Load more'),
                        ),
                      ),
                    );
                  }
                  return const SizedBox(height: 16); // end spacer
                }

                final workout = _workouts[index];

                final isBw = PeriodizationModelUtils.isBodyweightExercise(
                  id: widget.exerciseId,
                  name: widget.exerciseName,
                );
                // Bodyweight exercises: WES2 stores the added load, the legacy
                // screen stored the total (bodyweight_load.dart). Each set is
                // read at the bodyweight recorded on or before this day and
                // ranked on its TOTAL load.
                final double? dayBw = isBw
                    ? PeriodizationModelUtils.recordedBodyweightKgOnOrBefore(
                        uid: userId, asOf: workout.date)
                    : null;
                double rankWeight(SetDetails s) => isBw
                    ? (s.bodyweightLoad(dayBw).totalKg ?? 0.0)
                    : (s.weight ?? 0.0);

                // 🔎 Only consider sets for the selected exercise
                SetDetails? topSet;
                double highestE1RM = 0.0;
                String? topExerciseName;

                for (var exercise in workout.exercises) {
                  if (exercise.name != widget.exerciseName) continue;

                  for (var set in exercise.sets) {
                    if (_selectedRepTarget != null && set.reps != _selectedRepTarget) {
                      continue;
                    }
                    final weight = rankWeight(set);
                    final reps = (set.reps ?? 0).toDouble();
                    final rir  = set.rir ?? 0.0;
                    final e1rm = calculateE1RM(weight, reps, rir);

                    // Same canonical rule the progression history index uses,
                    // so the visible Top Set and the sample progression treats
                    // as that date's history can never be different sets.
                    if (topSet == null ||
                        PeriodizationModelUtils.beatsTopSet(
                          candidateWeight: weight,
                          candidateReps: reps,
                          candidateRir: rir,
                          incumbentWeight: rankWeight(topSet),
                          incumbentReps: (topSet.reps ?? 0).toDouble(),
                          incumbentRir: topSet.rir ?? 0.0,
                        )) {
                      highestE1RM = e1rm;
                      topSet = set;
                      topExerciseName = exercise.name;
                    }
                  }
                }

                if (topSet == null) return const SizedBox.shrink();
                final highlight = _selectedRepTarget != null && topSet!.reps == _selectedRepTarget;

                final String weightLabel;
                final String e1rmLabel;
                if (isBw) {
                  final NormalizedLoad load = topSet!.bodyweightLoad(dayBw);
                  final double? added = load.addedKg;
                  final double? total = load.totalKg;
                  weightLabel = added != null
                      ? '+${(added < 0 ? 0.0 : added).toStringAsFixed(1)} kg'
                      : '${(total ?? 0.0).toStringAsFixed(1)} kg total';
                  if (total != null && dayBw != null) {
                    final double e = calculateE1RM(total,
                            (topSet!.reps ?? 0).toDouble(), topSet!.rir ?? 0.0) -
                        dayBw;
                    e1rmLabel = '+${(e < 0 ? 0.0 : e).toStringAsFixed(1)} kg';
                  } else {
                    e1rmLabel = '— (BW not recorded)';
                  }
                } else {
                  weightLabel = '${(topSet!.weight ?? 0.0).toStringAsFixed(1)} kg';
                  e1rmLabel = '${highestE1RM.toStringAsFixed(1)} kg';
                }

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  shape: highlight
                      ? RoundedRectangleBorder(
                    side: const BorderSide(color: Colors.blue, width: 2.0),
                    borderRadius: BorderRadius.circular(8.0),
                  )
                      : null,
                  child: ListTile(
                    title: Text(
                      '$topExerciseName - ${DateFormat('dd-MM-yyyy').format(workout.date)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style,
                        children: [
                          TextSpan(
                            text: weightLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: ' x ',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: '${topSet!.reps}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: ', RIR: ',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: '${topSet!.rir}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: ' | E1RM: ',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                          TextSpan(
                            text: e1rmLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          )

        ],
      ),

    );
  }
}
