import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'dart:ui' show FontFeature;

import 'profile/ui/live_identity.dart';

enum LeaderboardPeriod { monthly, allTime }

class LeaderboardPage extends StatefulWidget {
  final bool embedMode;
  const LeaderboardPage({Key? key, this.embedMode = false}) : super(key: key);

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  LeaderboardPeriod _period = LeaderboardPeriod.allTime;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _makeStream();
    debugPrint('🏁 [Leaderboard] initState → period=${_period.name}');
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _makeStream() {
    final users = FirebaseFirestore.instance.collection('users_public');
    if (_period == LeaderboardPeriod.monthly) {
      // mirror for the **current** month (lazy reset via CF later)
      return users
          .orderBy('rePointsMonthlyCurrent', descending: true)
          .limit(100)
          .snapshots();
    } else {
      return users.orderBy('rePoints', descending: true).limit(100).snapshots();
    }
  }

  void _setPeriod(LeaderboardPeriod p) {
    if (_period == p) return;
    setState(() {
      _period = p;
      _stream = _makeStream();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cyan = Colors.cyanAccent;
    final secondary = Colors.blueGrey.shade600;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        centerTitle: true,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: SegmentedButton<LeaderboardPeriod>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: LeaderboardPeriod.monthly,
                icon: Icon(Icons.calendar_month, size: 16),
                label: Text('Monthly'),
              ),
              ButtonSegment(
                value: LeaderboardPeriod.allTime,
                icon: Icon(Icons.timeline, size: 16),
                label: Text('All Time'),
              ),
            ],
            selected: <LeaderboardPeriod>{_period},
            onSelectionChanged: (s) => _setPeriod(s.first),
            style: ButtonStyle(
              padding: MaterialStateProperty.all(
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
              visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
              side: MaterialStateProperty.resolveWith((states) {
                final selected = states.contains(MaterialState.selected);
                return BorderSide(
                    color: selected ? Colors.white70 : Colors.white24,
                    width: 1);
              }),
              backgroundColor: MaterialStateProperty.resolveWith((states) {
                final selected = states.contains(MaterialState.selected);
                return selected ? Colors.white12 : Colors.transparent;
              }),
              foregroundColor: MaterialStateProperty.all(Colors.white),
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.active) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2));
          }

          debugPrint(
              '📊 [Leaderboard] ${_period.name} docs=${snap.data?.docs.length ?? 0}');
          final docs = snap.data?.docs ?? const [];

// Build local list (even if points missing)
          final items = <Map<String, dynamic>>[];
          for (final d in docs) {
            final m = d.data();

            // users_public doc id IS the uid. The stored displayName /
            // fullName are the fallback; the row resolves the CURRENT username
            // by uid so a rename reaches the leaderboard without a restart.
            final fallbackName =
                (m['displayName'] ?? m['fullName'] ?? '') as String;
            final points = (_period == LeaderboardPeriod.monthly)
                ? (m['rePointsMonthlyCurrent'] as num?)?.toDouble() ?? 0.0
                : (m['rePoints'] as num?)?.toDouble() ?? 0.0;

            final byLift = (_period == LeaderboardPeriod.monthly)
                ? Map<String, dynamic>.from(
                    m['rePointsMonthlyByLiftCurrent'] ?? const {})
                : Map<String, dynamic>.from(m['rePointsByLift'] ?? const {});

            items.add({
              'uid': d.id,
              'name': fallbackName,
              'points': points,
              'byLift': byLift,
            });
          }

// Always show users, even with 0 points
          items.sort((a, b) =>
              (b['points'] as double).compareTo(a['points'] as double));

          if (items.isEmpty) {
            return const Center(
              child:
                  Text('No users yet', style: TextStyle(color: Colors.white70)),
            );
          }

          // Build winners per lift (client-side fallback).
          // Keys must match your canonical keys in stats_snapshot.dart.

          const squat = 'Back Squat, Barbell';
          const bench = 'Bench Press, Barbell';
          const dead = 'Deadlift, Conventional';
          const chin = 'Chin-Up';
          const ohp = 'Overhead Dumbbell Press, Unilateral';

// Build top-3 unique thresholds per lift (ties allowed)
          const double _eps = 1e-9;

          List<double> _top3UniqueFor(String k) {
            // collect all values > 0 for this lift
            final vals = <double>[];
            for (final row in items) {
              final byLift = Map<String, dynamic>.from(row['byLift'] as Map);
              final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
              if (v > 0) vals.add(v);
            }
            if (vals.isEmpty) return const <double>[];

            // sort descending
            vals.sort((a, b) => b.compareTo(a));

            // take unique values with epsilon tolerance
            final unique = <double>[];
            for (final v in vals) {
              if (unique.isEmpty || (unique.last - v).abs() > _eps) {
                unique.add(v);
                if (unique.length == 3) break; // only need top 3
              }
            }
            return unique;
          }

          final top3Thresholds = <String, List<double>>{
            bench: _top3UniqueFor(bench),
            squat: _top3UniqueFor(squat),
            dead: _top3UniqueFor(dead),
            chin: _top3UniqueFor(chin),
            ohp: _top3UniqueFor(ohp),
          };

