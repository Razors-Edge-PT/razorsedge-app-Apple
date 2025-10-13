import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

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
              visualDensity:
              const VisualDensity(horizontal: -3, vertical: -3),
              side: MaterialStateProperty.resolveWith((states) {
                final selected = states.contains(MaterialState.selected);
                return BorderSide(
                    color: selected ? Colors.white70 : Colors.white24, width: 1);
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

          debugPrint('📊 [Leaderboard] ${_period.name} docs=${snap.data?.docs.length ?? 0}');
          final docs = snap.data?.docs ?? const [];

// Build local list (even if points missing)
          final items = <Map<String, dynamic>>[];
          for (final d in docs) {
            final m = d.data();

            final displayName = (m['displayName'] ?? m['fullName'] ?? 'User') as String;
            final points = (_period == LeaderboardPeriod.monthly)
                ? (m['rePointsMonthlyCurrent'] as num?)?.toDouble() ?? 0.0
                : (m['rePoints'] as num?)?.toDouble() ?? 0.0;

            final byLift = (_period == LeaderboardPeriod.monthly)
                ? Map<String, dynamic>.from(m['rePointsMonthlyByLiftCurrent'] ?? const {})
                : Map<String, dynamic>.from(m['rePointsByLift'] ?? const {});

            items.add({
              'name': displayName,
              'points': points,
              'byLift': byLift,
            });
          }

// Always show users, even with 0 points
          items.sort((a, b) => (b['points'] as double).compareTo(a['points'] as double));

          if (items.isEmpty) {
            return const Center(
              child: Text('No users yet', style: TextStyle(color: Colors.white70)),
            );
          }



          // Build winners per lift (client-side fallback).
          // Keys must match your canonical keys in stats_snapshot.dart.
          const squat = 'Back Squat, Barbell';
          const bench = 'Bench Press, Barbell';
          const dead  = 'Deadlift, Conventional';
          const chin  = 'Chin-Up';
          const ohp   = 'Overhead Dumbbell Press, Unilateral';

          // Scan once to find max per lift using the preprocessed items list
          double mx(String k) {
            double best = 0;
            for (final row in items) {
              final byLift = Map<String, dynamic>.from(row['byLift'] as Map);
              final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
              if (v > best) best = v;
            }
            return best;
          }


          final maxByLift = <String, double>{
            bench: mx(bench),
            squat: mx(squat),
            dead:  mx(dead),
            chin:  mx(chin),
            ohp:   mx(ohp),
          };

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final row = items[index];

              final rank = index + 1;
              final displayName = row['name'] as String;
              final points = row['points'] as double;
              final byLift = Map<String, dynamic>.from(row['byLift'] as Map);

              bool winner(String k) {
                final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
                return v > 0 && (v - (maxByLift[k] ?? 0.0)).abs() < 1e-9;
              }


              Widget medalChip(String label, bool hasMedal) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  margin: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(
                    color: hasMedal ? cyan.withOpacity(0.20) : Colors.transparent,
                    border: Border.all(
                      color: hasMedal ? cyan : Colors.white24,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: hasMedal ? cyan : Colors.white70,
                      fontWeight: hasMedal ? FontWeight.w700 : FontWeight.w500,
                      letterSpacing: 0.4,
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
                  title: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                    constraints: const BoxConstraints(maxWidth: 160), // tweak 140–200 as needed
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          medalChip('B', winner(bench)),
                          medalChip('S', winner(squat)),
                          medalChip('D', winner(dead)),
                          medalChip('C', winner(chin)),
                          medalChip('O', winner(ohp)),
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

    // Small chip used for medals
    Widget medalChip(String label, bool hasMedal) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        margin: const EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: hasMedal ? cyan.withOpacity(0.18) : Colors.transparent,
          border: Border.all(color: hasMedal ? cyan : Colors.white24, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: hasMedal ? cyan : Colors.white70,
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
                    backgroundColor: MaterialStateProperty.resolveWith((states) {
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

          // ---- Table-style header (aligned to row widths) ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Column(
              children: [
                // Top header row
                Row(
                  children: [
                    // Rank header
                    const SizedBox(
                      width: 28,
                      child: Text(
                        '#',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Name header (expands)
                    const Expanded(
                      child: Text(
                        'Name',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Points header (fixed width, right-aligned)
                    const SizedBox(
                      width: 64,
                      child: Text(
                        'RE pts',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Medals header (same max width as medals container in rows)
                    const SizedBox(
                      width: 160,
                      child: Text(
                        'Medals',
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 2),

                // Sub-header row (labels under medals)
                Row(
                  children: const [
                    SizedBox(width: 28), // align with rank
                    SizedBox(width: 8),
                    Expanded(child: SizedBox()), // skip under Name
                    SizedBox(width: 8),
                    SizedBox(width: 64), // skip under RE pts
                    SizedBox(width: 8),

                    // Subheaders inside medals area (match 160px width)
                    SizedBox(
                      width: 160,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Bench', style: TextStyle(color: Colors.white38, fontSize: 11)),
                          Text('Squat', style: TextStyle(color: Colors.white38, fontSize: 11)),
                          Text('DL',    style: TextStyle(color: Colors.white38, fontSize: 11)),
                          Text('C-Up',  style: TextStyle(color: Colors.white38, fontSize: 11)),
                          Text('OHDP',  style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
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
                final name =
                (m['displayName'] ?? m['fullName'] ?? 'User') as String;

                final points = (_period == LeaderboardPeriod.monthly)
                    ? (m['rePointsMonthlyCurrent'] as num?)?.toDouble() ?? 0.0
                    : (m['rePoints'] as num?)?.toDouble() ?? 0.0;

                final byLift = (_period == LeaderboardPeriod.monthly)
                    ? Map<String, dynamic>.from(
                    m['rePointsMonthlyByLiftCurrent'] ?? const {})
                    : Map<String, dynamic>.from(
                    m['rePointsByLift'] ?? const {});

                items.add({'name': name, 'points': points, 'byLift': byLift});
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
              const squat = 'Back Squat, Barbell';
              const bench = 'Bench Press, Barbell';
              const dead = 'Deadlift, Conventional';
              const chin = 'Chin-Up';
              const ohp = 'Overhead Dumbbell Press, Unilateral';

              double mx(String k) {
                double best = 0;
                for (final row in items) {
                  final byLift =
                  Map<String, dynamic>.from(row['byLift'] as Map);
                  final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
                  if (v > best) best = v;
                }
                return best;
              }

              final maxByLift = <String, double>{
                bench: mx(bench),
                squat: mx(squat),
                dead: mx(dead),
                chin: mx(chin),
                ohp: mx(ohp),
              };

              bool win(Map<String, dynamic> byLift, String k) {
                final v = (byLift[k] as num?)?.toDouble() ?? 0.0;
                return v > 0 && (v - (maxByLift[k] ?? 0.0)).abs() < 1e-9;
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final row = items[index];
                  final rank = index + 1;
                  final name = row['name'] as String;
                  final pts = row['points'] as double;
                  final byLift =
                  Map<String, dynamic>.from(row['byLift'] as Map);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: rowBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Rank (fixed)
                        SizedBox(
                          width: 28,
                          child: Text(
                            '$rank',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Name (expands)
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),

                        const SizedBox(width: 8),

                        // Points (fixed min width, right-aligned)
                        SizedBox(
                          width: 64, // fits up to 5 digits comfortably
                          child: Text(
                            pts.toStringAsFixed(0),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),

                        const SizedBox(width: 8),

                        // Medals (constrained; scrolls if tight)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                medalChip('B', win(byLift, bench)),
                                medalChip('S', win(byLift, squat)),
                                medalChip('D', win(byLift, dead)),
                                medalChip('C', win(byLift, chin)),
                                medalChip('O', win(byLift, ohp)),
                              ],
                            ),
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

