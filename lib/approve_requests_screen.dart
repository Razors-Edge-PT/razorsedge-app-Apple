import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ApproveRequestsScreen extends StatelessWidget {
  const ApproveRequestsScreen({super.key});

  Future<void> _approve(String requestId, String coachUid, String athleteUid) async {
    final db = FirebaseFirestore.instance;

    // Load request details
    final reqSnap = await db.collection('accessRequests').doc(requestId).get();
    if (!reqSnap.exists) {
      debugPrint('⚠️ [approve] Request $requestId not found.');
      return;
    }
    final r = reqSnap.data() as Map<String, dynamic>;
    final coachEmail   = (r['coachEmail'] ?? '') as String;
    final coachName    = (r['coachName']  ?? '') as String;

    final batch = db.batch();

    // ✅ Athlete grants access by writing their own doc (allowed by rules)
    final athleteRef = db.collection('athleteAssignments').doc(athleteUid);
    batch.set(athleteRef, {
      'coaches': {
        coachUid: {
          'coachEmail': coachEmail,
          'coachName': coachName,
          'approvedAt': FieldValue.serverTimestamp(),
        }
      }
    }, SetOptions(merge: true));

    // 🧹 Remove request
    batch.delete(db.collection('accessRequests').doc(requestId));

    await batch.commit();

    debugPrint('✅ [approve] Athlete $athleteUid approved coach $coachUid '
        '(wrote athleteAssignments & deleted request $requestId).');
  }



  Future<void> _reject(String requestId) async {
    await FirebaseFirestore.instance
        .collection('accessRequests')
        .doc(requestId)
        .delete();
  }

  Future<void> _addGymBuddyByEmail(BuildContext context, String email) async {
    final trimmed = email.trim().toLowerCase();
    if (trimmed.isEmpty) return;

    try {
      final actorUid = UserContext.of(context, listen: false).actorUid;

      final hash = emailHash(trimmed);
      final lookup = await FirebaseFirestore.instance
          .collection('user_lookup')
          .doc(hash)
          .get();

      if (!lookup.exists) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No user found for $trimmed')),
        );
        return;
      }

      final data = lookup.data()!;
      final athleteUid = (data['uid'] as String).trim();
      final displayName = (data['displayName'] ?? '') as String;

      if (athleteUid == actorUid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You can't add yourself.")),
        );
        return;
      }

      await FirebaseFirestore.instance
          .collection('buddyAssignments')
          .doc(actorUid)
          .set({
        'athletes': {
          athleteUid: {
            'displayName': displayName,
            'email': trimmed,
            'addedAt': FieldValue.serverTimestamp(),
          }
        }
      }, SetOptions(merge: true));

      debugPrint('🤝 [addGymBuddyByEmail] $athleteUid ($displayName) added as read-only for $actorUid');

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $trimmed as a read-only gym buddy')),
      );

    } catch (e) {
      debugPrint('❌ addGymBuddyByEmail error: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add gym buddy')),
      );
    }
  }

  Future<void> _removeBuddy(BuildContext context, String athleteUid) async {
    final actorUid = UserContext.of(context, listen: false).actorUid;
    await FirebaseFirestore.instance
        .collection('buddyAssignments')
        .doc(actorUid)
        .update({
      'athletes.$athleteUid': FieldValue.delete(), // delete nested field
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Removed gym buddy')),
    );
  }

  Widget _buildGymBuddiesSection(BuildContext context, String actorUid) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('buddyAssignments')
          .doc(actorUid)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
              child: SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final data = snap.data?.data() ?? const {};
        final athletes = Map<String, dynamic>.from(data['athletes'] ?? {});
        final entries = athletes.entries.toList();

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.people_alt_outlined,
                          color: Colors.cyanAccent, size: 20),
                      SizedBox(width: 6),
                      Text(
                        'Your Gym Buddies',
                        textAlign: TextAlign.center,
                        style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: Colors.cyanAccent),
                          SizedBox(width: 4),
                          Text(
                            'You haven’t added any gym buddies yet.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final athleteUid = entries[i].key;
                      final v =
                      Map<String, dynamic>.from(entries[i].value ?? {});
                      final email = (v['email'] ?? '').toString();

                      return ListTile(
                        dense: true,
                        visualDensity:
                        const VisualDensity(horizontal: 0, vertical: 2),
                        contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12),
                        minVerticalPadding: 1,
                        horizontalTitleGap: 8,
                        leading: const Icon(Icons.person_outline,
                            size: 18, color: Colors.cyanAccent),
                        minLeadingWidth: 20,
                        subtitle: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            email,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style:
                            const TextStyle(fontSize: 16, color: Colors.white),
                          ),
                        ),
                        trailing: Padding(
                          padding: const EdgeInsets.only(right: 0),
                          child: IconButton(
                            tooltip: 'Remove',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 28, minHeight: 28),
                            iconSize: 16,
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.orangeAccent,
                            ),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Remove Gym Buddy'),
                                  content: Text(
                                    'Are you sure you want to remove ${email.isNotEmpty ? email : athleteUid} from your gym buddies?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Remove',
                                          style:
                                          TextStyle(color: Colors.red)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await _removeBuddy(context, athleteUid);
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }


  Widget _coachedByRow(String athleteUid) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('athleteAssignments')
          .doc(athleteUid)
          .snapshots(),
      builder: (context, snap) {
        final map = snap.data?.data()?['coaches'] as Map<String, dynamic>? ?? {};
        if (map.isEmpty) return const SizedBox.shrink();

        final emails = map.values
            .map((v) => (v['coachEmail'] ?? '').toString())
            .where((e) => e.isNotEmpty)
            .toList();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(
            'Coached by: ${emails.join(', ')}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.of(context);
    final athleteUid = userContext.actorUid;

    return Scaffold(
        appBar: AppBar(
            title: const Text("Wow u so popular"),
            actions: [
              // Coach path: add by email (will fail if rules block coach from writing 'athletes')
              IconButton(
                tooltip: 'Add Gymbro by email',
                icon: const Icon(Icons.person_add_alt),
                onPressed: () async {
                  final controller = TextEditingController();
                  final email = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Add Gymbro by email'),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'smallerthanu@email.com',
                          hintStyle: TextStyle(color: Colors.grey), // 👈 sets hint text color
                        ),
                        autofocus: true,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Add')),
                      ],
                    ),
                  );
                  if (email != null && email.trim().isNotEmpty) {
                    await _addGymBuddyByEmail(context, email);
                  }
                },
              ),
            ]
        ),

      body: Builder(
        builder: (context) {
          final userContext = UserContext.of(context);
          final actorUid = userContext.actorUid; // the logged-in (non-impersonated) user

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),

                // 🏷 Section heading styled like Home
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center, // ⬅ centers horizontally
                    children: [
                      const Icon(
                        Icons.supervisor_account,
                        size: 24,
                        color: Colors.cyanAccent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Coach Access Requests',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),



                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('accessRequests')
                      .where('athleteUid', isEqualTo: actorUid)
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final requests = snapshot.data!.docs;

                    if (requests.isEmpty) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch, // keep normal left alignment for _coachedByRow
                        children: [
                          _coachedByRow(actorUid), // coach info stays left
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 4, 16, 2),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'No pending access requests.',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ),

                          ),
                        ],
                      );

                    }

                    return ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: requests.length,
                      itemBuilder: (context, idx) {
                        final doc = requests[idx];
                        final data = doc.data() as Map<String, dynamic>;
                        final coachUid = data['coachUid'] ?? 'unknown';
                        final createdAt = data['createdAt']?.toDate();
                        final coachEmail = (data['coachEmail'] ?? '').toString();

                        return Card(
                        color: Colors.blueGrey.shade900,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: ListTile(
                          leading: const Icon(
                            Icons.mail_outline,
                            color: Colors.cyanAccent,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          title: Text(
                            coachEmail.isNotEmpty ? coachEmail : 'Coach UID: $coachUid',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            createdAt != null
                                ? 'Requested on: ${createdAt.toString().substring(0, 10)}'
                                : 'Requested on: N/A',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check, color: Colors.green),
                                onPressed: () async {
                                    final uc = UserContext.of(context, listen: false);
                                    if (!uc.isActingAsSelf) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Switch back to your own account to approve requests.',
                                          ),
                                        ),
                                      );
                                      debugPrint(
                                        '⛔ [approve] Blocked: actingAs=${uc.actingAsUid}, auth=${FirebaseAuth.instance.currentUser?.uid}',
                                      );
                                      return;
                                    }
                                    await _approve(doc.id, coachUid, uc.actorUid);
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Approved ${coachEmail.isNotEmpty ? coachEmail : 'coach'}',
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.red),
                                  onPressed: () async {
                                    await _reject(doc.id);
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Rejected access for $coachUid')),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),

                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(color: Colors.white24),
                ),

                _buildGymBuddiesSection(context, actorUid),
              ],
            ),
          );
        },
      ),


    );
  }
}