// Return 1,2,3 for medal tier, or null if not in top-3
          int? _tierFor(String lift, Map<String, dynamic> byLift) {
            final v = (byLift[lift] as num?)?.toDouble() ?? 0.0;
            if (v <= 0) return null;
            final th = top3Thresholds[lift] ?? const <double>[];
            if (th.isEmpty) return null;
            if ((v - th[0]).abs() < _eps) return 1; // gold
            if (th.length > 1 && (v - th[1]).abs() < _eps) return 2; // silver
            if (th.length > 2 && (v - th[2]).abs() < _eps) return 3; // bronze
            return null;
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final row = items[index];

              final rank = index + 1;
              final uid = row['uid'] as String;
              final fallbackName = row['name'] as String;
              final points = row['points'] as double;
              final byLift = Map<String, dynamic>.from(row['byLift'] as Map);

              Widget medalChip(String label, int? tier) {
                const Color _bronze = Color(0xFFCD7F32);

                final Color? tierColor = switch (tier) {
                  1 => Colors.amberAccent,
                  2 => Colors.white70,
                  3 => _bronze,
                  _ => null,
                };

                final bool hasMedal = tier != null;

                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: hasMedal
                        ? (tierColor ?? Colors.cyanAccent).withOpacity(0.18)
                        : Colors.transparent,
                    border: Border.all(
                      color: hasMedal
                          ? (tierColor ?? Colors.cyanAccent)
                          : Colors.white24,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: hasMedal
                          ? (tierColor ?? Colors.cyanAccent)
                          : Colors.white70,
                      fontWeight: hasMedal ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                );
              }

              return Container(
                decoration: BoxDecoration(
                  color: secondary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  leading: CircleAvatar(
                    backgroundColor: Colors.white10,
                    child: Text('$rank',
                        style: const TextStyle(color: Colors.white)),
                  ),
                  title: LiveUserName(
                    uid: uid,
                    fallback: fallbackName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Row(
                    children: [
                      Text(points.toStringAsFixed(0),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      const SizedBox(width: 8),
                      const Text('RE Points',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(
                        maxWidth: 160), // tweak 140–200 as needed
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          medalChip('S', _tierFor(squat, byLift)),
                          medalChip('B', _tierFor(bench, byLift)),
                          medalChip('D', _tierFor(dead, byLift)),
                          medalChip('C', _tierFor(chin, byLift)),
                          medalChip('O', _tierFor(ohp, byLift)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class LeaderboardEmbedded extends StatefulWidget {
  const LeaderboardEmbedded({super.key});

  @override
  State<LeaderboardEmbedded> createState() => _LeaderboardEmbeddedState();
}

class _LeaderboardEmbeddedState extends State<LeaderboardEmbedded> {
  LeaderboardPeriod _period = LeaderboardPeriod.allTime;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _makeStream();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _makeStream() {
    final users = FirebaseFirestore.instance.collection('users_public');
    if (_period == LeaderboardPeriod.monthly) {
      return users
          .orderBy('rePointsMonthlyCurrent', descending: true)
          .limit(200)
          .snapshots();
    } else {
      return users.orderBy('rePoints', descending: true).limit(200).snapshots();
    }
  }

  void _setPeriod(LeaderboardPeriod p) {
    if (_period == p) return;
    setState(() {
      _period = p;
      _stream = _makeStream();
    });
  }

  @override
  @override
  Widget build(BuildContext context) {
    // colors
    final cyan = Colors.cyanAccent;
    final rowBg = Colors.blueGrey.shade600;
    // ── column widths (compact + more space for Name)
    const double kHPad = 3; // page left/right padding
    const double kGap = 6; // gap between columns
    const double kRankW = 8; // "#"
    const double kPtsW = 56; // RE pts (narrower to give Name more room)
    const double kMedalSlotW = 26; // single medal slot (compact chip)
    const double kMedalGap = 0; // no gaps between medals
    const double kMedalsW = (kMedalSlotW * 5); // total medals area width

    // Small chip used for medals
    Widget medalChip(String label, int? tier) {
      const Color _bronze = Color(0xFFCD7F32);

      final Color? tierColor = switch (tier) {
        1 => Colors.amberAccent,
        2 => Colors.white70,
        3 => _bronze,
        _ => null,
      };

      final bool hasMedal = tier != null;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: hasMedal
              ? (tierColor ?? Colors.cyanAccent).withOpacity(0.18)
              : Colors.transparent,
          border: Border.all(
            color: hasMedal ? (tierColor ?? Colors.cyanAccent) : Colors.white24,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: hasMedal ? (tierColor ?? Colors.cyanAccent) : Colors.white70,
            fontWeight: hasMedal ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: Colors.black, // 👈 black from selector downward, edge-to-edge
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ----- Monthly / All-Time selector (inline, on black) -----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Align(
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: SegmentedButton<LeaderboardPeriod>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: LeaderboardPeriod.monthly,
                      icon: Icon(Icons.calendar_month, size: 16),
                      label: Text('Monthly'),
                    ),
                    ButtonSegment(
                      value: LeaderboardPeriod.allTime,
                      icon: Icon(Icons.timeline, size: 16),
                      label: Text('All Time'),
                    ),
                  ],
                  selected: <LeaderboardPeriod>{_period},
                  onSelectionChanged: (s) => _setPeriod(s.first),
                  style: ButtonStyle(
                    padding: MaterialStateProperty.all(
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
                    visualDensity:
                        const VisualDensity(horizontal: -3, vertical: -3),
                    side: MaterialStateProperty.resolveWith((states) {
                      final selected = states.contains(MaterialState.selected);
                      return BorderSide(
                          color: selected ? Colors.white70 : Colors.white24,
                          width: 1);
                    }),
                    backgroundColor:
                        MaterialStateProperty.resolveWith((states) {
                      final selected = states.contains(MaterialState.selected);
                      return selected ? Colors.white12 : Colors.transparent;
                    }),
                    foregroundColor: MaterialStateProperty.all(Colors.white),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 6),

          // ---- Table-style header (aligned to fixed widths) ----
          Padding(
            padding: const EdgeInsets.fromLTRB(kHPad, 0, kHPad, 4),
            child: Column(
              children: [
                // Top header row
                Row(
                  children: [
                    // #
                    const SizedBox(
                      width: kRankW,
                      child: Text(
                        '#',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white54, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: kGap),

                    // Name
                    const Expanded(
                      child: Text(
                        'Name',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),

                    const SizedBox(width: kGap),

                    // RE pts
                    const SizedBox(
                      width: kPtsW,
                      child: Text(
                        'RE pts',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),

                    const SizedBox(width: kGap),

                    // Medals title (fixed area equal to row medals area)
                    const SizedBox(
                      width: kMedalsW,
                      child: Text(
                        'Medals',
                        style: TextStyle(
                            color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 2),

                // Sub-header row under medals
                Row(
                  children: [
                    const SizedBox(width: kRankW),
                    const SizedBox(width: kGap),
                    const Expanded(child: SizedBox()), // under Name
                    const SizedBox(width: kGap),
                    const SizedBox(width: kPtsW), // under RE pts
                    const SizedBox(width: kGap),

                    // 5 evenly-sized labels in the medals area
                    SizedBox(
                      width: kMedalsW,
                      child: Row(
                        children: const [
                          SizedBox(
                              width: kMedalSlotW,
                              child: Text('Sqt',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11))),
                          SizedBox(width: kMedalGap),
                          SizedBox(
                              width: kMedalSlotW,
                              child: Text('Bnch',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11))),
                          SizedBox(width: kMedalGap),
                          SizedBox(
                              width: kMedalSlotW,
                              child: Text('DL',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11))),
                          SizedBox(width: kMedalGap),
                          SizedBox(
                              width: kMedalSlotW,
                              child: Text('C-Up',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11))),
                          SizedBox(width: kMedalGap),
                          SizedBox(
                              width: kMedalSlotW,
                              child: Text('ODP',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 11))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),

                const SizedBox(height: 6),
                const Divider(height: 1, color: Colors.white24),
              ],
            ),
          ),

          // ----- List -----
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.active) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }

              final docs = snap.data?.docs ?? const [];

              // Build items (show even if no points -> 0)
              final items = <Map<String, dynamic>>[];
              for (final d in docs) {
                final m = d.data();
                final fallbackName =
                    (m['displayName'] ?? m['fullName'] ?? '') as String;

                final points = (_period == LeaderboardPeriod.monthly)
                    ? (m['rePointsMonthlyCurrent'] as num?)?.toDouble() ?? 0.0
                    : (m['rePoints'] as num?)?.toDouble() ?? 0.0;

                final byLift = (_period == LeaderboardPeriod.monthly)
                    ? Map<String, dynamic>.from(
                        m['rePointsMonthlyByLiftCurrent'] ?? const {})
                    : Map<String, dynamic>.from(
                        m['rePointsByLift'] ?? const {});

                items.add({
                  'uid': d.id,
                  'name': fallbackName,
                  'points': points,
                  'byLift': byLift,
                });
              }

              // Sort by points desc so ranks are stable
              items.sort((a, b) =>
                  (b['points'] as double).compareTo(a['points'] as double));

              if (items.isEmpty) {
                // Monthly likely missing — still show empty list frame
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('No users yet',
                        style: TextStyle(color: Colors.white70)),
                  ),
                );
              }

              // Max per lift (for medals)
              // Canonical lift keys (unchanged)
              const squat = 'Back Squat, Barbell';
              const bench = 'Bench Press, Barbell';
              const dead = 'Deadlift, Conventional';
              const chin = 'Chin-Up';
              const ohp = 'Overhead Dumbbell Press, Unilateral';

// Build top-3 unique thresholds per lift (ties allowed)
              const double _eps = 1e-9;

              List<double> _top3UniqueFor(String k) {
                // collect all values > 0 for this lift
                final vals = <double>[];
                for (final row in items) {
                  final byLift =
                      Map<String, dynamic>.from(row['byLift'] as Map);
                  final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
                  if (v > 0) vals.add(v);
                }
                if (vals.isEmpty) return const <double>[];

                // sort descending
                vals.sort((a, b) => b.compareTo(a));

                // take unique values with epsilon tolerance
                final unique = <double>[];
                for (final v in vals) {
                  if (unique.isEmpty || (unique.last - v).abs() > _eps) {
                    unique.add(v);
                    if (unique.length == 3) break; // only need top 3
                  }
                }
                return unique;
              }

              final top3Thresholds = <String, List<double>>{
                bench: _top3UniqueFor(bench),
                squat: _top3UniqueFor(squat),
                dead: _top3UniqueFor(dead),
                chin: _top3UniqueFor(chin),
                ohp: _top3UniqueFor(ohp),
              };

// Return 1,2,3 for medal tier, or null if not in top-3
              int? _tierFor(String lift, Map<String, dynamic> byLift) {
                final v = (byLift[lift] as num?)?.toDouble() ?? 0.0;
                if (v <= 0) return null;
                final th = top3Thresholds[lift] ?? const <double>[];
                if (th.isEmpty) return null;
                if ((v - th[0]).abs() < _eps) return 1; // gold
                if (th.length > 1 && (v - th[1]).abs() < _eps)
                  return 2; // silver
                if (th.length > 2 && (v - th[2]).abs() < _eps)
                  return 3; // bronze
                return null;
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final row = items[index];
                  final rank = index + 1;
                  final uid = row['uid'] as String;
                  final fallbackName = row['name'] as String;
                  final pts = row['points'] as double;
                  final byLift =
                      Map<String, dynamic>.from(row['byLift'] as Map);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: EdgeInsets.only(right: kHPad, top: 10, bottom: 10),
                    decoration: const BoxDecoration(
                      color: Colors.black, // black rows; easy to toggle later
                      borderRadius: BorderRadius.zero,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Rank
                        SizedBox(
                          width: kRankW,
                          child: Text(
                            '$rank',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: kGap),

                        // Name (expands)
                        Expanded(
                          child: LiveUserName(
                            uid: uid,
                            fallback: fallbackName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                        ),

                        const SizedBox(width: kGap),

                        // RE pts (fixed, right-aligned)
                        SizedBox(
                          width: kPtsW,
                          child: Text(
                            pts.toStringAsFixed(1),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),

                        const SizedBox(width: kGap),

                        // Medals: 5 fixed slots (aligns perfectly with subheader)
                        SizedBox(
                          width: (kMedalSlotW *
                              5), // total width = 5 slots, no extra gaps
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              SizedBox(
                                  width: kMedalSlotW,
                                  child: Center(
                                      child: medalChip(
                                          'S', _tierFor(squat, byLift)))),
                              SizedBox(
                                  width: kMedalSlotW,
                                  child: Center(
                                      child: medalChip(
                                          'B', _tierFor(bench, byLift)))),
                              SizedBox(
                                  width: kMedalSlotW,
                                  child: Center(
                                      child: medalChip(
                                          'D', _tierFor(dead, byLift)))),
                              SizedBox(
                                  width: kMedalSlotW,
                                  child: Center(
                                      child: medalChip(
                                          'C', _tierFor(chin, byLift)))),
                              SizedBox(
                                  width: kMedalSlotW,
                                  child: Center(
                                      child: medalChip(
                                          'O', _tierFor(ohp, byLift)))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
