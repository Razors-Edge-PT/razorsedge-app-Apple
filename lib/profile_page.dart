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
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';


enum _CompMode { threeLift, benchOnly }

enum VideoStorageMode { local, firestore }

enum BodyWeightMode { recent, avg7 }

enum HeightUnit { cm, inch }

class LiftVideo {
  final String liftId;      // stable key e.g., 'bench_barbell'
  final String? localPath;  // file path on device
  final String? remoteUrl;  // Firestore mode (future)
  final DateTime updatedAt;

  LiftVideo({
    required this.liftId,
    this.localPath,
    this.remoteUrl,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  bool get hasLocal => (localPath != null && localPath!.isNotEmpty);
  bool get hasRemote => (remoteUrl != null && remoteUrl!.isNotEmpty);

  Map<String, dynamic> toJson() => {
    'liftId': liftId,
    'localPath': localPath,
    'remoteUrl': remoteUrl,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static LiftVideo fromJson(Map<String, dynamic> j) => LiftVideo(
    liftId: j['liftId'] as String,
    localPath: j['localPath'] as String?,
    remoteUrl: j['remoteUrl'] as String?,
    updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
  );
}

class _InAppVideoPlayer extends StatefulWidget {
  final String videoPath;
  const _InAppVideoPlayer({required this.videoPath});

  @override
  State<_InAppVideoPlayer> createState() => _InAppVideoPlayerState();
}

class _InAppVideoPlayerState extends State<_InAppVideoPlayer> {
  late VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() => _ready = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lift Video')),
      body: Center(
        child: _ready
            ? AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: VideoPlayer(_controller),
        )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: _ready
          ? FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying
                ? _controller.pause()
                : _controller.play();
          });
        },
        child: Icon(
          _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
        ),
      )
          : null,
    );
  }
}



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

    // ✅ Choose font based on label
    final customStyle = (label.toLowerCase() == 'goodlift')
        ? GoogleFonts.monda(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
    )
        : GoogleFonts.monda(
      color: Colors.white,
      fontWeight: FontWeight.bold,
      fontSize: 14,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.blueGrey.withOpacity(0.35)),
      ),
      child: Text(
        '${(label.toLowerCase() == 'goodlift') ? label.toUpperCase() : label}: $text',
        style: customStyle,
      ),
    );
  }

}


class _ProfilePageState extends State<ProfilePage> {
  final _picker = ImagePicker();
  File? _localProfileImage;           // <-- use this one
  String? photoURL;
  String? _localProfilePath; // persisted path on device
  String? _currentUsername;

  // Bio
  final TextEditingController _bioController = TextEditingController();
  double squat = 0, bench = 0, deadlift = 0, chinUp = 0, unilateralPress = 0;
  bool isLoading = true;

  // UI layout
  static const double _rightColWidth = 185; // tweak to taste

  // Training Singles totals/toggle
  _CompMode _compMode = _CompMode.threeLift;
  double? _bestThreeLiftTotal; // kg
  double? _bestBenchOnly;      // kg
  Map<String, double> _bestSinglesFive = {};
  bool _moreStatsExpanded = false;


  // Best competition singles (kg)
  final _compSqCtrl = TextEditingController();
  final _compBpCtrl = TextEditingController();
  final _compDlCtrl = TextEditingController();

  //Body Metric bits
  double? _bwRecent;
  double? _bwAvg7;
  BodyWeightMode _bwMode = BodyWeightMode.recent;
  bool _bwPrivate = false; // local flag; persist later if you want
  bool _bwLoading = false;
  final TextEditingController _heightCtrl = TextEditingController();
  HeightUnit _heightUnit = HeightUnit.cm;
  double? _parseNum(String s) => double.tryParse(s.trim());
  double _cmToIn(double cm) => cm / 2.54;
  double _inToCm(double inch) => inch * 2.54;


  //Video bits
  // Toggleable later; default to local.
  VideoStorageMode _videoMode = VideoStorageMode.local;
// One entry per liftId.
  final Map<String, LiftVideo> _liftVideos = {};
// SharedPreferences key
  static const _kLiftVideosPrefsKey = 'lift_videos_map_v1';
  final ImagePicker _imagePicker = ImagePicker();
  // In-memory thumbnail cache (keyed by liftId)
  final Map<String, Uint8List?> _thumbCache = {};

// Inline (press&hold) players, one per tile as needed
  final Map<String, VideoPlayerController> _inlineControllers = {};
  String? _inlinePlayingLiftId;


