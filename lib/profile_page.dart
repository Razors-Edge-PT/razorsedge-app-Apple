import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'periodization_model_utils.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';


enum _CompMode { threeLift, benchOnly }

class BestLift {
  final String exerciseName;
  final double weight; // kg
  final int reps;
  final double e1rm; // calc with RIR=0
  final DateTime? date;

  BestLift({
    required this.exerciseName,
    required this.weight,
    required this.reps,
    required this.e1rm,
    this.date,
  });
}


class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();

}

class _StatChip extends StatelessWidget {
  final String label;
  final double? value;
  const _StatChip({required this.label, required this.value});



  @override
  Widget build(BuildContext context) {
    final text = (value == null) ? '--' : value!.toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.blueGrey.withOpacity(0.35)),
      ),
      child: Text('$label: $text',
          style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}


class _ProfilePageState extends State<ProfilePage> {
  final _picker = ImagePicker();
  File? _localProfileImage;           // <-- use this one
  String? photoURL;
  String? _localProfilePath; // persisted path on device

  // Bio
  final TextEditingController _bioController = TextEditingController();
  double squat = 0, bench = 0, deadlift = 0, chinUp = 0, unilateralPress = 0;
  bool isLoading = true;

  // UI layout
  static const double _rightColWidth = 190; // tweak to taste

