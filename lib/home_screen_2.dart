import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';

import 'app_drawer.dart';
import 'app_theme.dart';
import 'bb3_week_planner.dart';
import 'coach_home_screen.dart';
import 'home_v2_app_bar.dart';
import 'home_v2_calendar_service.dart';
import 'home_v2_controller.dart';
import 'main.dart';
import 'planned_blocks_screen.dart';
import 'profile_page.dart';
import 'templates.dart';
import 'user_context.dart';
import 'user_settings.dart';
import 'membership_gate.dart';
import 'startup_trace.dart';

// Private to this file — avoids name collision with home_screen.dart's SelectedFeed.
enum _HomeV2Feed { home, points, leaderboard }

class HomeScreen2 extends StatefulWidget {
  const HomeScreen2({super.key});

  @override
  State<HomeScreen2> createState() => _HomeScreen2State();
}

class _HomeScreen2State extends State<HomeScreen2> with RouteAware {
  final HomeV2Controller _ctrl = HomeV2Controller();
  late final UserContext _uc;
  bool _ucBound = false;
  bool _startupDone = false;
  bool _tracedFirstBuild = false;
  String _lastActingUid = '';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const double kFeatureCardWidth = 150;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  _HomeV2Feed _selectedFeed = _HomeV2Feed.home;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    debugPrint('🏠 [HOME2:initState] created');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_ucBound) {
      _uc = context.read<UserContext>();
      _ucBound = true;
      _uc.addListener(_onUserContextChange);
      _ctrl.addListener(_onControllerNotify);
    }

    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);

    if (!_startupDone) {
      _startupDone = true;
      final uc = Provider.of<UserContext>(context, listen: false);
      _lastActingUid = uc.actingAsUid;
      unawaited(_ctrl.onInitialStartup(uc: uc, initialMonth: _focusedDay));
    }
  }

  @override
  void dispose() {
    if (_ucBound) {
      _uc.removeListener(_onUserContextChange);
      _ctrl.removeListener(_onControllerNotify);
    }
    routeObserver.unsubscribe(this);
    _ctrl.dispose();
    debugPrint('🏠 [HOME2] dispose()');
    super.dispose();
  }

  @override
  void didPopNext() {
    if (!mounted) return;
    // Defence-in-depth: drop any focus left over from the route above (e.g. a
    // WES2 numeric field) so an orphaned iOS keyboard cannot linger over Home.
    // Safe here because didPopNext only fires on return from a child route,
    // where Home has no legitimately-focused input. NOT a blanket build()
    // unfocus — the root-cause fix is WES2's _exitToHome.
    FocusManager.instance.primaryFocus?.unfocus();
    final uc = Provider.of<UserContext>(context, listen: false);
    unawaited(_ctrl.onReturnedToHome(
      actingUid: uc.actingAsUid,
      month: _focusedDay,
    ));
  }

  // ── Listeners ──────────────────────────────────────────────────────────────

  void _onControllerNotify() {
    if (mounted) setState(() {});
  }

  void _onUserContextChange() {
    if (!mounted || !_ucBound) return;
    final uc = Provider.of<UserContext>(context, listen: false);
    final newUid = uc.actingAsUid;
    if (newUid == _lastActingUid) return;
    _lastActingUid = newUid;
    unawaited(_ctrl.onActingUserChanged(
      newUid: newUid,
      uc: uc,
      month: _focusedDay,
    ));
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  bool _isBlockReady() {
    if (_ctrl.isFirstTimeSetup) return false;
    if (!_ctrl.blockSetupComplete) return false;
    final uc = UserContext.of(context, listen: false);
    return uc.activeBlockId?.isNotEmpty == true;
  }

  void _showBlockNotReadySnack() {
    final msg = _ctrl.isFirstTimeSetup
        ? 'Setting up your training profile, please wait a moment...'
        : 'Training data is loading, please wait...';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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
                          color: iconColor ??
                              Theme.of(context).colorScheme.secondary),
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
              _ctrl.setupStatusMessage,
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

  // ── Calendar day helper ────────────────────────────────────────────────────

  /// Builds a single calendar day cell with the correct state visual.
  /// Colours come from [_HomeV2CalendarColors.of] — see that class for sourcing.
  Widget _buildCalendarDay(
    BuildContext context,
    DateTime date,
    HomeV2CalendarDayKind kind, {
    bool isToday = false,
    bool isSelected = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final cc = _HomeV2CalendarColors.of(context);

    Color? bgColor;
    if (isSelected) {
      bgColor = cs.primary;
    } else if (isToday) {
      bgColor = Colors.white24;
    }

    if (kind == HomeV2CalendarDayKind.mixed) {
      return Padding(
        padding: const EdgeInsets.all(6),
        // StackFit.expand forces the Container to fill the painted circle area,
        // which matters when bgColor is set (today/selected states).
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bgColor,
              ),
              alignment: Alignment.center,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: isToday ? FontWeight.bold : null,
                ),
              ),
            ),
            CustomPaint(
              painter: _SplitCirclePainter(
                topColor: cc.completed,
                bottomColor: cc.planned,
              ),
            ),
          ],
        ),
      );
    }

    Color? borderColor;
    if (isSelected) {
      borderColor = cs.secondary;
    } else if (isToday) {
      borderColor = cs.tertiary;
    } else if (kind == HomeV2CalendarDayKind.planned) {
      borderColor = cc.planned;
    } else if (kind == HomeV2CalendarDayKind.completed) {
      borderColor = cc.completed;
    }

    return Container(
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        border: borderColor != null
            ? Border.all(color: borderColor, width: 2)
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        '${date.day}',
        style: TextStyle(
          color: Colors.white,
          fontWeight: isToday ? FontWeight.bold : null,
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watch UserContext so the coach-check and uc-bound widgets stay reactive.
    context.watch<UserContext>();

    if (!_tracedFirstBuild) {
      _tracedFirstBuild = true;
      StartupTrace.homeFirstBuild();
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: HomeV2AppBar(
        scaffoldKey: _scaffoldKey,
        displayName: _ctrl.actingDisplayName,
      ),
      drawer: const AppDrawer(),
    body: SafeArea(
    top: false,
    minimum: const EdgeInsets.only(bottom: 16),
    child: _ctrl.isFirstTimeSetup
    ? _buildSetupBody()
        : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Quick Access ──────────────────────────────────────────
                  SizedBox(
                    height: (!_ctrl.wpDone || !_ctrl.wesDone) ? 296.0 : 280.0,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Column 1: Enter Workout / Body Weight Tracker
                          _buildQAColumn(
                            _GlowingCueWrapper(
                              active: _ctrl.wpDone && !_ctrl.wesDone,
                              label: 'Tap here next',
                              child: _buildQACard(
                                icon: Icons.fitness_center,
                                label: 'Enter\nWorkout',
                                onTap: () {
                                  if (!_isBlockReady()) {
                                    _showBlockNotReadySnack();
                                    return;
                                  }
                                  final uc =
                                      UserContext.of(context, listen: false);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ChangeNotifierProvider<UserContext>.value(
                                        value: uc,
                                        child: gatedWes2(),
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
                            _GlowingCueWrapper(
                              active: !_ctrl.wpDone,
                              label: 'Tap here first',
                              child: _buildQACard(
                                icon: Icons.view_list,
                                label: 'Workout\nPlanner',
                                onTap: () {
                                  if (!_isBlockReady()) {
                                    _showBlockNotReadySnack();
                                    return;
                                  }
                                  final uc =
                                      UserContext.of(context, listen: false);
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
                            ),
                            _buildQACard(
                              icon: Icons.person_outline,
                              label: 'Profile',
                              onTap: () {
                                final uc =
                                    UserContext.of(context, listen: false);
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
                                if (_ctrl.isFirstTimeSetup) {
                                  _showBlockNotReadySnack();
                                  return;
                                }
                                final uc =
                                    UserContext.of(context, listen: false);
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
                                final uc =
                                    UserContext.of(context, listen: false);
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
                          // Column 4: Settings / Coach Dashboard (coach only)
                          _buildQAColumn(
                            _buildQACard(
                              icon: Icons.settings_outlined,
                              label: 'Settings',
                              onTap: () {
                                final uc =
                                    UserContext.of(context, listen: false);
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

                  const SizedBox(height: 3),


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
                    onDaySelected: (selectedDay, focusedDay) {
                      setState(() {
                        _selectedDay = selectedDay;
                        _focusedDay = focusedDay;
                      });
                      _ctrl.updateFocusedMonth(focusedDay);

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
                            child: gatedWes2(initialDate: selectedDay),
                          ),
                        ),
                      );
                    },
                    onPageChanged: (focusedDay) {
                      setState(() => _focusedDay = focusedDay);
                      _ctrl.updateFocusedMonth(focusedDay);
                      unawaited(_ctrl.refreshCalendar(
                        focusedDay,
                        uid: Provider.of<UserContext>(context, listen: false)
                            .actingAsUid,
                      ));
                    },
                    calendarBuilders: CalendarBuilders(
                      defaultBuilder: (context, date, _) {
                        final kind = _ctrl.dayKindFor(date);
                        return _buildCalendarDay(context, date, kind);
                      },
                      todayBuilder: (context, date, _) {
                        final kind = _ctrl.dayKindFor(date);
                        return _buildCalendarDay(context, date, kind,
                            isToday: true);
                      },
                      selectedBuilder: (context, date, _) {
                        final kind = _ctrl.dayKindFor(date);
                        return _buildCalendarDay(context, date, kind,
                            isSelected: true);
                      },
                    ),
                  ),

                  const SizedBox(height: 1),

                  // ── Feed Switcher ─────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 2, vertical: 2),
                    child: Row(
                      children: [
                        SegmentedButton<_HomeV2Feed>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment<_HomeV2Feed>(
                              value: _HomeV2Feed.home,
                              icon: Icon(Icons.photo_library_outlined,
                                  size: 16),
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
                            side: MaterialStateProperty.resolveWith(
                                (states) {
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
                       // child: Text('New Feed coming soon',style: TextStyle(color: Colors.white54),),
                      ),
                    )
                  else if (_selectedFeed == _HomeV2Feed.points)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        //child: Text('New Points feed coming soon',style: TextStyle(color: Colors.white54),),
                      ),
                    )
                  else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                       // child: Text('New Leaderboard coming soon', style: TextStyle(color: Colors.white54),                        ),
                      ),
                    ),
                ],
              ),
            ),
    ),
    );
  }
}

// ── Calendar colour tokens ─────────────────────────────────────────────────────
// GoodLift's AppTheme defines four user-configurable colour slots:
//   primary    (chrome/scaffold)
//   secondary  (active/selected)
//   tertiary   (accent / training-day planned indicator)
//   quaternary (completed/success — via GoodLiftColors ThemeExtension)
class _HomeV2CalendarColors {
  const _HomeV2CalendarColors({
    required this.planned,
    required this.completed,
  });

  /// Training-day planned indicator — user's theme accent (colorScheme.tertiary).
  final Color planned;

  /// Workout completed indicator — user's quaternary colour from [GoodLiftColors]
  /// ThemeExtension; falls back to [AppTheme.defaultQuaternary] if the extension
  /// is somehow absent (should not happen in normal app builds).
  final Color completed;

  static _HomeV2CalendarColors of(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gl = Theme.of(context).extension<GoodLiftColors>();
    return _HomeV2CalendarColors(
      planned:   cs.tertiary,
      completed: gl?.quaternary ?? AppTheme.defaultQuaternary,
    );
  }
}

// ── Split-circle painter ───────────────────────────────────────────────────────
// Draws a circle border split into top and bottom halves with separate colours.
// Top half  = completed state colour (quaternary).
// Bottom half = planned state colour (tertiary).
//
// Flutter canvas angle convention: 0 = 3-o'clock, angles increase CLOCKWISE
// because the y-axis points downward.
//   Top half    = 9-o'clock → CW through 12-o'clock → 3-o'clock
//                 startAngle=π, sweepAngle=+π
//   Bottom half = 3-o'clock → CW through 6-o'clock  → 9-o'clock
//                 startAngle=0, sweepAngle=+π
class _SplitCirclePainter extends CustomPainter {
  final Color topColor;
  final Color bottomColor;

  const _SplitCirclePainter({
    required this.topColor,
    required this.bottomColor,
  });

  static const double _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - _stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = _stroke;

    // Top half: 9-o'clock clockwise through 12-o'clock to 3-o'clock.
    paint.color = topColor;
    canvas.drawArc(rect, math.pi, math.pi, false, paint);

    // Bottom half: 3-o'clock clockwise through 6-o'clock to 9-o'clock.
    paint.color = bottomColor;
    canvas.drawArc(rect, 0, math.pi, false, paint);
  }

  @override
  bool shouldRepaint(_SplitCirclePainter old) =>
      old.topColor != topColor || old.bottomColor != bottomColor;
}

// ── Glowing cue wrapper ────────────────────────────────────────────────────────
// Wraps a Quick Access card with an animated colour-cycling glow border and a
// small label above it. Renders the child unchanged when active is false.
class _GlowingCueWrapper extends StatefulWidget {
  final bool active;
  final String label;
  final Widget child;
  const _GlowingCueWrapper({
    required this.active,
    required this.label,
    required this.child,
  });

  @override
  State<_GlowingCueWrapper> createState() => _GlowingCueWrapperState();
}

class _GlowingCueWrapperState extends State<_GlowingCueWrapper>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final AnimationController _nudgeCtrl;
  late final Animation<double> _nudgeAnim;
  Timer? _nudgeTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _nudgeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _nudgeAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -4.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -4.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_nudgeCtrl);

    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _nudgeCtrl.forward(from: 0);
    });
    _nudgeTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (mounted) _nudgeCtrl.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _ctrl.dispose();
    _nudgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final color = Color.lerp(cs.secondary, cs.tertiary, _ctrl.value)!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _nudgeAnim,
              builder: (_, child) => Transform.translate(
                offset: Offset(0, _nudgeAnim.value),
                child: child,
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color.withValues(alpha: 0.9),
                ),
              ),
            ),
            const SizedBox(height: 2),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: widget.child,
            ),
          ],
        );
      },
    );
  }
}