  final List<Map<String, String>> _bestTrainingByE1RM = [
    {'id': 'bench_barbell', 'name': 'Bench Press, Barbell'},
    {'id': 'squat_barbell', 'name': 'Back Squat, Barbell'},
    {'id': 'deadlift_conv', 'name': 'Deadlift, Conventional'},
    {'id': 'chin_up', 'name': 'Chin-Up'},
    {'id': 'ohp_db_uni', 'name': 'Overhead Dumbbell Press, Unilateral'},
  ];

  final List<Map<String, String>> _bestSinglesTraining = [
    {'id': 'bench_barbell_single', 'name': 'Bench Press, Barbell'},
    {'id': 'squat_barbell_single', 'name': 'Back Squat, Barbell'},
    {'id': 'deadlift_conv_single', 'name': 'Deadlift, Conventional'},
    {'id': 'chin_up_single', 'name': 'Chin-Up'},
    {'id': 'ohp_db_uni_single', 'name': 'Overhead Dumbbell Press, Unilateral'},
  ];

  final List<Map<String, String>> _bestCompSingles = [
    {'id': 'squat_barbell_comp', 'name': 'Back Squat, Barbell'},
    {'id': 'bench_barbell_comp', 'name': 'Bench Press, Barbell'},
    {'id': 'deadlift_conv_comp', 'name': 'Deadlift, Conventional'},
  ];

