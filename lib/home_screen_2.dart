import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';

import 'app_drawer.dart';
import 'approve_requests_screen.dart';
import 'bb3_week_planner.dart';
import 'block_exercise_defaults_repository.dart';
import 'coach_home_screen.dart';
import 'directMessages.dart';
import 'home_bootstrap_service.dart';
import 'main.dart';
import 'planned_blocks_screen.dart';
import 'profile_page.dart';
import 'templates.dart';
import 'user_context.dart';
import 'user_settings.dart';
import 'warmup_service.dart';
import 'WES2_screen.dart';

// Private to this file — avoids name collision with home_screen.dart's SelectedFeed.
enum _HomeV2Feed { home, points, leaderboard }

class HomeScreen2 extends StatefulWidget {
  const HomeScreen2({super.key});

  @override
  State<HomeScreen2> createState() => _HomeScreen2State();
}

class _HomeScreen2State extends State<HomeScreen2> with RouteAware {
  late final UserContext _uc;
  bool _ucBound = false;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const double kFeatureCardWidth = 150;

  bool _isFirstTimeSetup = false;
  String _setupStatusMessage = '';
  bool _blockSetupComplete = false;

  String? _lastEmailLoadedForUid;
  String? _actingAsEmail;
  String? _lastWarmUid;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _activeBlockSub;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Set<DateTime> _trainingDays = {};

  bool _avatarPersistInProgress = false;
  String? _avatarLastUrlSaved;

  _HomeV2Feed _selectedFeed = _HomeV2Feed.home;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    debugPrint('🏠 [HOME2:initState] running');

    final uc = Provider.of<UserContext>(context, listen: false);
    final actingUid = uc.actingAsUid;
    _lastWarmUid = actingUid;

