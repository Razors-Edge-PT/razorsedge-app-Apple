// Dart SDK
import 'dart:async';          // for unawaited, Futures
import 'dart:convert';        // if you use jsonEncode/Decode for prefs
import 'dart:io';             // File, Platform
import 'dart:typed_data';     // Uint8List

// Flutter
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';          // if you use SystemChrome/Clipboard/etc.
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

// Firebase
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

// Media / cache
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// Local storage / utils
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart'; // only if used

// Project-local
import 'user_context.dart';
import 'periodization_model_utils.dart';
import 'formula.dart' as formula;
import 'stats_snapshot.dart' as stats;




enum _CompMode { threeLift, benchOnly }

enum VideoStorageMode { local, firestore }

enum BodyWeightMode { recent, avg7 }

enum HeightUnit { cm, inch }

enum BodyWeightUnit { kg, lb }

class LiftVideo {
  final String liftId;      // stable key e.g., 'bench_barbell'
  final String? localPath;  // file path on device
  final String? remoteUrl;  // Firestore mode (future)
  final String? thumbUrl;   // ✅ thumbnail image URL from Storage
  final DateTime updatedAt;

  LiftVideo({
    required this.liftId,
    this.localPath,
    this.remoteUrl,
    this.thumbUrl,          // ✅ new optional field
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  bool get hasLocal => (localPath != null && localPath!.isNotEmpty);
  bool get hasRemote => (remoteUrl != null && remoteUrl!.isNotEmpty);
  bool get hasThumb => (thumbUrl != null && thumbUrl!.isNotEmpty); // ✅ convenience

  Map<String, dynamic> toJson() => {
    'liftId': liftId,
    'localPath': localPath,
    'remoteUrl': remoteUrl,
    'thumbUrl': thumbUrl, // ✅ include in JSON
    'updatedAt': updatedAt.toIso8601String(),
  };

  static LiftVideo fromJson(Map<String, dynamic> j) => LiftVideo(
    liftId: j['liftId'] as String,
    localPath: j['localPath'] as String?,
    remoteUrl: j['remoteUrl'] as String?,
    thumbUrl: j['thumbUrl'] as String?, // ✅ parse from JSON
    updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
  );
}

class _PostDetailPage extends StatelessWidget {
  final Post post;
  final Future<void> Function(Post) onToggleLike;
  final Future<void> Function(Post) onToggleGoodLift;
  final Future<void> Function(Post, String) onAddComment;
  final bool canDelete;

  const _PostDetailPage({
    super.key,
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
    required this.canDelete,
  });



  @override
  Widget build(BuildContext context) {
    // For brevity: simple viewer + action row with counts.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        actions: [
          if (canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Delete post?'),
                    content: const Text('This will remove the post and its media.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (confirm != true) return;

                // Delete post doc(s)
                await FirebaseFirestore.instance.collection('posts').doc(post.id).delete();

                // Also try to delete mirrored user doc if you added one (safe to keep even if you didn't):
                try {
                  await FirebaseFirestore.instance
                      .collection('users').doc(post.ownerUid)
                      .collection('posts').doc(post.id).delete();
                } catch (_) {}

                // Delete Storage folder
                final ref = FirebaseStorage.instance.ref('users/${post.ownerUid}/posts/${post.id}');
                try {
                  final list = await ref.listAll();
                  for (final i in list.items) { await i.delete(); }
                } catch (_) {}

                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],

      ),
      body: Column(
        children: [
          Expanded(
            child: (post.mediaType == 'image')
                ? FutureBuilder<File>(
              future: DefaultCacheManager().getSingleFile(post.smallUrl),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.done && snap.hasData) {
                  return Center(child: Image.file(snap.data!, fit: BoxFit.contain));
                }
                return const Center(child: CircularProgressIndicator());
              },
            )
                : FutureBuilder<String>(
              future: post.storagePathOriginal.isNotEmpty
                  ? FirebaseStorage.instance.ref(post.storagePathOriginal).getDownloadURL()
                  : Future<String>.value(''),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final url = (snap.data ?? '').trim();
                if (url.isEmpty) {
                  return const Center(child: Text('Video unavailable'));
                }
                return _InAppVideoPlayer.networkUrl(url: url);
              },
            ),
          ),

          // --- Simple comments list (last 20) ---
          SizedBox(
            height: 160,
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('posts').doc(post.id)
                  .collection('comments')
                  .orderBy('createdAt', descending: true)
                  .limit(20)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(child: Text('No comments yet'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  reverse: false,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final d = docs[i].data();
                    final text = (d['text'] ?? '') as String;
                    final uid = (d['uid'] ?? '') as String;
                    final storedName = (d['username'] as String?)?.trim();

// If the comment doc already has a username, use it.
// Otherwise, do a one-off lookup to users_public and cache via the ListView.
                    if (storedName != null && storedName.isNotEmpty) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.person_outline, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$storedName: $text',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      );
                    } else {
                      return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        future: FirebaseFirestore.instance
                            .collection('users_public')
                            .doc(uid)
                            .get(),
                        builder: (ctx, snapUser) {
                          String display = uid; // fallback

                          if (snapUser.hasData) {
                            final map = snapUser.data!.data(); // Map<String, dynamic>?
                            if (map != null) {
                              final u = map['username'];
                              final dn = map['displayName'];
                              if (u is String && u.trim().isNotEmpty) {
                                display = u.trim();
                              } else if (dn is String && dn.trim().isNotEmpty) {
                                display = dn.trim();
                              }
                            }
                          }

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.person_outline, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '$display: $text',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          );
                        },
                      );

                    }

                  },
                );
              },
            ),
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: _PostActionsBar(
                post: post,
                onToggleLike: onToggleLike,
                onToggleGoodLift: onToggleGoodLift,
                onAddComment: onAddComment,
              ),

            ),
          ],
        ),
      ),

    );
  }
}

class _PostActionsBar extends StatefulWidget {
  final Post post;
  final Future<void> Function(Post) onToggleLike;
  final Future<void> Function(Post) onToggleGoodLift;
  final Future<void> Function(Post, String) onAddComment;

  const _PostActionsBar({
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
  });

  @override
  State<_PostActionsBar> createState() => _PostActionsBarState();
}

class _PostActionsBarState extends State<_PostActionsBar> {
  bool _liking = false;
  bool _glifting = false;
  bool _commenting = false;

  Future<void> _promptAndComment() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add comment'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Write a comment...'),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Post')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    setState(() => _commenting = true);
    try {
      await widget.onAddComment(widget.post, text.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Comment failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _commenting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live counts from the post doc
    final postStream = FirebaseFirestore.instance.collection('posts').doc(widget.post.id).snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: postStream,
      builder: (context, snap) {
        int likeCount = widget.post.likeCount;
        int goodLiftCount = widget.post.goodLiftCount;
        int commentCount = widget.post.commentCount;

        if (snap.hasData && snap.data!.data() != null) {
          final d = snap.data!.data()!;
          likeCount = (d['likeCount'] as num?)?.toInt() ?? likeCount;
          goodLiftCount = (d['goodLiftCount'] as num?)?.toInt() ?? goodLiftCount;
          commentCount = (d['commentCount'] as num?)?.toInt() ?? commentCount;
        }

        return Row(
          children: [
            // Like
            IconButton(
              tooltip: 'Like',
              onPressed: _liking
                  ? null
                  : () async {
                setState(() => _liking = true);
                try {
                  await widget.onToggleLike(widget.post);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Like failed: $e')),
                    );
                  }
                } finally {
                  if (mounted) setState(() => _liking = false);
                }
              },
              icon: const Icon(Icons.thumb_up_alt_outlined),
            ),
            Text('$likeCount'),

            const SizedBox(width: 16),

            // Good Lift (videos only)
            if (widget.post.mediaType == 'video') ...[
              IconButton(
                tooltip: 'Good lift',
                onPressed: _glifting
                    ? null
                    : () async {
                  setState(() => _glifting = true);
                  try {
                    await widget.onToggleGoodLift(widget.post);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Good lift failed: $e')),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => _glifting = false);
                  }
                },
                icon: const Icon(Icons.check_circle_outline),
              ),
              Text('$goodLiftCount'),
              const SizedBox(width: 16),
            ],

            // Comments
            IconButton(
              tooltip: 'Comment',
              onPressed: _commenting ? null : _promptAndComment,
              icon: const Icon(Icons.mode_comment_outlined),
            ),
            Text('$commentCount'),

            const Spacer(),
          ],
        );
      },
    );
  }
}