  Widget _buildLiftVideoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _buildLiftVideoGroupGrid(
          title: 'Best Reps in Training (Highest E1RM)',
          lifts: _bestTrainingByE1RM,
        ),
        const SizedBox(height: 12),
        _buildLiftVideoGroupGrid(
          title: 'Best Singles in Training',
          lifts: _bestSinglesTraining,
        ),
        const SizedBox(height: 12),
        _buildLiftVideoGroupGrid(
          title: 'Best Comp Singles',
          lifts: _bestCompSingles,
        ),
      ],
    );
  }

  Widget _buildLiftVideoGroupGrid({
    required String title,
    required List<Map<String, String>> lifts,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            color: Colors.black.withOpacity(0.04),
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Monda',
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),

          // GRID: 3 per row, square tiles, no overflow; it expands to content height.
          GridView.builder(
            itemCount: lifts.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1, // square tiles
            ),
            itemBuilder: (_, i) {
              final liftId = lifts[i]['id']!;
              final fullName = lifts[i]['name']!;
              final shortName = _shortExerciseNames[fullName] ?? fullName;
              return _buildLiftVideoTile(liftId: liftId, liftName: shortName);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLiftVideoTile({
    required String liftId,
    required String liftName,
  }) {
    final entry = _liftVideos[liftId];
    final hasVideo = (entry?.hasLocal ?? false);
    final path = entry?.localPath;

    return GestureDetector(
      onTap: () {
        if (!hasVideo || path == null || !File(path).existsSync()) {
          _pickVideoForLift(liftId);
          return;
        }
        _playVideo(context, path);
      },
      onLongPress: () async {
        if (!hasVideo || path == null || !File(path).existsSync()) return;
        await _startInlinePlay(liftId, path);
      },
      onLongPressUp: () async {
        if (_inlinePlayingLiftId == liftId) {
          await _stopInlinePlay(liftId);
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.black.withOpacity(0.06),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ---- BACKGROUND (Video thumb if present) ----
              if (hasVideo && path != null && File(path).existsSync())
                FutureBuilder<Uint8List?>(
                  future: _getThumbFor(liftId, path),
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done || snap.data == null) {
                      return const Center(child: Icon(Icons.videocam));
                    }
                    return Image.memory(snap.data!, fit: BoxFit.cover);
                  },
                ),

              // ---- INLINE PLAYER (press & hold) ----
              if (_inlinePlayingLiftId == liftId &&
                  _inlineControllers[liftId]?.value.isInitialized == true)
                VideoPlayer(_inlineControllers[liftId]!),

              // ---- CENTER ICON (Upload or Play) ----
              Align(
                alignment: Alignment.center,
                child: Icon(
                  hasVideo ? Icons.play_circle_fill : Icons.file_upload,
                  size: 40,
                  color: Colors.white.withOpacity(0.65),
                ),
              ),

              // ---- BOTTOM NAME BAND (only when NO video yet) ----
              if (!hasVideo)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: const BoxDecoration(
                      // subtle gradient makes text readable without feeling heavy
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                    child: Text(
                      liftName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Monda',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),

              // ---- REPLACE / REMOVE (only when video exists) ----
              if (hasVideo)
              // Replace icon (further left)
                Positioned(
                  right: 62, // moves it left from the bin
                  top: 6,
                  child: _tinyCircleBtn(
                    Icons.swap_horiz,
                    tooltip: 'Replace',
                    onTap: () => _pickVideoForLift(liftId),
                  ),
                ),

// Bin icon (furthest right)
              Positioned(
                right: 2,
                top: 6,
                child: _tinyCircleBtn(
                  Icons.delete_outline,
                  tooltip: 'Remove',
                  onTap: () {
                    _removeVideoForLift(liftId);
                    _stopInlinePlay(liftId);
                  },
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }


  Widget _tinyCircleBtn(IconData icon,
      {required VoidCallback onTap, String? tooltip}) {
    final btn = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black54,
        ),
        child: Icon(icon, size: 16, color: Colors.white),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }


  Future<Uint8List?> _getThumbFor(String liftId, String videoPath) async {
    // Use cache first
    if (_thumbCache.containsKey(liftId)) return _thumbCache[liftId];

    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.PNG,
        maxWidth: 300, // keeps memory reasonable; grid is small
        quality: 70,
      );
      _thumbCache[liftId] = bytes;
      return bytes;
    } catch (_) {
      _thumbCache[liftId] = null;
      return null;
    }
  }

  Future<void> _startInlinePlay(String liftId, String videoPath) async {
    // Stop any other tile first
    if (_inlinePlayingLiftId != null && _inlinePlayingLiftId != liftId) {
      await _stopInlinePlay(_inlinePlayingLiftId!);
    }

    // If already built, just play
    if (_inlineControllers.containsKey(liftId)) {
      final c = _inlineControllers[liftId]!;
      await c.play();
      setState(() => _inlinePlayingLiftId = liftId);
      return;
    }

    final controller = VideoPlayerController.file(File(videoPath));
    _inlineControllers[liftId] = controller;
    await controller.initialize();
    controller.setLooping(true);
    controller.setVolume(0); // muted
    await controller.play();

    setState(() => _inlinePlayingLiftId = liftId);
  }

  Future<void> _stopInlinePlay(String liftId) async {
    final c = _inlineControllers[liftId];
    if (c != null) {
      await c.pause();
      await c.dispose();
      _inlineControllers.remove(liftId);
    }
    if (_inlinePlayingLiftId == liftId) {
      setState(() => _inlinePlayingLiftId = null);
    }
  }

  Future<void> _loadLiftVideosFromLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLiftVideosPrefsKey);
    if (raw == null) return;

    try {
      final decoded = (jsonDecode(raw) as Map<String, dynamic>);
      decoded.forEach((liftId, obj) {
        _liftVideos[liftId] = LiftVideo.fromJson(Map<String, dynamic>.from(obj));
      });
      if (mounted) setState(() {});
    } catch (_) {
      // Ignore corrupt; you could add logging
    }
  }

  Future<void> _saveLiftVideosToLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _liftVideos.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_kLiftVideosPrefsKey, jsonEncode(map));
  }

  Future<void> _pickVideoForLift(String liftId) async {
    if (_videoMode != VideoStorageMode.local) {
      // Future: route to Firestore upload flow
      return;
    }

    // 👉 This opens the device's Gallery-style picker
    final XFile? picked = await _imagePicker.pickVideo(
      source: ImageSource.gallery,
      // optional: cap duration shown/recorded
      // maxDuration: const Duration(minutes: 5),
    );

    if (picked == null) return; // user canceled

    final path = picked.path;

    setState(() {
      _liftVideos[liftId] = LiftVideo(
        liftId: liftId,
        localPath: path,
        remoteUrl: null,
        updatedAt: DateTime.now(),
      );
    });

    await _saveLiftVideosToLocal();
  }

  void _removeVideoForLift(String liftId) {
    setState(() {
      _liftVideos.remove(liftId);
    });
    _saveLiftVideosToLocal();
  }

  void _playVideo(BuildContext context, String path) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _InAppVideoPlayer(videoPath: path),
      ),
    );
  }
  //Video bits end






  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _loadLocalProfileImage();
    _loadPhotoURL();
    _refreshBestLiftsAndPoints(); // NEW
    _loadCurrentUsername();
    _loadCompSingles();
    _loadLiftVideosFromLocal(); // local-only for now
    _loadBodyWeightForSelectedUser();
  }

  @override
  void dispose() {
    _saveCompSingles();
    _compSqCtrl.dispose();
    _compBpCtrl.dispose();
    _compDlCtrl.dispose();
    _saveLiftVideosToLocal(); // persist on page exit
    _heightCtrl.dispose();

    for (final c in _inlineControllers.values) {
      c.dispose();
    }
    _inlineControllers.clear();
    super.dispose();
  }


  Widget _chipButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadCurrentUsername() async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    if (uid == null) return;

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (userDoc.exists) {
      final data = userDoc.data();
      setState(() {
        _currentUsername = data?['username'] ?? data?['displayName'] ?? 'No username';
      });
    }
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

  Future<void> _pickAndUploadProfileImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    final tempFile = File(picked.path);
    final appDir = await getApplicationDocumentsDirectory();
    final destPath = '${appDir.path}/profile.jpg';

    // Overwrite the old file (delete first to be explicit)
    try { await File(destPath).delete(); } catch (_) {}
    await tempFile.copy(destPath);

    // ⚠️ Evict old cached image for this path
    final provider = FileImage(File(destPath));
    await provider.evict();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_local_path', destPath);

    if (!mounted) return;
    setState(() {
      _localProfilePath = destPath;
      _localProfileImage = File(destPath);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile photo updated (local only)')),
    );
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

  Future<void> _loadCompSingles() async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    if (uid == null) return;

    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = snap.data();
    final comp = (data?['compSingles'] as Map<String, dynamic>?) ?? {};

    String _fmt(dynamic v) {
      final d = (v is num) ? v.toDouble() : double.tryParse('$v');
      return (d != null && d > 0) ? d.toStringAsFixed(1) : '';
    }

    setState(() {
      _compSqCtrl.text = _fmt(comp['squatKg']);
      _compBpCtrl.text = _fmt(comp['benchKg']);
      _compDlCtrl.text = _fmt(comp['deadliftKg']);
    });
  }

  Future<void> _saveCompSingles() async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    if (uid == null) return;

    double? _parse(TextEditingController c) {
      final t = c.text.trim();
      if (t.isEmpty) return null;
      return double.tryParse(t);
    }

    final squat = _parse(_compSqCtrl);
    final bench = _parse(_compBpCtrl);
    final dead  = _parse(_compDlCtrl);

    final payload = {
      'compSingles': {
        if (squat != null) 'squatKg': squat,
        if (bench != null) 'benchKg': bench,
        if (dead  != null) 'deadliftKg': dead,
      }
    };

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .set(payload, SetOptions(merge: true));
  }

  //Body metric functions
  Future<void> _loadBodyWeightForSelectedUser() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    setState(() => _bwLoading = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true) // <-- matches your field
          .limit(60) // grab a decent window
          .get();

      if (snap.docs.isEmpty) {
        setState(() {
          _bwRecent = null;
          _bwAvg7 = null;
          _bwLoading = false;
        });
        return;
      }

      double? recent;
      double sum = 0.0;
      int count = 0;