    final hasBlockMeta = uc.activeBlockId != null && uc.activeBlockId!.isNotEmpty;
    if (hasBlockMeta) {
      debugPrint('🏠 [HOME2] existing user (blockId=${uc.activeBlockId}) — rendering immediately');
      _blockSetupComplete = true;
      _fetchTrainingDaysForMonth(_focusedDay);
      _setupActiveBlockListener(actingUid);
      _scheduleRirHeal(uc);
      unawaited(() async {
        await HomeBootstrapService.ensureBlocksExist(uid: actingUid, uc: uc);
        if (!mounted) return;
        final freshUc = Provider.of<UserContext>(context, listen: false);
        unawaited(freshUc.refreshBlockMetaFromServer(uid: freshUc.actingAsUid));
      }());
    } else {
      debugPrint('🏠 [HOME2] no block meta — running first-time setup');
      unawaited(_runFirstTimeSetup(actingUid));
    }

    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null && authUser.uid == actingUid && actingUid.isNotEmpty) {
      HomeBootstrapService.startTemplateBootstrap(actingUid);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_ucBound) {
      _uc = context.read<UserContext>();
      _ucBound = true;
      _uc.addListener(_onUserContextChange);
    }

    final currentUid = context.read<UserContext>().actingAsUid;
    if (currentUid != _lastEmailLoadedForUid) {
      _lastEmailLoadedForUid = currentUid;
      unawaited(_loadAthleteEmail());
    }

    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    if (_ucBound) {
      _uc.removeListener(_onUserContextChange);
    }
    routeObserver.unsubscribe(this);
    _activeBlockSub?.cancel();
    debugPrint('🏠 [HOME2] dispose() called');
    super.dispose();
  }

  @override
  void didPopNext() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _fetchTrainingDaysForMonth(_focusedDay);
    });
  }

  // ── UserContext change handler ──────────────────────────────────────────────

  void _onUserContextChange() {
    final uc = Provider.of<UserContext>(context, listen: false);
    final newUid = uc.actingAsUid;

    if (newUid != _lastWarmUid) {
      final prevUid = _lastWarmUid;
      _lastWarmUid = newUid;
      _lastEmailLoadedForUid = newUid;
      debugPrint('🏠 [HOME2] actingAsUid $prevUid → $newUid — refreshing listeners');

      _setupActiveBlockListener(newUid);
      unawaited(_loadAthleteEmail());
      _fetchTrainingDaysForMonth(_focusedDay);
      unawaited(WarmupService.instance.warmWES(newUid));

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final bid = uc.activeBlockId;
        if (bid != null && bid.isNotEmpty) {
          unawaited(BlockExerciseDefaultsRepository.healActiveBlockRirPlan(
            uid: newUid,
            blockId: bid,
          ));
        }
      });
    }
  }

  // ── Block setup helpers ────────────────────────────────────────────────────

  void _setupActiveBlockListener(String uid) {
    _activeBlockSub?.cancel();
    _activeBlockSub = null;
    if (uid.isEmpty) return;
    _activeBlockSub = HomeBootstrapService.setupActiveBlockListener(
      uid: uid,
      onChange: () {
        if (mounted) _fetchTrainingDaysForMonth(_focusedDay);
      },
    );
  }

  void _scheduleRirHeal(UserContext uc) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final uid = uc.actingAsUid;
      final bid = uc.activeBlockId;
      if (uid.isNotEmpty && bid != null && bid.isNotEmpty) {
        unawaited(HomeBootstrapService.healRirPlan(uid: uid, blockId: bid));
      }
    });
  }

  Future<void> _runFirstTimeSetup(String actingUid) async {
    if (!mounted) return;
    setState(() {
      _isFirstTimeSetup = true;
      _setupStatusMessage = '';
    });

    final uc = Provider.of<UserContext>(context, listen: false);
    final ready = await HomeBootstrapService.runFirstTimeSetup(
      uid: actingUid,
      uc: uc,
      onStatus: (msg) {
        if (mounted) setState(() => _setupStatusMessage = msg);
      },
    );

    if (!mounted) return;
    setState(() {
      _blockSetupComplete = ready;
      _isFirstTimeSetup = false;
      _setupStatusMessage = '';
    });
    debugPrint('🏠 [HOME2] first-time setup complete blockSetupComplete=$ready');

    _fetchTrainingDaysForMonth(_focusedDay);
    _setupActiveBlockListener(actingUid);
    _scheduleRirHeal(uc);
  }

  bool _isBlockReady() {
    if (_isFirstTimeSetup) return false;
    if (!_blockSetupComplete) return false;
    final uc = UserContext.of(context, listen: false);
    return uc.activeBlockId != null && uc.activeBlockId!.isNotEmpty;
  }

  void _showBlockNotReadySnack() {
    final msg = _isFirstTimeSetup
        ? 'Setting up your training profile, please wait a moment...'
        : 'Training data is loading, please wait...';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Data helpers ──────────────────────────────────────────────────────────

  Future<void> _loadAthleteEmail() async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = snap.data();
    if (!mounted || data == null) return;

    String? pick(dynamic v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    final chosen =
        pick(data['username']) ??
        pick(data['displayName']) ??
        pick(data['email']) ??
        'Unknown';

    setState(() => _actingAsEmail = chosen);
  }

  Future<void> _persistAvatarLocalIfNeeded(
    BuildContext ctx, {
    required String uid,
    required String photoURL,
  }) async {
    if (_avatarPersistInProgress) return;
    final uc = ctx.read<UserContext>();

    if (uc.localPhotoPath != null) {
      final f = File(uc.localPhotoPath!);
      if (f.existsSync() && await f.length() > 0) return;
    }

    if (_avatarLastUrlSaved == photoURL) return;

    _avatarPersistInProgress = true;
    try {
      final file = await DefaultCacheManager().getSingleFile(photoURL);
      if (!file.existsSync()) return;

      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/avatar_$uid.jpg');
      try {
        if (dest.existsSync()) await dest.delete();
      } catch (_) {}
      await file.copy(dest.path);

      _avatarLastUrlSaved = photoURL;
      uc.setLocalPhotoPath(dest.path);
    } catch (_) {
      // fallback stays as NetworkImage
    } finally {
      _avatarPersistInProgress = false;
    }
  }

  Future<void> _fetchTrainingDaysForMonth(DateTime month) async {
    final uid = Provider.of<UserContext>(context, listen: false).actingAsUid;
    if (uid.isEmpty) return;

    try {
      final blockDoc = await _fetchActiveBlock(uid);
      final data = blockDoc.data() as Map<String, dynamic>;

      final Timestamp startTs = data['startDate'];
      final Timestamp endTs = data['endDate'];
      final DateTime blockStart = startTs.toDate();
      final DateTime blockEnd = endTs.toDate();

      final List<dynamic> blockDays =
          data['selectedDays'] ?? data['daysOfWeek'] ?? [];

      const daysOfWeekMap = {
        'Mon': DateTime.monday,
        'Tue': DateTime.tuesday,
        'Wed': DateTime.wednesday,
        'Thu': DateTime.thursday,
        'Fri': DateTime.friday,
        'Sat': DateTime.saturday,
        'Sun': DateTime.sunday,
      };
      final Set<int> blockWeekdays = blockDays
          .map((d) => daysOfWeekMap[d.toString()])
          .whereType<int>()
          .toSet();

      final firstOfMonth = DateTime(month.year, month.month, 1);
      final lastOfMonth = DateTime(month.year, month.month + 1, 0);

      final from = firstOfMonth.isAfter(blockStart) ? firstOfMonth : blockStart;
      final to = lastOfMonth.isBefore(blockEnd) ? lastOfMonth : blockEnd;

      final trainingDays = <DateTime>{};
      for (var day = from;
          !day.isAfter(to);
          day = day.add(const Duration(days: 1))) {
        if (blockWeekdays.contains(day.weekday)) {
          trainingDays.add(DateTime(day.year, day.month, day.day));
        }
      }

      if (mounted) setState(() => _trainingDays = trainingDays);
    } catch (_) {}
  }

  Future<DocumentSnapshot<Object?>> _fetchActiveBlock(String uid) async {
    if (uid.isEmpty) throw Exception('No UID — cannot fetch active block');

    final query = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) return query.docs.first;
    throw Exception('No active block found');
  }

  // ── Widget helpers ─────────────────────────────────────────────────────────

  Widget _buildQACard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    Widget? iconWidget,
  }) {
    return SizedBox(
      width: kFeatureCardWidth,
      height: 130,
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  child: iconWidget ??
                      Icon(icon, size: 44,
                          color: iconColor ?? Theme.of(context).colorScheme.secondary),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  left: 44,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.3,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQAColumn(Widget top, Widget bottom) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [top, const SizedBox(height: 8), bottom],
    );
  }

  Widget _buildSetupBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _setupStatusMessage,
              textAlign: TextAlign.left,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final uc = context.watch<UserContext>();
    final dmUid = uc.currentUid;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: null,
        automaticallyImplyLeading: false,
        actions: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 15),
                  // Logged-in / impersonated user banner
                  Padding(
                    padding: const EdgeInsets.only(right: 1.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: 95,
                          child: Text(
                            _actingAsEmail ?? '...',
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

                  // Profile picture
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        final userContext = context.read<UserContext>();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ChangeNotifierProvider<UserContext>.value(
                              value: userContext,
                              child: const ProfilePage(),
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(2.0),
                        child: Builder(
                          builder: (context) {
                            final uc = context.watch<UserContext>();
                            final actingUid = uc.actingAsUid;

                            ImageProvider? localAvatar;
                            if (uc.localPhotoPath != null) {
                              final f = File(uc.localPhotoPath!);
                              if (f.existsSync()) localAvatar = FileImage(f);
                            }

                            if (localAvatar != null) {
                              return CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.grey.shade300,
                                backgroundImage: localAvatar,
                              );
                            }

                            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                              stream: FirebaseFirestore.instance
                                  .collection('users_public')
                                  .doc(actingUid)
                                  .snapshots(),
                              builder: (context, snap) {
                                final uc = context.watch<UserContext>();
                                final uid = actingUid;

                                String? photoURL;
                                if (snap.hasData && snap.data!.data() != null) {
                                  final m = snap.data!.data()!;
                                  final v = m['photoURL'];
                                  if (v is String && v.isNotEmpty) photoURL = v;
                                }

                                if ((uc.localPhotoPath == null ||
                                        !(File(uc.localPhotoPath!).existsSync())) &&
                                    photoURL != null) {
                                  _persistAvatarLocalIfNeeded(context,
                                      uid: uid, photoURL: photoURL);
                                }

                                ImageProvider? provider;
                                if (uc.localPhotoPath != null) {
                                  final f = File(uc.localPhotoPath!);
                                  if (f.existsSync()) provider = FileImage(f);
                                }
                                provider ??=
                                    (photoURL != null ? NetworkImage(photoURL) : null);

                                return CircleAvatar(
                                  radius: 18,
                                  backgroundColor: Colors.grey.shade300,
                                  backgroundImage: provider,
                                  child: provider == null
                                      ? ClipOval(
                                          child: Image.asset(
                                            'assets/InApp/Placeholder_profilepic.png',
                                            fit: BoxFit.cover,
                                            width: 36,
                                            height: 36,
                                          ),
                                        )
                                      : null,
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 1),

                  // Buddy invite notifications
                  Builder(
                    builder: (context) {
                      final userCtx = context.watch<UserContext>();
                      final String invitesUid = userCtx.actingAsUid;

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('users')
                            .doc(invitesUid)
                            .collection('buddyInvites')
                            .where('status', isEqualTo: 'pending')
                            .snapshots(),
                        builder: (context, snapshot) {
                          final int buddyCount =
                              snapshot.hasData ? snapshot.data!.docs.length : 0;

                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              IconButton(
                                icon: Icon(Icons.person_add_alt_1,
                                    size: 24,
                                    color: Theme.of(context).colorScheme.secondary),
                                onPressed: () {
                                  if (!snapshot.hasData ||
                                      snapshot.data!.docs.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('No buddy requests.')),
                                    );
                                    return;
                                  }

                                  showDialog(
                                    context: context,
                                    builder: (ctx) {
                                      return AlertDialog(
                                        title: const Text('Buddy Requests'),
                                        content: SizedBox(
                                          width: 310,
                                          child: ListView.builder(
                                            shrinkWrap: true,
                                            itemCount: snapshot.data!.docs.length,
                                            itemBuilder: (_, i) {
                                              final doc =
                                                  snapshot.data!.docs[i];
                                              final data = doc.data()
                                                  as Map<String, dynamic>;
                                              final fromUid =
                                                  data['fromUid'] ?? '';
                                              final fromName =
                                                  data['fromDisplayName'] ??
                                                      'Someone';

                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    '$fromName added you!',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Row(
                                                    children: [
                                                      TextButton(
                                                        onPressed: () async {
                                                          await acceptBuddyInvite(
                                                            ownerUid: fromUid,
                                                            buddyUid: invitesUid,
                                                          );
                                                          Navigator.pop(ctx);
                                                        },
                                                        child: const Text('Accept'),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      TextButton(
                                                        onPressed: () async {
                                                          await denyBuddyInvite(
                                                            ownerUid: fromUid,
                                                            buddyUid: invitesUid,
                                                          );
                                                          Navigator.pop(ctx);
                                                        },
                                                        child: const Text('Deny'),
                                                      ),
                                                    ],
                                                  ),
                                                  const Divider(),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              if (buddyCount > 0)
                                Positioned(
                                  right: 6,
                                  top: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.redAccent,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '$buddyCount',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  ),

                  // DM badge
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(dmUid)
                        .collection('conversations')
                        .where('participants.$dmUid', isEqualTo: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return IconButton(
                          icon: Icon(Icons.message_outlined,
                              size: 26,
                              color: Theme.of(context).colorScheme.secondary),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const DirectMessages(),
                              ),
                            );
                          },
                        );
                      }

                      int unreadCount = 0;
                      final me = FirebaseAuth.instance.currentUser?.uid;

                      if (snapshot.hasData && me != null) {
                        for (var doc in snapshot.data!.docs) {
                          final data = doc.data();
                          final state = data['participantState']?[me];
                          final count = (state is Map &&
                                  state['unreadCount'] is int)
                              ? state['unreadCount'] as int
                              : 0;
                          unreadCount += count;
                        }
                      }

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          IconButton(
                            icon: Icon(Icons.message_outlined,
                                size: 26,
                                color: Theme.of(context).colorScheme.secondary),
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const DirectMessages(),
                                ),
                              );
                            },
                          ),
                          if (unreadCount > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  unreadCount.toString(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(width: 1),

                  // App logo
                  Image.asset(
                    'assets/InApp/transparent_good_lift_logo_inApp.png',
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(width: 2),

                  // Menu icon
                  GestureDetector(
                    onTap: () => _scaffoldKey.currentState?.openDrawer(),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 3.0),
                      child: Icon(Icons.menu, size: 28, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: _isFirstTimeSetup
          ? _buildSetupBody()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Quick Access ──────────────────────────────────────────
                  SizedBox(
                    height: 280.0,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Column 1: Enter Workout / Body Weight Tracker
                          _buildQAColumn(
                            _buildQACard(
                              icon: Icons.fitness_center,
                              label: 'Enter\nWorkout',
                              onTap: () {
                                if (!_isBlockReady()) {
                                  _showBlockNotReadySnack();
                                  return;
                                }
                                final uc = UserContext.of(context, listen: false);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const Wes2Screen(),
                                    ),
                                  ),
                                );
                              },
                              iconWidget: SizedBox(
                                width: 52,
                                height: 56,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Icon(Icons.fitness_center,
                                        size: 44,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .secondary),
                                    Positioned(
                                      right: -2,
                                      bottom: -2,
                                      child: Icon(Icons.bolt,
                                          size: 20,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .tertiary),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            _buildQACard(
                              icon: Icons.monitor_weight,
                              label: 'Body\nWeight\nTracker',
                              onTap: () =>
                                  Navigator.pushNamed(context, '/body_weight'),
                            ),
                          ),
                          // Column 2: Workout Planner / Profile
                          _buildQAColumn(
                            _buildQACard(
                              icon: Icons.view_list,
                              label: 'Workout\nPlanner',
                              onTap: () {
                                if (!_isBlockReady()) {
                                  _showBlockNotReadySnack();
                                  return;
                                }
                                final uc = UserContext.of(context, listen: false);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const TemplatesScreen(),
                                    ),
                                  ),
                                );
                              },
                            ),
                            _buildQACard(
                              icon: Icons.person_outline,
                              label: 'Profile',
                              onTap: () {
                                final uc = UserContext.of(context, listen: false);
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const ProfilePage(),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          // Column 3: Planned Blocks / Week Planner
                          _buildQAColumn(
                            _buildQACard(
                              icon: Icons.track_changes,
                              label: 'Planned\nBlocks',
                              onTap: () {
                                if (_isFirstTimeSetup) {
                                  _showBlockNotReadySnack();
                                  return;
                                }
                                final uc = UserContext.of(context, listen: false);
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const PlannedBlocksScreen(),
                                    ),
                                  ),
                                );
                              },
                            ),
                            _buildQACard(
                              icon: Icons.calendar_view_week,
                              label: 'Week\nPlanner',
                              onTap: () {
                                if (!_isBlockReady()) {
                                  _showBlockNotReadySnack();
                                  return;
                                }
                                final uc = UserContext.of(context, listen: false);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const BB3WeekPlanner(),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          // Column 4: Settings / Coach Dashboard (coach) or empty (non-coach)
                          _buildQAColumn(
                            _buildQACard(
                              icon: Icons.settings_outlined,
                              label: 'Settings',
                              onTap: () {
                                final uc = UserContext.of(context, listen: false);
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ChangeNotifierProvider<UserContext>.value(
                                      value: uc,
                                      child: const UserSettingsScreen(),
                                    ),
                                  ),
                                );
                              },
                            ),
                            UserContext.of(context).isCoach
                                ? _buildQACard(
                                    icon: Icons.supervisor_account,
                                    label: 'Coach\nDashboard',
                                    iconColor: Colors.amberAccent,
                                    onTap: () {
                                      final uc = context.read<UserContext>();
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              ChangeNotifierProvider<
                                                  UserContext>.value(
                                            value: uc,
                                            child: const CoachHomeScreen(),
                                          ),
                                        ),
                                      );
                                    },
                                  )
                                : const SizedBox(
                                    width: kFeatureCardWidth, height: 130),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                  const Text(
                    'Training Calendar',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // ── Calendar ─────────────────────────────────────────────
                  TableCalendar(
                    firstDay: DateTime.utc(2020, 1, 1),
                    lastDay: DateTime.utc(2100, 12, 31),
                    focusedDay: _focusedDay,
                    calendarFormat: CalendarFormat.month,
                    availableCalendarFormats: const {
                      CalendarFormat.month: 'Month',
                    },
                    headerStyle: const HeaderStyle(
                      formatButtonVisible: false,
                      titleCentered: true,
                    ),
                    selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                    eventLoader: (day) {
                      final normalized =
                          DateTime(day.year, day.month, day.day);
                      return _trainingDays.contains(normalized) ? [1] : [];
                    },
                    onDaySelected: (selectedDay, focusedDay) {
                      setState(() {
                        _selectedDay = selectedDay;
                        _focusedDay = focusedDay;
                      });

                      if (!_isBlockReady()) {
                        _showBlockNotReadySnack();
                        return;
                      }

                      final userContext =
                          UserContext.of(context, listen: false);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ChangeNotifierProvider<UserContext>.value(
                            value: userContext,
                            child: Wes2Screen(initialDate: selectedDay),
                          ),
                        ),
                      );
                    },
                    onPageChanged: (focusedDay) {
                      setState(() => _focusedDay = focusedDay);
                      _fetchTrainingDaysForMonth(focusedDay);
                    },
                    calendarBuilders: CalendarBuilders(
                      defaultBuilder: (context, date, _) {
                        final isTraining = _trainingDays.contains(
                            DateTime(date.year, date.month, date.day));
                        return Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: isTraining
                                ? Border.all(
                                    color:
                                        Theme.of(context).colorScheme.tertiary,
                                    width: 2,
                                  )
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${date.day}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        );
                      },
                      todayBuilder: (context, date, _) {
                        return Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white24,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.tertiary,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${date.day}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      },
                      selectedBuilder: (context, date, _) {
                        return Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context).colorScheme.primary,
                            border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.secondary,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${date.day}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 1),

                  // ── Feed Switcher ─────────────────────────────────────────
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Row(
                      children: [
                        SegmentedButton<_HomeV2Feed>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment<_HomeV2Feed>(
                              value: _HomeV2Feed.home,
                              icon: Icon(Icons.photo_library_outlined, size: 16),
                              label: SizedBox.shrink(),
                            ),
                            ButtonSegment<_HomeV2Feed>(
                              value: _HomeV2Feed.points,
                              icon: Icon(Icons.leaderboard_outlined, size: 16),
                              label: SizedBox.shrink(),
                            ),
                            ButtonSegment<_HomeV2Feed>(
                              value: _HomeV2Feed.leaderboard,
                              icon: Icon(Icons.emoji_events_outlined, size: 16),
                              label: SizedBox.shrink(),
                            ),
                          ],
                          selected: <_HomeV2Feed>{_selectedFeed},
                          onSelectionChanged: (s) {
                            final next = s.first;
                            if (_selectedFeed == next) return;
                            setState(() => _selectedFeed = next);
                          },
                          style: ButtonStyle(
                            padding: MaterialStateProperty.all(
                                const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2)),
                            visualDensity: const VisualDensity(
                                horizontal: -4, vertical: -4),
                            side:
                                MaterialStateProperty.resolveWith((states) {
                              final selected =
                                  states.contains(MaterialState.selected);
                              return BorderSide(
                                  color: selected
                                      ? Colors.white70
                                      : Colors.white24,
                                  width: 1);
                            }),
                            backgroundColor:
                                MaterialStateProperty.resolveWith((states) {
                              final selected =
                                  states.contains(MaterialState.selected);
                              return selected
                                  ? Colors.white12
                                  : Colors.transparent;
                            }),
                            shape: MaterialStateProperty.all(
                              RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            foregroundColor:
                                MaterialStateProperty.all(Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Feed stubs ────────────────────────────────────────────
                  if (_selectedFeed == _HomeV2Feed.home)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'Feed coming soon',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  else if (_selectedFeed == _HomeV2Feed.points)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'Points feed coming soon',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'Leaderboard coming soon',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