class _InAppVideoPlayer extends StatefulWidget {
  final String source;
  final bool isNetwork;

  const _InAppVideoPlayer.file({required String path})
      : source = path,
        isNetwork = false;

  const _InAppVideoPlayer.networkUrl({required String url})
      : source = url,
        isNetwork = true;

  @override
  State<_InAppVideoPlayer> createState() => _InAppVideoPlayerState();
}


class _InAppVideoPlayerState extends State<_InAppVideoPlayer> {
  late VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.isNetwork
        ? VideoPlayerController.networkUrl(Uri.parse(widget.source))
        : VideoPlayerController.file(File(widget.source));

    _controller.initialize().then((_) {
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

// ===== Profile Posts (grid) =====
class Post {
  final String id;
  final String ownerUid;
  final String mediaType; // "image" | "video"
  final String storagePathOriginal; // path in Storage
  final String smallUrl;
  final String thumbUrl;
  final String? caption;
  final int likeCount;
  final int goodLiftCount;
  final int commentCount;
  final Timestamp createdAt;

  Post({
    required this.id,
    required this.ownerUid,
    required this.mediaType,
    required this.storagePathOriginal,
    required this.smallUrl,
    required this.thumbUrl,
    required this.caption,
    required this.likeCount,
    required this.goodLiftCount,
    required this.commentCount,
    required this.createdAt,
  });

  static Post fromSnap(DocumentSnapshot<Map<String, dynamic>> s) {
    final d = s.data()!;
    return Post(
      id: s.id,
      ownerUid: (d['ownerUid'] ?? '') as String,
      mediaType: (d['mediaType'] ?? 'image') as String,
      storagePathOriginal: (d['storagePathOriginal'] ?? '') as String,
      smallUrl: (d['smallUrl'] ?? '') as String,
      thumbUrl: (d['thumbUrl'] ?? '') as String,
      caption: (d['caption'] as String?),
      likeCount: (d['likeCount'] as num?)?.toInt() ?? 0,
      goodLiftCount: (d['goodLiftCount'] as num?)?.toInt() ?? 0,
      commentCount: (d['commentCount'] as num?)?.toInt() ?? 0,
      createdAt: (d['createdAt'] as Timestamp?) ?? Timestamp.now(),
    );
  }
}



class ProfilePage extends StatefulWidget {
  final String? viewedUid;   // whose profile to show; null => self
  final bool readOnly;       // lock editing UI

  const ProfilePage({
    super.key,
    this.viewedUid,
    this.readOnly = false,
  });

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
  bool _metricsPrivate = false;   // master toggle for Body Metrics
  bool _bwPrivate = false; // local flag; persist later if you want
  bool _bwLoading = false;
  final TextEditingController _heightCtrl = TextEditingController();

  HeightUnit _heightUnit = HeightUnit.cm;
  double? _parseNum(String s) => double.tryParse(s.trim());
  double _cmToIn(double cm) => cm / 2.54;
  double _inToCm(double inch) => inch * 2.54;

  BodyWeightUnit _bwUnit = BodyWeightUnit.kg;
  double _kgToLbs(double kg) => kg * 2.20462;
  double _lbsToKg(double lbs) => lbs / 2.20462;

  //view only bits, for friends
  VoidCallback? _ucListener;
  String? _targetUid;           // resolved in initState
  bool _readOnlyView = false;   // resolved in initState

  bool get _isSelf {
    final self = UserContext.of(context, listen: false).actorUid;
    return (_targetUid != null && _targetUid == self);
  }
  /// Coaches acting-as the selected athlete should be able to upload.
  /// Friends (readOnly route) should not.
  bool get _canUploadForOwner {
    final uc = UserContext.of(context, listen: false);
    final owner = _targetUid;
    if (owner == null) return false;
    // If you're actively viewing an athlete because currentUid==owner,
    // treat it as "acting-as" and allow uploads.
    final actingAs = uc.currentUid ?? uc.actingAsUid;
    return actingAs != null && actingAs == owner;
  }


  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _publicSub;
  String? _subscribedUid; // for debugging

  String get _ownerUid => _targetUid ?? FirebaseAuth.instance.currentUser!.uid;

// view only bits ends


  //Video bits
  // Toggleable later; default to local.
  VideoStorageMode _videoMode = VideoStorageMode.firestore;
  static const _kProfilePhotoPrefsKeyPrefix = 'profile_local_path_'; // per user

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

  // Posts grid state
  final List<Post> _posts = [];
  DocumentSnapshot<Map<String, dynamic>>? _lastPostSnap;
  bool _loadingPosts = false;
  bool _hasMorePosts = true;


  String _folderForLift(String liftId) {
    if (_bestTrainingByE1RM.any((e) => e['id'] == liftId)) {
      return 'videos/best-e1rm-training';
    }
    if (_bestSinglesTraining.any((e) => e['id'] == liftId)) {
      return 'videos/best-singles-training';
    }
    if (_bestCompSingles.any((e) => e['id'] == liftId)) {
      return 'videos/best-comp-lifts';
    }
    // Fallback (shouldn’t happen with your lists)
    return 'videos/misc';
  }

  Future<Map<String, String>> _uploadVideoAndThumb({
    required String liftId,
    required String localVideoPath,
  }) async {
    final ownerUid = _targetUid ?? FirebaseAuth.instance.currentUser!.uid;

    // Unified paths:
    //   users/{uid}/liftVideos/{liftId}.mp4
    //   users/{uid}/liftVideos/{liftId}_thumb.jpg
    final baseRef  = FirebaseStorage.instance.ref().child('users/$ownerUid/liftVideos');
    final videoRef = baseRef.child('$liftId.mp4');
    final thumbRef = baseRef.child('${liftId}_thumb.jpg');

    // Upload video (assume mp4 from gallery)
    await videoRef.putFile(
      File(localVideoPath),
      SettableMetadata(contentType: 'video/mp4'),
    );
    final videoUrl = await videoRef.getDownloadURL();

    // Generate and upload thumbnail
    final thumbBytes = await VideoThumbnail.thumbnailData(
      video: localVideoPath,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 400,
      quality: 70,
    );

    String thumbUrl = '';
    if (thumbBytes != null) {
      await thumbRef.putData(
        thumbBytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      thumbUrl = await thumbRef.getDownloadURL();
    }

    return {
      'videoUrl': videoUrl,
      'thumbUrl': thumbUrl,
    };
  }




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

  Widget _buildPostsSection() {
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
          // Header row
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Posts',
                  style: TextStyle(
                    fontFamily: 'Monda',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_canUploadForOwner)
                TextButton.icon(
                  onPressed: _pickAndUploadPost,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Post'),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Grid or placeholder
          if (_posts.isEmpty)
            (_loadingPosts)
                ? const Center(child: CircularProgressIndicator())
                : Column(
              children: [
                const SizedBox(height: 12),
                const Center(
                  child: Text(
                    'Nothing to show yet',
                    style: TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                ),
                if (_canUploadForOwner)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton.icon(
                      onPressed: _pickAndUploadPost,
                      icon: const Icon(Icons.add),
                      label: const Text('Add your first post'),
                    ),
                  ),
              ],
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _posts.length + (_hasMorePosts ? 1 : 0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, index) {
                if (index >= _posts.length) {
                  _loadMorePosts();
                  return const Center(
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                final p = _posts[index];
                final url = (p.mediaType == 'image') ? p.smallUrl : p.thumbUrl;
                return GestureDetector(
                  onTap: () => _openPostDetail(p),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FutureBuilder<File>(
                          future: DefaultCacheManager().getSingleFile(url),
                          builder: (ctx, snap) {
                            if (snap.connectionState == ConnectionState.done && snap.hasData) {
                              return Image.file(snap.data!, fit: BoxFit.cover);
                            }
                            return const ColoredBox(color: Color(0x11000000));
                          },
                        ),
                        if (p.mediaType == 'video')
                          const Positioned(
                            right: 6,
                            top: 6,
                            child: Icon(Icons.play_circle_fill, size: 22, color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),

        ],
      ),
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
    final hasVideo = (entry != null) && (entry.hasLocal || entry.hasRemote);
    final path = entry?.localPath;
    final remoteUrl = entry?.remoteUrl;


    return GestureDetector(
      onTap: () {
        if (!hasVideo) {
          if (!_canUploadForOwner) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No video uploaded yet.')),
            );
            return;
          }
          _pickVideoForLift(liftId);
          return;
        }
        // Prefer remote playback if present
        if (remoteUrl != null && remoteUrl.isNotEmpty) {
          _playVideoRemote(context, remoteUrl);
          return;
        }
        if (path != null && File(path).existsSync()) {
          _playVideo(context, path);
          return;
        }
        // Fallback: if something’s off, offer re-upload (owner/coach-only)
        if (_canUploadForOwner) {
          _pickVideoForLift(liftId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to play this video.')),
          );
        }
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
              // ---- BACKGROUND (prefer in-memory thumb for instant render) ----
              if (hasVideo)
                (_thumbCache[liftId] != null)
                    ? Image.memory(
                  _thumbCache[liftId]!,
                  fit: BoxFit.cover,
                )
                    : (_liftVideos[liftId]?.thumbUrl != null && _liftVideos[liftId]!.thumbUrl!.isNotEmpty)
                    ? Image.network(
                  _liftVideos[liftId]!.thumbUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(child: Icon(Icons.videocam));
                  },
                  errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.videocam)),
                )
                    : const Center(child: Icon(Icons.videocam)),



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
              if (_isSelf && hasVideo)
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

  Future<void> _loadInitialPosts() async {
    if (_loadingPosts) return;
    _loadingPosts = true;
    try {
      final q = await FirebaseFirestore.instance
          .collection('posts')
          .where('ownerUid', isEqualTo: _ownerUid)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .get();

      _posts
        ..clear()
        ..addAll(q.docs.map(Post.fromSnap));
      _lastPostSnap = q.docs.isNotEmpty ? q.docs.last : null;
      _hasMorePosts = q.docs.length == 30;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('❌ [_loadInitialPosts] $e');
    } finally {
      _loadingPosts = false;
    }
  }

  Future<void> _loadMorePosts() async {
    if (_loadingPosts || !_hasMorePosts || _lastPostSnap == null) return;
    _loadingPosts = true;
    try {
      final q = await FirebaseFirestore.instance
          .collection('posts')
          .where('ownerUid', isEqualTo: _ownerUid)
          .orderBy('createdAt', descending: true)
          .startAfterDocument(_lastPostSnap!)
          .limit(30)
          .get();

      if (q.docs.isEmpty) {
        _hasMorePosts = false;
      } else {
        _posts.addAll(q.docs.map(Post.fromSnap));
        _lastPostSnap = q.docs.last;
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('❌ [_loadMorePosts] $e');
    } finally {
      _loadingPosts = false;
    }
  }


  Future<void> _loadLiftVideosFromLocal() async {
    final ownerUid = _targetUid; // 👈 friend/coach/self-safe
    if (ownerUid == null) return;

    try {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .doc(ownerUid)
          .collection('liftVideos')
          .get();

      print('🎬 [_loadLiftVideosFromLocal] ownerUid=$ownerUid docs=${query.docs.length}');

      _liftVideos.clear();
      for (final doc in query.docs) {
        final data = doc.data();
        // Optional: debug to confirm we actually have remoteUrl/thumbUrl
        // print('   • ${doc.id}: remoteUrl=${data['remoteUrl']} thumbUrl=${data['thumbUrl']}');
        _liftVideos[doc.id] = LiftVideo.fromJson(data);
      }

      if (mounted) setState(() {});
    } catch (e) {
      print('❌ [_loadLiftVideosFromLocal] ownerUid=$ownerUid error=$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load videos')),
      );
    }
  }




  Future<void> _saveLiftVideosToLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _liftVideos.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_kLiftVideosPrefsKey, jsonEncode(map));
  }

  Future<void> _pickVideoForLift(String liftId) async {
    if (!_canUploadForOwner) return; // only owner or coach acting-as owner

    // Pick from gallery
    final XFile? picked = await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return; // user canceled

    final path = picked.path;

    // Low-cost: reject big files client-side (keeps network + Storage lean).
    final file = File(path);
    final size = await file.length(); // bytes
    const maxBytes = 100 * 1024 * 1024; // must match Storage rules
    if (size > maxBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video too large (max 100 MB). Please trim or compress.')),
      );
      return;
    }

    final ownerUid = _targetUid; // store under selected athlete
    if (ownerUid == null) return;

    // ✅ 1) Generate a thumbnail immediately so the tile updates right away.
    final thumbBytes = await VideoThumbnail.thumbnailData(
      video: path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 400,
      quality: 70,
    );

    // ✅ 2) Optimistically update UI now (instant thumb + local playback).
    setState(() {
      _liftVideos[liftId] = LiftVideo(
        liftId: liftId,
        localPath: path,      // instant playback while upload happens
        remoteUrl: null,
        thumbUrl: null,       // will be filled after upload
        updatedAt: DateTime.now(),
      );
      _thumbCache[liftId] = thumbBytes; // show immediately
    });

    // ✅ 3) Upload in the background and time it.
    final sw = Stopwatch()..start();
    debugPrint('⏱️ [VideoUpload] start liftId=$liftId, size=${size}B');

    unawaited(_uploadVideoAndThumb(liftId: liftId, localVideoPath: path).then((urls) async {
      final videoUrl = urls['videoUrl'] ?? '';
      final thumbUrl = urls['thumbUrl'] ?? '';

      // Update local model with remote URLs (keep localPath for snappy replays)
      if (mounted) {
        setState(() {
          _liftVideos[liftId] = LiftVideo(
            liftId: liftId,
            localPath: _liftVideos[liftId]?.localPath, // keep local for instant play
            remoteUrl: videoUrl,
            thumbUrl: thumbUrl,                        // ✅ ensure thumbUrl is saved
            updatedAt: DateTime.now(),
          );
          _thumbCache[liftId] = null;                 // ✅ prefer CDN thumb next build
        });
      }

      // Persist metadata so friends can read it
      await FirebaseFirestore.instance
          .collection('users')
          .doc(ownerUid)
          .collection('liftVideos')
          .doc(liftId)
          .set(_liftVideos[liftId]!.toJson());

      sw.stop();
      debugPrint('✅ [VideoUpload] done liftId=$liftId in ${sw.elapsedMilliseconds} ms '
          '(hasThumb=${thumbUrl.isNotEmpty})');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video uploaded')),
      );
    }).catchError((e) async {
      sw.stop();
      debugPrint('❌ [VideoUpload] failed liftId=$liftId after ${sw.elapsedMilliseconds} ms: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }));

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
        builder: (_) => _InAppVideoPlayer.file(path: path),
      ),
    );
  }

  void _playVideoRemote(BuildContext context, String url) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(url);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _InAppVideoPlayer.file(path: file.path)),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _InAppVideoPlayer.networkUrl(url: url)),
      );
    }
  }


  //Video bits end

  void _openPostDetail(Post p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PostDetailPage(
          post: p,
          onToggleLike: _toggleLike,
          onToggleGoodLift: _toggleGoodLift,
          onAddComment: _addComment,
          canDelete: _isSelf && p.ownerUid == _ownerUid, // owner-only delete
        ),
      ),
    );
  }




  Future<void> _loadSnapshotIfReadOnly() async {
    if (!widget.readOnly) return;

    final uid = widget.viewedUid ??
        UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    final snap = await FirebaseFirestore.instance
        .collection('users_public')
        .doc(uid)
        .get();
    final m = snap.data() ?? {};

    // helpers
    List<double> _arrOfNums(dynamic v) =>
        (v is List) ? v.map((e) => (e as num).toDouble()).toList() : <double>[];
    double _best(List<double> a) => a.isEmpty ? 0 : a.reduce((a1, a2) => a1 > a2 ? a1 : a2);

    // read top3 singles → best singles map for the 5 lifts
    final top3Singles = Map<String, dynamic>.from(m['top3SinglesKg'] ?? {});
    final squatBest = _best(_arrOfNums(top3Singles['Back Squat, Barbell']));
    final benchBest = _best(_arrOfNums(top3Singles['Bench Press, Barbell']));
    final deadBest  = _best(_arrOfNums(top3Singles['Deadlift, Conventional']));
    final chinBest  = _best(_arrOfNums(top3Singles['Chin-Up']));
    final ohpBest   = _best(_arrOfNums(top3Singles['Overhead Dumbbell Press, Unilateral']));

    setState(() {
      // your UI already uses these
      _bestSinglesFive = {
        'Back Squat, Barbell': squatBest,
        'Bench Press, Barbell': benchBest,
        'Deadlift, Conventional': deadBest,
        'Chin-Up': chinBest,
        'Overhead Dumbbell Press, Unilateral': ohpBest,
      };

      _bestThreeLiftTotal = (m['threeLiftTotalKg'] as num?)?.toDouble();
      _bestBenchOnly      = (m['benchOnlyKg'] as num?)?.toDouble();

      // points are optional
      _rePoints       = (m['rePoints'] as num?)?.toDouble();
      _goodliftPoints = (m['goodliftPoints'] as num?)?.toDouble();

      isLoading = false; // stop spinner when friend snapshot is loaded
    });
  }

  void _subscribeUsersPublic() {
    final uid = _selectedUidFromContext();
    if (uid == null) {
      debugPrint('📡 [Profile] _subscribeUsersPublic: no selected UID');
      return;
    }

    // Always (re)target the selected athlete
    _publicSub?.cancel();
    _subscribedUid = uid;

    debugPrint('📡 [Profile] subscribing to users_public/$uid');
    final docRef = FirebaseFirestore.instance.collection('users_public').doc(uid);

    _publicSub = docRef.snapshots().listen((snap) {
      final m = snap.data();
      if (m == null) return;

      final rePts  = (m['rePoints'] as num?)?.toDouble();
      final byLift = Map<String, dynamic>.from(m['rePointsByLift'] ?? const {});

      debugPrint('📡 [Profile] users_public/$uid '
          'update source=${m['rePointsSource']} total=$rePts '
          'byLift=$byLift computedAt=${m['rePointsComputedAt']}');

      if (!mounted) return;
      setState(() {
        _rePoints = rePts; // chip reads this
        // If you also keep per-lift locally, map them here.
        // _rePointsByLift = byLift.map((k, v) => MapEntry(k, (v as num).toDouble()));
      });
    });
  }





  Future<void> _kickRecompute12m() async {
    final uid = _selectedUidFromContext();
    if (uid == null) {
      debugPrint('⏱️ [Profile] _kickRecompute12m: no selected UID');
      return;
    }

    final loggedInUid = FirebaseAuth.instance.currentUser?.uid;
    final isSelf = (loggedInUid != null && uid == loggedInUid);
    debugPrint('⏱️ [Profile] recompute12m for uid=$uid isSelf=$isSelf');

    try {
      await stats.recomputeRePointsLast12Months(uid);
      debugPrint('✅ [Profile] recompute12m finished for uid=$uid');
    } catch (e) {
      debugPrint('❌ [Profile] recompute12m failed for uid=$uid: $e');
    }
  }



  String? _selectedUidFromContext() {
    // Prefer an already-computed target if you keep one:
    if (_targetUid != null && _targetUid!.isNotEmpty) return _targetUid;

    // If the page was navigated with a viewedUid:
    if (widget.viewedUid != null && widget.viewedUid!.isNotEmpty) return widget.viewedUid;

    // Fallbacks: try your UserContext, then the logged-in user
    final uc = UserContext.of(context, listen: false);
    final ctxUid = uc.currentUid ?? uc.actorUid;
    if (ctxUid != null && ctxUid.isNotEmpty) return ctxUid;

    return FirebaseAuth.instance.currentUser?.uid;
  }


  @override
  void initState() {
    super.initState();

    final uc = UserContext.of(context, listen: false);
    print('👤 [Profile.init] actorUid=${uc.actorUid} currentUid(actingAs)=${uc.currentUid}');

    final selectedUid = uc.currentUid; // 👈 acting-as athlete (if any)
    final selfUid     = uc.actorUid;   // 👈 logged-in user
    _targetUid        = widget.viewedUid ?? selectedUid;
    _readOnlyView     = widget.readOnly || (_targetUid != selfUid);
    print('🎯 [Profile.init] widget.viewedUid=${widget.viewedUid}, selectedUid=$selectedUid selfUid=$selfUid → _targetUid=$_targetUid, _readOnlyView=$_readOnlyView');

    // 🔄 Reset any stale avatar state from previous user before loading fresh data
    _localProfileImage = null;
    _localProfilePath  = null;
    photoURL           = null;

    // Load per-user local avatar (works for self OR friend)
    unawaited(_loadLocalProfileImage());

    // Load profile document (users for self, users_public for friend)
    _loadProfileData();
    print('📥 [Profile.init] _loadProfileData() kicked for uid=$_targetUid (readOnlyView=$_readOnlyView)');

    // Always load lift videos for the viewed profile (self/coach-acting-as/friend)
    _loadLiftVideosFromLocal();
    print('🎞️ [Profile.init] _loadLiftVideosFromLocal() kicked for uid=$_targetUid');

    // Subscribe to selected user's public stats and (if self) kick recompute
    _subscribeUsersPublic();   // uses _targetUid
    print('📡 [Profile.init] _subscribeUsersPublic() wired for uid=$_targetUid');

    _kickRecompute12m();       // checks !_readOnlyView internally

    if (!_readOnlyView) {
      print('🛠️ [Profile.init] SELF mode loaders starting for uid=$_targetUid');

      // ==== SELF: keep original loaders + compute ====
      _loadPhotoURL();
      _refreshBestLiftsAndPoints();   // ✅ self ONLY
      _loadCurrentUsername();
      _loadCompSingles();
      _loadProfilePrefs();
      _loadBodyWeightForSelectedUser();
      _loadHeightForSelectedUser();
      _loadGender();

      // Optionally reflect local photo into UserContext for app bar, if present
      _loadLocalProfileImage().then((_) {
        final uc2 = context.read<UserContext>();
        if (_localProfilePath != null && File(_localProfilePath!).existsSync()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) uc2.setLocalPhotoPath(_localProfilePath);
          });
        }
      });
    } else {
      print('🔒 [Profile.init] FRIEND (read-only) mode for uid=$_targetUid');
      // ==== FRIEND (read-only): nothing extra ====
    }

    // Posts grid (profile feed) for the viewed profile
    _loadInitialPosts();

  }




  @override
  void dispose() {
    _saveCompSingles();
    _saveProfileData();
    _compSqCtrl.dispose();
    _compBpCtrl.dispose();
    _compDlCtrl.dispose();
    _heightCtrl.dispose();
    _bioController.dispose();
    _publicSub?.cancel();

    _saveLiftVideosToLocal(); // persist on page exit


    for (final c in _inlineControllers.values) {
      c.dispose();
    }
    _inlineControllers.clear();
    super.dispose();
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

  Future<void> _loadProfilePrefs() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = doc.data();
    if (data == null) return;

    // Safe map coercion
    final profile = data['profile'] is Map
        ? Map<String, dynamic>.from(data['profile'] as Map)
        : <String, dynamic>{};
    final prefs = profile['prefs'] is Map
        ? Map<String, dynamic>.from(profile['prefs'] as Map)
        : <String, dynamic>{};

    // DEBUG
    print('[PrefsLoader] profile keys: ${profile.keys.toList()}');
    print('[PrefsLoader] prefs keys: ${prefs.keys.toList()}');

    setState(() {
      final bw = (prefs['bwUnit'] as String?)?.toLowerCase();
      _bwUnit = (bw == 'lb') ? BodyWeightUnit.lb : BodyWeightUnit.kg;

      final hu = (prefs['heightUnit'] as String?)?.toLowerCase();
      _heightUnit = (hu == 'inch') ? HeightUnit.inch : HeightUnit.cm;

      final mode = (prefs['bwMode'] as String?)?.toLowerCase();
      _bwMode = (mode == 'avg7') ? BodyWeightMode.avg7 : BodyWeightMode.recent;

      // If you store this:
      // _metricsPrivate = prefs['bodyMetricsPrivate'] == true;
    });
  }

  Future<void> _loadGender() async {
    // ✅ Use the SELECTED athlete first; fall back to actor/logged-in.
    final selectedUid =
        _targetUid ??
            UserContext.of(context, listen: false).actorUid ??
            FirebaseAuth.instance.currentUser?.uid;

    if (selectedUid == null) return;

    debugPrint('⚙️ [Profile] _loadGender for selectedUid=$selectedUid (readOnlyView=$_readOnlyView)');

    // Try users/{uid} server-first, fallback to cache
    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(selectedUid)
          .get(const GetOptions(source: Source.server));
    } catch (_) {
      snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(selectedUid)
          .get(const GetOptions(source: Source.cache));
    }
    Map<String, dynamic> data = snap.data() ?? {};

    // Prefer 'sex' ('M'|'F'|'N'); fallback to profile.gender ('male'|'female')
    String? sex = data['sex'] as String?;
    String? profileGender;
    try { profileGender = snap.get('profile.gender') as String?; } catch (_) {}
    if (profileGender == null && data.containsKey('profile.gender') && data['profile.gender'] is String) {
      profileGender = data['profile.gender'] as String;
    }

    // If nothing in users/{uid}, try users_public/{uid} as a last resort
    if (sex == null && profileGender == null) {
      try {
        final pubSnap = await FirebaseFirestore.instance
            .collection('users_public')
            .doc(selectedUid)
            .get(const GetOptions(source: Source.server));
        final pub = pubSnap.data() ?? {};
        sex = pub['sex'] as String?;
        if (profileGender == null && pub.containsKey('profile.gender') && pub['profile.gender'] is String) {
          profileGender = pub['profile.gender'] as String;
        }
      } catch (_) {/* ignore */}
    }

    // Map to formula.Gender — default male; 'N' also → male (per your rule)
    final formula.Gender resolvedGender =
    (sex == 'F' || (sex == null && (profileGender?.toLowerCase() == 'female')))
        ? formula.Gender.female
        : formula.Gender.male;

    if (!mounted) return;
    setState(() {
      _gender = resolvedGender;

      // ✅ keep the overwrite: recompute RE Points from _bestLifts for the SELECTED user
      // (Your _bestLifts already holds the selected athlete’s lifts in friend view,
      //  and self lifts in self view.)
      _rePoints = _computeREPointsFromBest(_bestLifts);
    });

    debugPrint('👤 [Profile] gender resolved for $selectedUid → $_gender; RE recomputed from selected user’s best lifts.');
  }





  Future<void> _loadProfileData() async {
    final uid = _targetUid;
    if (uid == null) return;

    // self => private profile; friend => public projection
    final bool isSelf = !_readOnlyView;
    final String col = isSelf ? 'users' : 'users_public';

    final doc = await FirebaseFirestore.instance.collection(col).doc(uid).get();
    final data = doc.data() ?? {};

    if (isSelf) {
      // --- SELF VIEW: your existing editable fields ---
      _bioController.text = (data['bio'] ?? '').toString();
      squat           = (data['bestSquat'] ?? 0).toDouble();
      bench           = (data['bestBench'] ?? 0).toDouble();
      deadlift        = (data['bestDeadlift'] ?? 0).toDouble();
      chinUp          = (data['bestChinUp'] ?? 0).toDouble();
      unilateralPress = (data['bestUnilateralPress'] ?? 0).toDouble();
      _currentUsername = (data['username'] ?? _currentUsername ?? '').toString();
      photoURL = (data['photoURL'] ?? photoURL ?? '').toString();

    } else {
      // --- FRIEND VIEW: read snapshot aggregates from users_public ---
      List<double> _arr(dynamic v) =>
          (v is List) ? v.whereType<num>().map((n) => n.toDouble()).toList() : <double>[];
      double _best(List<double> a) => a.isEmpty ? 0 : a.reduce((a, b) => a > b ? a : b);

      final top3Singles = Map<String, dynamic>.from(data['top3SinglesKg'] ?? {});
      final squatBest = _best(_arr(top3Singles['Back Squat, Barbell']));
      final benchBest = _best(_arr(top3Singles['Bench Press, Barbell']));
      final deadBest  = _best(_arr(top3Singles['Deadlift, Conventional']));
      final chinBest  = _best(_arr(top3Singles['Chin-Up']));
      final ohpBest   = _best(_arr(top3Singles['Overhead Dumbbell Press, Unilateral']));

      _bestSinglesFive = {
        'Back Squat, Barbell': squatBest,
        'Bench Press, Barbell': benchBest,
        'Deadlift, Conventional': deadBest,
        'Chin-Up': chinBest,
        'Overhead Dumbbell Press, Unilateral': ohpBest,
      };

      _bestThreeLiftTotal = (data['threeLiftTotalKg'] as num?)?.toDouble();
      _bestBenchOnly      = (data['benchOnlyKg']      as num?)?.toDouble();

      // optional points (may be null)
      _rePoints       = (data['rePoints']       as num?)?.toDouble();
      _goodliftPoints = (data['goodliftPoints'] as num?)?.toDouble();

      // header label source for friend view (users_public likely has username/emailLower)
      _currentUsername = (data['username'] ?? _currentUsername ?? '').toString();
      photoURL = (data['photoURL'] ?? photoURL ?? '').toString();


      // 👇 Drive the “weight × reps  ~ e1RM” rows from bestE1rmDetail
      final detail = Map<String, dynamic>.from(data['bestE1rmDetail'] ?? {});
      BestLift? _mk(String name) {
        final d = detail[name];
        if (d is Map) {
          return BestLift(
            exerciseName: name,
            weight: (d['weight'] as num?)?.toDouble() ?? 0,
            reps:   (d['reps']   as num?)?.toInt()    ?? 0,
            e1rm:   (d['e1rm']   as num?)?.toDouble() ?? 0,
          );
        }
        return null;
      }

      final Map<String, BestLift> filled = {};
      void put(String name) {
        final x = _mk(name);
        if (x != null) filled[name] = x; // only add if present
      }

      put('Back Squat, Barbell');
      put('Bench Press, Barbell');
      put('Deadlift, Conventional');
      put('Chin-Up');
      put('Overhead Dumbbell Press, Unilateral');

      _bestLifts.clear();
      _bestLifts.addAll(filled);


      // Do NOT touch editable self-only fields in friend view (bio, etc.)
      _bioController.text = '';
    }

    if (mounted) setState(() => isLoading = false);
  }




  Future<void> _saveProfileData() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    final heightCm = _currentHeightCmFromField();
    final bwUnitPref = _bwUnit == BodyWeightUnit.kg ? 'kg' : 'lb';
    final heightUnitPref = _heightUnit == HeightUnit.cm ? 'cm' : 'inch';

    final payload = <String, dynamic>{
      'bio': _bioController.text,
      'profile': {
        if (heightCm != null)
          'heightCm': double.parse(heightCm.toStringAsFixed(2)),
        'gender': (_gender == formula.Gender.female) ? 'female' : 'male', // ✅ nested
        'prefs': {
          'bwUnit': bwUnitPref,
          'heightUnit': heightUnitPref,
          'bwMode': _bwMode == BodyWeightMode.recent ? 'recent' : 'avg7',
          // 'bodyMetricsPrivate': _metricsPrivate,
        },
        'updatedAt': FieldValue.serverTimestamp(),
      },
    };

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .set(payload, SetOptions(merge: true));


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

    final ownerUid = _targetUid ?? FirebaseAuth.instance.currentUser!.uid;
    final tempFile = File(picked.path);
    final appDir = await getApplicationDocumentsDirectory();
    final destPath = '${appDir.path}/profile_$ownerUid.jpg'; // 👈 per-user filename

    // Overwrite any previous file for THIS user
    try { await File(destPath).delete(); } catch (_) {}
    await tempFile.copy(destPath);

    // Evict any old cache entries for this destPath
    await FileImage(File(destPath)).evict();

    // Persist per-user local path
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kProfilePhotoPrefsKeyPrefix$ownerUid', destPath);

    // Update UI immediately with the local image
    if (!mounted) return;
    setState(() {
      _localProfilePath = destPath;
      _localProfileImage = File(destPath);
    });

    // If this is self, sync UserContext so the AppBar/avatar can update
    final uc = context.read<UserContext>();
    if (uc.actorUid == ownerUid) {
      uc.setLocalPhotoPath(destPath);
    }

    // 🔄 Background upload to Storage
    final ref = FirebaseStorage.instance.ref('users/$ownerUid/profile/profile.jpg');
    final sw = Stopwatch()..start();
    debugPrint('⏱️ [ProfilePhoto] start uid=$ownerUid, size=${await File(destPath).length()}B');
    unawaited(ref.putFile(File(destPath), SettableMetadata(contentType: 'image/jpeg')).then((_) async {
      final url = await ref.getDownloadURL();

      // Evict any old cached network image (in case URL stayed same—which it usually doesn't)
      await NetworkImage(url).evict();

      // Write to users + users_public so friends see it
      await FirebaseFirestore.instance.collection('users').doc(ownerUid)
          .set({'photoURL': url, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('users_public').doc(ownerUid)
          .set({'photoURL': url}, SetOptions(merge: true));

      if (mounted) {
        setState(() {
          photoURL = url; // so friend/self view can use NetworkImage if needed
        });
      }

      sw.stop();
      debugPrint('✅ [ProfilePhoto] done uid=$ownerUid in ${sw.elapsedMilliseconds} ms');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile photo uploaded')));
    }).catchError((e) {
      sw.stop();
      debugPrint('❌ [ProfilePhoto] failed after ${sw.elapsedMilliseconds} ms: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
    }));
  }

  Future<void> _pickAndUploadPost() async {
    if (!_canUploadForOwner) return;

    // Simple chooser – image or video
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('New Post'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'image'),
            child: const Text('Image'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'video'),
            child: const Text('Video'),
          ),
        ],
      ),
    );
    if (type != 'image' && type != 'video') return;

    final XFile? picked = (type == 'image')
        ? await _imagePicker.pickImage(source: ImageSource.gallery, imageQuality: 90)
        : await _imagePicker.pickVideo(source: ImageSource.gallery);

    if (picked == null) return;

    final ownerUid = _ownerUid;
    final postId = FirebaseFirestore.instance.collection('_').doc().id;
    final baseRef = FirebaseStorage.instance.ref('users/$ownerUid/posts/$postId');

    String smallUrl = '';
    String thumbUrl = '';
    String storagePathOriginal = '';

    try {
      if (type == 'image') {
        // Compress -> small.jpg (~1080px longest edge)
        final original = File(picked.path);
        final tempSmall = File('${(await getTemporaryDirectory()).path}/$postId-small.jpg');

        final compBytes = await FlutterImageCompress.compressWithFile(
          original.path,
          format: CompressFormat.jpeg,
          quality: 85,
          minWidth: 1080,
          keepExif: false,
        );
        if (compBytes == null) throw Exception('Image compress failed');

        await tempSmall.writeAsBytes(compBytes);

        // Upload small.jpg (grid)
        final smallRef = baseRef.child('small.jpg');
        await smallRef.putFile(
          tempSmall,
          SettableMetadata(
            contentType: 'image/jpeg',
            cacheControl: 'public,max-age=31536000',
          ),
        );
        smallUrl = await smallRef.getDownloadURL();
        thumbUrl = smallUrl; // images use small as thumb

        // Upload original.jpg (optional bigger view)
        final origRef = baseRef.child('original.jpg');
        await origRef.putFile(
          original,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        storagePathOriginal = origRef.fullPath;
      } else {
        // VIDEO: upload .mp4 and thumb.jpg
        final original = File(picked.path);
        final videoRef = baseRef.child('original.mp4');
        await videoRef.putFile(
          original,
          SettableMetadata(contentType: 'video/mp4'),
        );
        storagePathOriginal = videoRef.fullPath;

        // Generate & upload thumb
        final thumbBytes = await VideoThumbnail.thumbnailData(
          video: original.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 400,
          quality: 70,
        );
        if (thumbBytes == null) throw Exception('Video thumb failed');
        final tempThumb = File('${(await getTemporaryDirectory()).path}/$postId-thumb.jpg')
          ..writeAsBytesSync(thumbBytes);

        final thumbRef = baseRef.child('thumb.jpg');
        await thumbRef.putFile(
          tempThumb,
          SettableMetadata(
            contentType: 'image/jpeg',
            cacheControl: 'public,max-age=31536000',
          ),
        );
        thumbUrl = await thumbRef.getDownloadURL();
        smallUrl = thumbUrl; // grid uses thumb for videos too
      }

      // Create post doc (denormalized counters)
      await FirebaseFirestore.instance.collection('posts').doc(postId).set({
        'ownerUid': ownerUid,
        'mediaType': type,
        'storagePathOriginal': storagePathOriginal,
        'thumbUrl': thumbUrl,
        'smallUrl': smallUrl,
        'caption': null,
        'aspectRatio': null,
        'durationMs': null,
        'likeCount': 0,
        'goodLiftCount': 0,
        'commentCount': 0,
        'visibility': 'public',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Optimistic refresh
      await _loadInitialPosts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post uploaded')));
    } catch (e) {
      debugPrint('❌ [_pickAndUploadPost] $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  Future<void> _toggleLike(Post p) async {
    final uid = UserContext.of(context, listen: false).actorUid;
    if (uid.isEmpty) throw 'Not signed in';

    final likeRef = FirebaseFirestore.instance.collection('posts').doc(p.id).collection('likes').doc(uid);
    final postRef = FirebaseFirestore.instance.collection('posts').doc(p.id);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final likeSnap = await tx.get(likeRef);
        final postSnap = await tx.get(postRef);
        if (!postSnap.exists) throw 'Post missing';

        final cur = (postSnap['likeCount'] ?? 0) as int;
        if (likeSnap.exists) {
          tx.delete(likeRef);
          tx.update(postRef, {'likeCount': (cur > 0) ? cur - 1 : 0});
        } else {
          tx.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
          tx.update(postRef, {'likeCount': cur + 1});
        }
      });
    } catch (e) {
      debugPrint('❌ [_toggleLike] $e');
      rethrow;
    }
  }

  Future<void> _toggleGoodLift(Post p) async {
    if (p.mediaType != 'video') return;
    final uid = UserContext.of(context, listen: false).actorUid;
    if (uid.isEmpty) throw 'Not signed in';

    final glRef = FirebaseFirestore.instance.collection('posts').doc(p.id).collection('goodLifts').doc(uid);
    final postRef = FirebaseFirestore.instance.collection('posts').doc(p.id);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final glSnap = await tx.get(glRef);
        final postSnap = await tx.get(postRef);
        if (!postSnap.exists) throw 'Post missing';

        final cur = (postSnap['goodLiftCount'] ?? 0) as int;
        if (glSnap.exists) {
          tx.delete(glRef);
          tx.update(postRef, {'goodLiftCount': (cur > 0) ? cur - 1 : 0});
        } else {
          tx.set(glRef, {'createdAt': FieldValue.serverTimestamp()});
          tx.update(postRef, {'goodLiftCount': cur + 1});
        }
      });
    } catch (e) {
      debugPrint('❌ [_toggleGoodLift] $e');
      rethrow;
    }
  }

  Future<void> _addComment(Post p, String text) async {
    final uid = UserContext.of(context, listen: false).actorUid;
    if (text.trim().isEmpty) return;

    // 🔹 Fetch username from users_public
    final userDoc = await FirebaseFirestore.instance
        .collection('users_public')
        .doc(uid)
        .get();

    final data = userDoc.data() ?? {};
    final username = (data['username'] ?? data['displayName'] ?? uid).toString();

    final postRef = FirebaseFirestore.instance.collection('posts').doc(p.id);
    final commentRef = postRef.collection('comments').doc();

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final postSnap = await tx.get(postRef);
      if (!postSnap.exists) return;

      tx.set(commentRef, {
        'uid': uid,
        'username': username, // ✅ store username at time of posting
        'text': text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'likeCount': 0,
      });

      final cur = (postSnap.data()?['commentCount'] ?? 0) as int;
      tx.update(postRef, {'commentCount': cur + 1});
    });
  }



  Future<void> _loadLocalProfileImage() async {
    final ownerUid = _targetUid; // the page’s subject (self/selected/friend)
    if (ownerUid == null) return;

    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('$_kProfilePhotoPrefsKeyPrefix$ownerUid');

    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      if (!mounted) return;
      setState(() {
        _localProfilePath = path;
        _localProfileImage = File(path);
      });
    } else {
      // Ensure we don't carry over a previous user's local image in memory
      if (!mounted) return;
      setState(() {
        _localProfilePath = null;
        _localProfileImage = null;
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

  double? _currentBodyWeightKg() {
    // pick the active source (recent vs 7-day)
    final raw = (_bwMode == BodyWeightMode.recent) ? _bwRecent : _bwAvg7;
    if (raw == null) return null;

    // raw is stored from Firestore in kg.
    // If the UI toggle is lb, convert back to kg to be safe.
    if (_bwUnit == BodyWeightUnit.lb) {
      return _lbsToKg(_kgToLbs(raw)); // no-op in practice but future-proof if source changes
    }
    return raw;
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

  double? _currentHeightCmFromField() {
    final txt = _heightCtrl.text.trim();
    if (txt.isEmpty) return null;

    if (_heightUnit == HeightUnit.cm) {
      return double.tryParse(txt);
    } else {
      // inch mode accepts 5'8", 5'8.5", 68, etc.
      final inches = _feetInchesStringToInches(txt);
      if (inches == null) return null;
      return _inToCm(inches);
    }
  }

  Future<void> _loadHeightForSelectedUser() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) {
      print('[HeightLoader] No UID found, skipping load.');
      return;
    }
    print('[HeightLoader] Loading height for UID: $uid');

    // Server-first to avoid stale cache
    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
    } catch (_) {
      snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.cache));
    }
    if (!snap.exists) {
      print('[HeightLoader] User doc missing.');
      return;
    }

    // ----- Load height unit pref (nested if present)
    String? heightUnitPref;
    try {
      final v = snap.get('profile.prefs.heightUnit');
      if (v is String) heightUnitPref = v.toLowerCase();
    } catch (_) {}
    setState(() {
      _heightUnit = (heightUnitPref == 'inch') ? HeightUnit.inch : HeightUnit.cm;
    });
    print('[HeightLoader] Height unit from prefs: $_heightUnit (raw="$heightUnitPref")');

    // ----- Read height: try nested map first
    double? heightCm;
    try {
      final v = snap.get('profile.heightCm'); // nested path
      if (v is num) heightCm = v.toDouble();
    } catch (_) {
      // fallback: literal flat field named "profile.heightCm"
      // Fallback: check for legacy flat key
      try {
        final rawData = snap.data();
        if (rawData != null && rawData.containsKey('profile.heightCm')) {
          final v = rawData['profile.heightCm'];
          if (v is num) heightCm = v.toDouble();
          print('[HeightLoader] Read legacy flat field "profile.heightCm": $heightCm');
        }
      } catch (e) {
        print('[HeightLoader] Legacy flat key read failed: $e');
      }

    }

    if (heightCm == null) {
      print('[HeightLoader] heightCm not found in nested or flat field.');
      return;
    }
    print('[HeightLoader] Found heightCm: $heightCm');

    // ----- Format into TextField
    if (_heightUnit == HeightUnit.cm) {
      _heightCtrl.text = heightCm.toStringAsFixed(2);
    } else {
      final inches = heightCm / 2.54;
      final feet = inches ~/ 12;
      final rem = inches - feet * 12;
      _heightCtrl.text = "$feet'${rem.toStringAsFixed(1)}\"";
    }
    if (mounted) setState(() {});
    print('[HeightLoader] TextField set to: ${_heightCtrl.text}');
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
  formula.Gender _gender = formula.Gender.male; // default until you wire profile.gender

  Future<void> _refreshBestLiftsAndPoints() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    try {
      // 1) Fetch best E1RMs from workouts
      final best = await _fetchBestLiftsFromWorkouts(uid, _displayExercises);

      // 2) (Optional) Goodlift points from your existing helper
      final gl = await _computeGoodliftPoints(uid, best);

      // 3) RE points from best-in-training E1RMs + BW/gender
      final rePts = _computeREPointsFromBest(best);

      // 4) Any other totals you compute
      await _computeCompTotals(uid);

      if (!mounted) return;
      setState(() {
        _bestLifts
          ..clear()
          ..addAll(best);
        _goodliftPoints = gl;
        _rePoints = rePts;
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


  /// Compute RE points from the best-in-training E1RMs.
  /// Expects `_bestLifts` to be keyed by the workout exercise names that match
  /// `formula.ReExerciseKeys.defaults`.
  double? _computeREPointsFromBest(Map<String, BestLift> bestByName) {
    final bwKg = _currentBodyWeightKg();
    if (bwKg == null || bwKg <= 0) return null;

    const keys = formula.ReExerciseKeys.defaults;
    double readE1(String name) => (bestByName[name]?.e1rm ?? 0.0).toDouble();

    final squatE1       = readE1(keys.squat);
    final benchE1       = readE1(keys.bench);
    final deadliftE1    = readE1(keys.deadlift);
    final chinTotalE1   = readE1(keys.chinUp);        // ← use E1RM as TOTAL (no BW add)
    final dbShoulderE1  = readE1(keys.dbShoulder);

    final includes = formula.ReIncludes(
      bench:      benchE1 > 0,
      squat:      squatE1 > 0,
      deadlift:   deadliftE1 > 0,
      chinUp:     chinTotalE1 > 0,
      dbShoulder: dbShoulderE1 > 0,
    );

    return formula.computeRePoints(
      gender: _gender,
      bodyweightKg: bwKg,
      benchKg: benchE1,
      squatKg: squatE1,
      deadliftKg: deadliftE1,
      chinUpCombinedKg: chinTotalE1,       // ← pass through directly
      dbShoulderUnilateralKg: dbShoulderE1,
      includes: includes,
      roundDecimals: 2,
    );
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
                  // Centered heading with adjustable right-aligned toggle
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: double.infinity, // <-- ensure full width
                      height: 32,
                      child: Stack(
                        children: [
                          // Centered heading
                          const Center(
                            child: Text(
                              'Body Metrics',
                              textAlign: TextAlign.center,
                              // replace with GoogleFonts.monda if you prefer
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),

                          // Right-aligned toggle (on top)
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 0), // <- tweak this to nudge
                              child: InkWell(
                                onTap: () => setState(() => _metricsPrivate = !_metricsPrivate),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _metricsPrivate
                                        ? Colors.blueGrey.withOpacity(0.25)
                                        : Colors.blueGrey.withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _metricsPrivate ? Icons.lock : Icons.lock_open,
                                        size: 14,
                                        color: Colors.blueGrey,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _metricsPrivate ? 'Private' : 'Public',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                                      InkWell(
                                        onTap: () {
                                          setState(() {
                                            if (_bwUnit == BodyWeightUnit.kg) {
                                              _bwUnit = BodyWeightUnit.lb;
                                            } else {
                                              _bwUnit = BodyWeightUnit.kg;
                                            }
                                          });
                                        },
                                        borderRadius: BorderRadius.circular(16),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.blueGrey.withOpacity(0.10),
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: Text(
                                            _bwUnit == BodyWeightUnit.kg ? 'kg' : 'lb',
                                            style: const TextStyle(fontSize: 14),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )

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

                                    if (_bwUnit == BodyWeightUnit.lb) {
                                      return '${_kgToLbs(v).toStringAsFixed(1)} lb';
                                    } else {
                                      return '${v.toStringAsFixed(1)} kg';
                                    }

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
// --- Gender ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // LEFT: label (keeps same look as others)
                        Expanded(
                          child: Text('Gender', style: GoogleFonts.monda(fontSize: 16)),
                        ),

                        // RIGHT: chip with dropdown (same chip styling as height/deadlift)
                        SizedBox(
                          width: _rightColWidth,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: (_metricsPrivate)
                                ? const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Private',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            )
                                : DropdownButtonHideUnderline(
                              child: DropdownButton<formula.Gender>(
                                isExpanded: true,
                                value: _gender,
                                dropdownColor: Colors.blueGrey,
                                iconEnabledColor: Colors.white,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                items: const [
                                  DropdownMenuItem(
                                    value: formula.Gender.male,
                                    child: Text('Male'),
                                  ),
                                  DropdownMenuItem(
                                    value: formula.Gender.female,
                                    child: Text('Female'),
                                  ),
                                ],
                                onChanged: (val) {
                                  if (val == null) return;
                                  setState(() => _gender = val);
                                  // Recompute RE immediately
                                  setState(() {
                                    _rePoints = _computeREPointsFromBest(_bestLifts);
                                  });
                                },
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

    final ImageProvider? avatarImage =
    (_localProfileImage != null)
        ? FileImage(_localProfileImage!)
        : (_localProfilePath != null && File(_localProfilePath!).existsSync())
        ? FileImage(File(_localProfilePath!))
        : (photoURL != null && photoURL!.isNotEmpty)
        ? NetworkImage(photoURL!)
        : null;


    return WillPopScope(
      onWillPop: () async {
        if (!_readOnlyView && _isSelf) {
          await _saveCompSingles();
          await _saveProfileData();
        }
        return true;
      },

      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.blueGrey,
          automaticallyImplyLeading: false, // disable default
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              // ✅ Only save if this is *your own* editable profile
              if (!_readOnlyView && _targetUid == UserContext.of(context, listen: false).actorUid) {
                await _saveCompSingles();
                await _saveProfileData();
              }
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
                    child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection(_readOnlyView ? 'users_public' : 'users')
                          .doc(_targetUid)
                          .snapshots(),
                      builder: (context, snap) {
                        print('🧷 [AppBar.title] stream col=${_readOnlyView ? 'users_public' : 'users'} doc=$_targetUid hasData=${snap.hasData} err=${snap.error}');

                        final data = snap.data?.data();
                        print('🧷 [AppBar.title] data keys=${data?.keys.toList()} username=${data?['username']} displayName=${data?['displayName']} email=${data?['email']}');

                        String? pick(dynamic v) {
                          final s = (v ?? '').toString().trim();
                          return s.isEmpty ? null : s;
                        }

                        final label = pick(data?['username']) ??
                            pick(data?['displayName']) ??
                            pick(data?['email']) ??
                            'Unknown';
                        print('🏷️ [AppBar.title] resolved label="$label"');


                        return Text(
                          label,
                          maxLines: 1,
                          style: GoogleFonts.rajdhani(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
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
                      if (_readOnlyView) return; // 👈 block edits in friend view
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
                        if (_readOnlyView || !_isSelf) return; // 👈 block in friend view
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
                        if (_readOnlyView || !_isSelf) return; // 👈 block edits in friend view
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
                      _StatChip(label: 'RE Points', value: _rePoints),
                      const SizedBox(height: 8),
                      _StatChip(
                        label: 'Best Comp Total Kgs',
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
            if (!_readOnlyView && _isSelf)
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

// ===== NEW: Posts Grid (3×3) =====
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _buildPostsSection(),
            ),

            const SizedBox(height: 60),

          ],
        ),


      ),
    ),
    );
  }
}