// Helper: strip time → date-only (local)
      DateTime _toDateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

      final today = _toDateOnly(DateTime.now());
// Inclusive window: today, today-1, ..., today-6  (7 calendar days)
      bool _isInLast7Days(DateTime dt) {
        final d = _toDateOnly(dt);
        final diff = today.difference(d).inDays; // 0=today, 1=yesterday, ...
        return diff >= 0 && diff <= 6;
      }

      for (final d in snap.docs) {
        final data = d.data();

        final w = (data['weight'] as num?)?.toDouble();
        if (w == null) continue;

        DateTime? dt;
        final ts = data['timestamp'];
        if (ts is Timestamp) dt = ts.toDate();
        if (ts is DateTime) dt = ts;
        dt ??= (data['date'] is Timestamp) ? (data['date'] as Timestamp).toDate() : null;
        if (dt == null) continue;

        // First valid entry (already ordered desc) → most recent
        recent ??= w;

        if (_isInLast7Days(dt)) {
          sum += w;
          count += 1;
        }
      }

      final avg7 = (count > 0) ? (sum / count) : null;

      setState(() {
        _bwRecent = recent;
        _bwAvg7  = avg7 ?? recent; // still falls back, but should now compute
        _bwLoading = false;
      });

    } catch (e) {
      setState(() => _bwLoading = false);
      // Optional: print for debug
      // print('❌ _loadBodyWeightForSelectedUser error: $e');
    }
  }

  void _toggleHeightUnit(HeightUnit to) {
    if (_heightUnit == to) return;

    final currentText = _heightCtrl.text.trim();
    double? currentValueInches;

    if (_heightUnit == HeightUnit.cm) {
      // Convert cm → inches first
      final cmValue = double.tryParse(currentText);
      if (cmValue != null) {
        currentValueInches = _cmToIn(cmValue);
      }
    } else {
      // Currently in inches/feet mode → parse it into inches
      currentValueInches = _feetInchesStringToInches(currentText);
    }

    if (to == HeightUnit.cm && currentValueInches != null) {
      // Inches → cm
      _heightCtrl.text = _inToCm(currentValueInches).toStringAsFixed(2);
    } else if (to == HeightUnit.inch && currentValueInches != null) {
      // Inches → ft'in"
      _heightCtrl.text = _inchToFeetInchesString(currentValueInches);
    }

    setState(() => _heightUnit = to);
  }


  String _inchToFeetInchesString(double inches) {
    final feet = inches ~/ 12; // integer division
    final remainingInches = inches % 12;
    return "$feet'${remainingInches.toStringAsFixed(1)}\"";
  }

  double? _feetInchesStringToInches(String input) {
    // Normalize spaces and smart quotes
    var cleaned = input.trim()
        .replaceAll('′', "'")
        .replaceAll('″', '"')
        .replaceAll('’', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"');

    // Remove internal spaces for simple patterns like 5' 8"
    cleaned = cleaned.replaceAll(' ', '');

    // 1) Match feet + inches (inches may have decimals, trailing " optional)
    final reFeetIn = RegExp(r'''^(\d+)'(\d+(?:\.\d+)?)"?$''');
    final m1 = reFeetIn.firstMatch(cleaned);
    if (m1 != null) {
      final feet = double.tryParse(m1.group(1)!) ?? 0;
      final inch = double.tryParse(m1.group(2)!) ?? 0;
      return feet * 12 + inch;
    }

    // 2) Feet only like 5'  → treat as 5 * 12 inches
    final reFeetOnly = RegExp(r'''^(\d+)'$''');
    final m2 = reFeetOnly.firstMatch(cleaned);
    if (m2 != null) {
      final feet = double.tryParse(m2.group(1)!) ?? 0;
      return feet * 12;
    }

    // 3) Plain number → treat as total inches (e.g., "68" or "68.5")
    final asNumber = double.tryParse(cleaned);
    if (asNumber != null) return asNumber;

    return null; // couldn't parse
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
    'Overhead Dumbbell Press, Unilateral': 'DB Shoulder Press, Uni',
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

    // Canonical exercise names
    const squatName = 'Back Squat, Barbell';
    const benchName = 'Bench Press, Barbell';
    const deadName  = 'Deadlift, Conventional';
    const chinName  = 'Chin-Up';
    const ohpUni    = 'Overhead Dumbbell Press, Unilateral';

    // Track best single (1 rep) and best-any (fallback) for ALL 5
    final Map<String, double> bestSingle = {
      squatName: 0, benchName: 0, deadName: 0, chinName: 0, ohpUni: 0,
    };
    final Map<String, double> bestAny = {
      squatName: 0, benchName: 0, deadName: 0, chinName: 0, ohpUni: 0,
    };

    // Helper: only care about these 5
    bool isTracked(String n) => bestSingle.containsKey(n);

    for (final doc in snaps.docs) {
      final data = doc.data();
      final exercises = (data['exercises'] is List)
          ? List<Map<String, dynamic>>.from(data['exercises'] as List)
          : const <Map<String, dynamic>>[];

      for (final ex in exercises) {
        final name = _canonical((ex['name'] as String?)?.trim() ?? '');
        if (!isTracked(name)) continue;

        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'] as List)
            : const <Map<String, dynamic>>[];

        for (final s in sets) {
          final w = (s['weight'] is num) ? (s['weight'] as num).toDouble() : 0.0;

          final rRaw = s['reps'];
          final r = (rRaw is num) ? rRaw.toInt() : int.tryParse('$rRaw') ?? 0;

          if (w <= 0) continue;

          // Best single (exactly 1 rep)
          if (r == 1 && w > (bestSingle[name] ?? 0)) {
            bestSingle[name] = w;
          }
          // Heaviest weight seen (any reps) as fallback
          if (w > (bestAny[name] ?? 0)) {
            bestAny[name] = w;
          }
        }
      }
    }

    // Resolve each lift's best: prefer single, else fallback
    double bestOrFallback(String n) =>
        (bestSingle[n] ?? 0) > 0 ? (bestSingle[n] ?? 0) : (bestAny[n] ?? 0);

    final squatBest = bestOrFallback(squatName);
    final benchBest = bestOrFallback(benchName);
    final deadBest  = bestOrFallback(deadName);
    final chinBest  = bestOrFallback(chinName);
    final ohpBest   = bestOrFallback(ohpUni);

    // Totals (unchanged)
    final threeLift = squatBest + benchBest + deadBest;
    final benchOnly = benchBest;

    if (!mounted) return;
    setState(() {
      _bestThreeLiftTotal = (threeLift > 0) ? threeLift : null;
      _bestBenchOnly      = (benchOnly > 0) ? benchOnly : null;

      // Expose best singles for all 5 to the UI
      _bestSinglesFive = {
        squatName: squatBest,
        benchName: benchBest,
        deadName : deadBest,
        chinName : chinBest,
        ohpUni   : ohpBest,
      };
    });

    debugPrint('🏆 Totals → 3-Lift=$_bestThreeLiftTotal, BenchOnly=$_bestBenchOnly');
    debugPrint('💪 Best singles → '
        'SQ=$squatBest, BP=$benchBest, DL=$deadBest, CH=$chinBest, OHPu=$ohpBest');
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

  Widget _buildMoreStatsCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.blueGrey.withOpacity(0.10),
      ),
      child: Column(
        children: [
          // Header row (tap to expand/collapse)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _moreStatsExpanded = !_moreStatsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'More Stats:',
                      style: GoogleFonts.monda(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    turns: _moreStatsExpanded ? 0.5 : 0.0, // chevron flips
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),

          // Collapsible content
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _moreStatsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  // --- Goodlift Points In Comp ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Goodlift Points In Comp',
                            style: GoogleFonts.monda(
                              fontSize: Theme.of(context).textTheme.bodyLarge?.fontSize ?? 14,
                              fontWeight: Theme.of(context).textTheme.bodyLarge?.fontWeight,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: const Text(
                              '(pending calc)',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- RE Points ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'RE Points (Singles)',
                            style: GoogleFonts.monda(
                              fontSize: Theme.of(context).textTheme.bodyLarge?.fontSize ?? 14,
                              fontWeight: Theme.of(context).textTheme.bodyLarge?.fontWeight,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: const Text(
                              '(pending calc)',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // --- Best Comp Singles (header) ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Best Comp Singles:',
                          style: GoogleFonts.monda(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),

                  // --- Squat ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Back Squat',
                            style: GoogleFonts.monda(fontSize: 16),
                          ),
                        ),
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _compSqCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                              ],
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: 'kg',
                                hintStyle: TextStyle(color: Colors.white70),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- Bench ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Bench Press',
                            style: GoogleFonts.monda(fontSize: 16),
                          ),
                        ),
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _compBpCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                              ],
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: 'kg',
                                hintStyle: TextStyle(color: Colors.white70),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- Deadlift ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Deadlift',
                            style: GoogleFonts.monda(fontSize: 16),
                          ),
                        ),
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _compDlCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                              ],
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: 'kg',
                                hintStyle: TextStyle(color: Colors.white70),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Body Metrics',
                          style: GoogleFonts.monda(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),


                  // --- Current Body Weight ---
                  // --- Current Body Weight (label w/ privacy under it; chip w/ mode toggle under) ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // LEFT: label + privacy under it
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Body Weight', style: GoogleFonts.monda(fontSize: 16)),
                              const SizedBox(height: 4),
                              // tiny privacy toggle (under label)
                              InkWell(
                                onTap: () => setState(() => _bwPrivate = !_bwPrivate),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _bwPrivate
                                        ? Colors.blueGrey.withOpacity(0.25)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _bwPrivate ? Icons.lock : Icons.lock_open,
                                        size: 14,
                                        color: Colors.blueGrey,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _bwPrivate ? 'Private' : 'Public',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // RIGHT: chip (value) + mode toggle under it, aligned to chip width
                        SizedBox(
                          width: _rightColWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.blueGrey,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.centerLeft,
                                child: _bwLoading
                                    ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                                    : Text(
                                  (() {
                                    final v = (_bwMode == BodyWeightMode.recent) ? _bwRecent : _bwAvg7;
                                    if (v == null) return '(no data)';
                                    return '${v.toStringAsFixed(1)} kg';
                                  })(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(height: 6),
                              // mode toggle under the chip (aligned)
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.blueGrey.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: ToggleButtons(
                                        constraints: const BoxConstraints(minHeight: 28),
                                        borderRadius: BorderRadius.circular(999),
                                        isSelected: [
                                          _bwMode == BodyWeightMode.recent,
                                          _bwMode == BodyWeightMode.avg7,
                                        ],
                                        onPressed: (i) {
                                          setState(() => _bwMode = (i == 0)
                                              ? BodyWeightMode.recent
                                              : BodyWeightMode.avg7);
                                        },
                                        children: const [
                                          Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 8),
                                            child: Text('Most Recent'),
                                          ),
                                          Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 8),
                                            child: Text('7-Day Avg'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- Height ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // LEFT: label + cm/in toggle under it (compact)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Height', style: GoogleFonts.monda(fontSize: 16)),
                              const SizedBox(height: 4),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.blueGrey.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: ToggleButtons(
                                  constraints: const BoxConstraints(minHeight: 26, minWidth: 56),
                                  borderRadius: BorderRadius.circular(999),
                                  isSelected: [
                                    _heightUnit == HeightUnit.cm,
                                    _heightUnit == HeightUnit.inch,
                                  ],
                                  onPressed: (i) =>
                                      _toggleHeightUnit(i == 0 ? HeightUnit.cm : HeightUnit.inch),
                                  children: const [
                                    Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 8),
                                      child: Text('cm'),
                                    ),
                                    Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 8),
                                      child: Text('in'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // RIGHT: input chip (same look as Deadlift)
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _heightCtrl,
                              keyboardType: TextInputType.text,
                              inputFormatters: _heightUnit == HeightUnit.cm
                                  ? [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))]
                                  : [], // no strict filter in inch mode, we parse it ourselves
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: _heightUnit == HeightUnit.cm ? 'cm' : 'ft\'in"',
                                hintStyle: const TextStyle(color: Colors.white70),
                                border: InputBorder.none,
                              ),
                            ),

                          ),
                        ),
                      ],
                    ),
                  ),



                ],
              ),
            ),
          ),
        ],
      ),
    );
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

    return WillPopScope(
      onWillPop: () async {
        await _saveCompSingles();
        return true; // allow navigation
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.blueGrey,
          automaticallyImplyLeading: false, // disable default
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              await _saveCompSingles();      // ✅ ensure save on custom back
              if (context.mounted) Navigator.pop(context);
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
                  child: Builder(
                    builder: (context) {
                      final actingUid = Provider.of<UserContext>(context, listen: true).actingAsUid;
                      if (actingUid == null) {
                        return const Text('Unknown',
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }

                      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance.collection('users').doc(actingUid).snapshots(),
                        builder: (context, snap) {
                          final data = snap.data?.data();
                          String? pick(dynamic v) {
                            final s = (v ?? '').toString().trim();
                            return s.isEmpty ? null : s;
                          }
                          final label = pick(data?['username']) ??
                              pick(data?['displayName']) ??
                              pick(data?['email']) ??
                              'Unknown';

                          return Text(
                            label,
                            maxLines: 1,
                            //style: GoogleFonts.rajdhani(
                            style: GoogleFonts.rajdhani(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          );
                        },
                      );
                    },
                  ),
                )

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
                // Avatar + Username Column
                Column(
                  mainAxisSize: MainAxisSize.min,
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

                    const SizedBox(height: 6),

                    // Username display + edit
                    InkWell(
                      onTap: () async {
                        final newName = await showDialog<String>(
                          context: context,
                          builder: (ctx) {
                            final ctrl = TextEditingController(text: _currentUsername);
                            return AlertDialog(
                              title: const Text('Update Username'),
                              content: TextField(
                                controller: ctrl,
                                decoration: const InputDecoration(labelText: 'New Username'),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                                  child: const Text('Save'),
                                ),
                              ],
                            );
                          },
                        );

                        if (newName != null && newName.isNotEmpty && newName != _currentUsername) {
                          await FirebaseFirestore.instance
                              .collection('users')
                              .doc(Provider.of<UserContext>(context, listen: false).actingAsUid)
                              .set({
                            'username': newName,
                            'usernameLower': newName.toLowerCase(),
                          }, SetOptions(merge: true));

                          setState(() => _currentUsername = newName);
                        }
                      },
                      child: Text(
                        _currentUsername ?? 'No username',
                        style: GoogleFonts.monda(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(width: 16),

                // Points chips & other stats stay as before
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatChip(label: 'Goodlift', value: _goodliftPoints),
                      const SizedBox(height: 8),
                      _StatChip(label: 'RE Points', value: _rePoints),
                      const SizedBox(height: 8),
                      _StatChip(
                        label: 'Best Comp Total',
                        value: _compMode == _CompMode.threeLift
                            ? _bestThreeLiftTotal
                            : _bestBenchOnly,
                      ),
                      const SizedBox(height: 4),
                      ToggleButtons(
                        isSelected: [
                          _compMode == _CompMode.threeLift,
                          _compMode == _CompMode.benchOnly,
                        ],
                        onPressed: (idx) {
                          setState(() {
                            _compMode = (idx == 0) ? _CompMode.threeLift : _CompMode.benchOnly;
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
            const Text('Bio',
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
                Expanded(
                  child: Text(
                    'Best Lifts In Training - Off E1RM',
                    style: GoogleFonts.monda(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
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
                            style: GoogleFonts.monda(
                              fontSize: 16,
                            ),
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


            const SizedBox(height: 10),
            // Stats




            const SizedBox(height: 6),
            Text(
              'Best singles In Training:',
              style: GoogleFonts.monda(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.blueGrey.withOpacity(0.10),
              ),
              child: Column(
                children: _displayExercises.map((name) {
                  final best = _bestSinglesFive[name] ?? 0.0;
                  final rightText = (best > 0) ? '${best.toStringAsFixed(1)} ' : '—';

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        // Left: exercise name
                        Expanded(
                          child: Text(
                            _shortExerciseNames[name] ?? name,
                            style: GoogleFonts.monda(
                              fontSize: 16,
                            ),
                          ),
                        ),

                        // Right: weight × 1 in a blue-grey chip
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              rightText,
                              style: const TextStyle(
                                color: Colors.white,
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

            const SizedBox(height: 8),
            // ⬇️ Drop-in replacement
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0),
              child: _buildMoreStatsCard(),
            ),



            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveProfileData,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
              child: const Text('Save Profile'),
            ),

            const SizedBox(height: 12),

// 👇 NEW: Videos section goes here (keeps your page styling/alignment)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _buildLiftVideoSection(),
            ),

            const SizedBox(height: 60),
          ],
        ),


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