  // Comp totals/toggle
  _CompMode _compMode = _CompMode.threeLift;
  double? _bestThreeLiftTotal; // kg
  double? _bestBenchOnly;      // kg

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _loadLocalProfileImage();
    _loadPhotoURL();
    _refreshBestLiftsAndPoints(); // NEW
  }

  Future<void> _loadProfileData() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (doc.exists) {
      final data = doc.data() ?? {};
      _bioController.text = data['bio'] ?? '';
      squat = (data['bestSquat'] ?? 0).toDouble();
      bench = (data['bestBench'] ?? 0).toDouble();
      deadlift = (data['bestDeadlift'] ?? 0).toDouble();
      chinUp = (data['bestChinUp'] ?? 0).toDouble();
      unilateralPress = (data['bestUnilateralPress'] ?? 0).toDouble();
    }
    setState(() => isLoading = false);
  }

  Future<void> _saveProfileData() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'bio': _bioController.text,
    }, SetOptions(merge: true));
  }


  Future<void> _loadPhotoURL() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (snap.exists) {
        setState(() {
          photoURL = snap.data()?['photoURL'] as String?;
        });
      }
    } catch (e) {
      debugPrint('❌ Failed to load photoURL: $e');
    }
  }

  Future<void> _loadLocalProfileImage() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('profile_local_path');
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      setState(() {
        _localProfilePath = path;
        _localProfileImage = File(path);
      });
    }
  }

  Future<void> _pickAndUploadProfileImage() async {
    // Local-only picker
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    final tempFile = File(picked.path);

    // Copy to app documents so it persists (cache may be cleared by OS)
    final appDir = await getApplicationDocumentsDirectory();
    final destPath = '${appDir.path}/profile.jpg';
    await tempFile.copy(destPath);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_local_path', destPath);

    setState(() {
      _localProfilePath = destPath;
      _localProfileImage = File(destPath);
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile photo updated (local only)')),
    );
  }


  final List<String> _displayExercises = const [
    'Bench Press, Barbell',
    'Back Squat, Barbell',
    'Deadlift, Conventional',
    'Chin-Up',
    'Overhead Dumbbell Press, Unilateral',
  ];

  final Map<String, String> _shortExerciseNames = const {
    'Bench Press, Barbell': 'Bench Press',
    'Back Squat, Barbell': 'Back Squat',
    'Deadlift, Conventional': 'Deadlift',
    'Chin-Up': 'Chin-Up',
    'Overhead Dumbbell Press, Unilateral': 'Standing, Uni Shoulder Press',
  };


  final Map<String, BestLift> _bestLifts = {}; // keyed by exercise name

  double? _goodliftPoints; // TODO: fill when you want
  double? _rePoints;       // TODO: fill when you want

  Future<void> _refreshBestLiftsAndPoints() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    try {
      final best = await _fetchBestLiftsFromWorkouts(uid, _displayExercises);
      final gl = await _computeGoodliftPoints(uid, best); // TODO real formula
      final re = await _computeREPoints(uid, best);       // TODO your brand metric
      await _computeCompTotals(uid);



      if (!mounted) return;
      setState(() {
        _bestLifts
          ..clear()
          ..addAll(best);
        _goodliftPoints = gl;
        _rePoints = re;
      });
    } catch (e) {
      debugPrint('❌ Failed to refresh best lifts/points: $e');
    }


  }

  Future<Map<String, BestLift>> _fetchBestLiftsFromWorkouts(
      String uid,
      List<String> displayExercises,
      ) async {
    final out = <String, BestLift>{};
    final workoutsCol = FirebaseFirestore.instance
        .collection('users').doc(uid)
        .collection('workouts');

    // Try to order by ISO-8601 date string; fallback to unordered if it errors.
    QuerySnapshot<Map<String, dynamic>> snaps;
    try {
      snaps = await workoutsCol.orderBy('date', descending: true).limit(600).get();
    } catch (_) {
      snaps = await workoutsCol.limit(600).get();
    }

    bool isIsoDate(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(s);

    for (final doc in snaps.docs) {
      final data = doc.data();
      final rawDate = data['date'];
      DateTime? dt;
      if (rawDate is String && isIsoDate(rawDate)) {
        dt = DateTime.tryParse(rawDate);
      }

      final exercises = (data['exercises'] is List)
          ? List<Map<String, dynamic>>.from(data['exercises'] as List)
          : const <Map<String, dynamic>>[];

      for (final ex in exercises) {
        final name = (ex['name'] as String?)?.trim() ?? '';
        if (!displayExercises.contains(name)) continue;

        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'] as List)
            : const <Map<String, dynamic>>[];

        for (final s in sets) {
          final w = (s['weight'] is num) ? (s['weight'] as num).toDouble() : 0.0;
          final r = (s['reps'] is num) ? (s['reps'] as num).toInt() : 0;
          if (w <= 0 || r <= 0) continue;

          // Use your PMU, forcing RIR = 0 (ignored by design here)
          final e1 = PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), 0.0);


          final current = out[name];
          if (current == null || e1 > current.e1rm) {
            out[name] = BestLift(
              exerciseName: name,
              weight: w,
              reps: r,
              e1rm: e1,
              date: dt,
            );
          }
        }
      }
    }

    // Ensure every display exercise has an entry (or remains absent)
    return out;
  }

  String _canonical(String name) {
    final n = name.trim();
    if (n == 'Deadlift') return 'Deadlift, Conventional';
    if (n == 'Back Squat') return 'Back Squat, Barbell';
    if (n == 'Bench Press') return 'Bench Press, Barbell';
    return n;
  }

  Future<void> _computeCompTotals(String uid) async {
    final workoutsCol = FirebaseFirestore.instance
        .collection('users').doc(uid)
        .collection('workouts');

    QuerySnapshot<Map<String, dynamic>> snaps;
    try {
      snaps = await workoutsCol.orderBy('date', descending: true).limit(600).get();
    } catch (_) {
      snaps = await workoutsCol.limit(600).get();
    }

    const squatName = 'Back Squat, Barbell';
    const benchName = 'Bench Press, Barbell';
    const deadName  = 'Deadlift, Conventional';

    final Map<String, double> bestSingle = {
      squatName: 0, benchName: 0, deadName: 0,
    };
    final Map<String, double> bestAny = {
      squatName: 0, benchName: 0, deadName: 0,
    };

    for (final doc in snaps.docs) {
      final data = doc.data();
      final exercises = (data['exercises'] is List)
          ? List<Map<String, dynamic>>.from(data['exercises'] as List)
          : const <Map<String, dynamic>>[];

      for (final ex in exercises) {
        final name = _canonical((ex['name'] as String?)?.trim() ?? '');
        if (!bestSingle.containsKey(name)) continue; // only S/B/D

        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'] as List)
            : const <Map<String, dynamic>>[];

        for (final s in sets) {
          final w = (s['weight'] is num) ? (s['weight'] as num).toDouble() : 0.0;

          final rRaw = s['reps'];
          final r = (rRaw is num) ? rRaw.toInt() : int.tryParse('$rRaw') ?? 0;

          if (w <= 0) continue;

          // Track best single
          if (r == 1 && w > (bestSingle[name] ?? 0)) {
            bestSingle[name] = w;
          }
          // Track heaviest weight (any reps) for fallback
          if (w > (bestAny[name] ?? 0)) {
            bestAny[name] = w;
          }
        }
      }
    }

    // Debug logs — keep these INSIDE the function so bestSingle/bestAny are in scope
    debugPrint('🏋️ Best single S/B/D: '
        'S=${bestSingle[squatName]}, B=${bestSingle[benchName]}, D=${bestSingle[deadName]}');
    debugPrint('🔁 Fallback any-rep S/B/D: '
        'S=${bestAny[squatName]}, B=${bestAny[benchName]}, D=${bestAny[deadName]}');

    // Use best single if available, else fallback to best any-rep
    double squatBest = (bestSingle[squatName] ?? 0) > 0
        ? (bestSingle[squatName] ?? 0)
        : (bestAny[squatName] ?? 0);
    double benchBest = (bestSingle[benchName] ?? 0) > 0
        ? (bestSingle[benchName] ?? 0)
        : (bestAny[benchName] ?? 0);
    double deadBest  = (bestSingle[deadName]  ?? 0) > 0
        ? (bestSingle[deadName]  ?? 0)
        : (bestAny[deadName]  ?? 0);

    final threeLift = squatBest + benchBest + deadBest;
    final benchOnly = benchBest;

    if (!mounted) return;
    setState(() {
      _bestThreeLiftTotal = (threeLift > 0) ? threeLift : null;
      _bestBenchOnly      = (benchOnly > 0) ? benchOnly : null;
    });

    debugPrint('🏆 Totals → 3-Lift=$_bestThreeLiftTotal, BenchOnly=$_bestBenchOnly');
  }


// Stubs – wire these when you’re ready
  Future<double?> _computeGoodliftPoints(String uid, Map<String, BestLift> best) async {
    // Pull bodyweight/sex/equipment from users/{uid} and apply GL formula.
    // Return null to show “--” for now.
    return null;
  }

  Future<double?> _computeREPoints(String uid, Map<String, BestLift> best) async {
    // Your brand metric. Example idea:
    // final s = best['Back Squat, Barbell']?.e1rm ?? 0;
    // final b = best['Bench Press, Barbell']?.e1rm ?? 0;
    // final d = best['Deadlift, Conventional']?.e1rm ?? 0;
    // return (s + b + d);
    return null;
  }



  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.email ?? '';

    final ImageProvider? avatarImage =
    _localProfileImage != null
        ? FileImage(_localProfileImage!)
        : (_localProfilePath != null && File(_localProfilePath!).existsSync())
        ? FileImage(File(_localProfilePath!))
        : null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blueGrey,
        automaticallyImplyLeading: false, // disable default
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context); // go back to the previous page
          },
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 180,
                  child: Text(
                    userEmail,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      overflow: TextOverflow.ellipsis,
                    ),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(9.0),
            child: SizedBox(
              height: kToolbarHeight,
              child: Center(
                child: GestureDetector(
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Change Profile Picture?'),
                        content: const Text('Do you want to change your profile picture?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel')),
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Yes')),
                        ],
                      ),
                    );
                    if (confirm == true) _pickAndUploadProfileImage();
                  },
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: avatarImage,
                    child: avatarImage == null ? const Icon(Icons.person, size: 18) : null,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),

      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Profile Picture
                GestureDetector(
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Change Profile Picture?'),
                        content: const Text('Do you want to change your profile picture?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) _pickAndUploadProfileImage();
                  },
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: _localProfileImage != null
                        ? FileImage(_localProfileImage!)
                        : (_localProfilePath != null && File(_localProfilePath!).existsSync())
                        ? FileImage(File(_localProfilePath!))
                        : null,
                    child: (_localProfileImage == null &&
                        (_localProfilePath == null || !File(_localProfilePath!).existsSync()))
                        ? const Icon(Icons.person, size: 48)
                        : null,
                  ),
                ),

                const SizedBox(width: 16),

                // Points chips
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatChip(label: 'Goodlift', value: _goodliftPoints),
                      const SizedBox(height: 8),
                      _StatChip(label: 'RE Points', value: _rePoints),
                      const SizedBox(height: 8),

                      // Best Comp Total line
                      _StatChip(
                        label: 'Best Comp Total',
                        value: _compMode == _CompMode.threeLift
                            ? _bestThreeLiftTotal
                            : _bestBenchOnly,
                      ),


                      const SizedBox(height: 4),

                      // Toggle buttons
                      ToggleButtons(
                        isSelected: [
                          _compMode == _CompMode.threeLift,
                          _compMode == _CompMode.benchOnly,
                        ],
                        onPressed: (idx) {
                          setState(() {
                            _compMode =
                            (idx == 0) ? _CompMode.threeLift : _CompMode.benchOnly;
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        constraints: const BoxConstraints(minHeight: 32, minWidth: 80),
                        children: const [
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('3-Lift'),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('Bench Only'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),



              ],
            ),



            const SizedBox(height: 16),

            // Bio Section
            const Text('About Me',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _bioController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Write a short bio about yourself...',
                filled: true,
                fillColor: Colors.blueGrey,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 20),

            // Best Lifts Section
            // Best Lifts header with chips
            Row(
              children: [
                const Expanded(
                  child: Text('Best Lifts',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                _StatChip(label: 'Goodlift', value: _goodliftPoints),
                const SizedBox(width: 8),
                _StatChip(label: 'RE Points', value: _rePoints),
              ],
            ),
            const SizedBox(height: 8),

// Read-only best lifts list
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.blueGrey.withOpacity(0.10),
              ),
              child: Column(
                children: _displayExercises.map((name) {
                  final lift = _bestLifts[name];
                  final rightText = (lift == null)
                      ? '—'
                      : '${lift.weight.toStringAsFixed(1)} × ${lift.reps}  ~ ${lift.e1rm.toStringAsFixed(1)} E1RM';

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        // Left: exercise name (fills remaining space)
                        Expanded(
                          child: Text(
                            _shortExerciseNames[name] ?? name, // falls back to full if not found
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),


                        // Right: aligned “weight × reps  •  ~e1RM” in a blue-grey chip
                        SizedBox(
                          width: _rightColWidth, // ensures all rows start at same x-position
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey, // blue-grey background
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              rightText,
                              style: const TextStyle(
                                color: Colors.white, // readable on blue-grey
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),



            // Stats
            const Text('Stats',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Goodlift Points: (pending calc)',
                style: Theme.of(context).textTheme.bodyLarge),
            Text('RE Points: (pending calc)',
                style: Theme.of(context).textTheme.bodyLarge),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveProfileData,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
              child: const Text('Save Profile'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiftRow(String label, double value, Function(double) onChanged) {
    final controller = TextEditingController(text: value.toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          SizedBox(
            width: 80,
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (val) => onChanged(double.tryParse(val) ?? 0),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.blueGrey,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
