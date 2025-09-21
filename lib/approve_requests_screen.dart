import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'profile_page.dart';

// Local model
class UserHit {
  final String uid;
  final String username;
  final String emailLower;
  final String? photoURL;               // ← nullable
  UserHit(this.uid, this.username, this.emailLower, [this.photoURL]); // ← 4th param in []
}



class ApproveRequestsScreen extends StatelessWidget {
  const ApproveRequestsScreen({super.key});

  Future<void> _approve(String requestId, String coachUid, String athleteUid) async {
    final db = FirebaseFirestore.instance;

    try {
      final reqSnap = await db.collection('accessRequests').doc(requestId).get();
      if (!reqSnap.exists) {
        debugPrint('⚠️ [approve] Request $requestId not found.');
        return;
      }
      final r = reqSnap.data() as Map<String, dynamic>;
      final coachEmail = (r['coachEmail'] ?? '') as String;
      final coachName  = (r['coachName']  ?? '') as String;

      // 1) Athlete-side approval (should be allowed by your rules)
      await db.collection('athleteAssignments').doc(athleteUid).set({
        'coaches': {
          coachUid: {
            'coachEmail': coachEmail,
            'coachName': coachName,
            'approved': true,
            'approvedAt': FieldValue.serverTimestamp(),
          }
        }
      }, SetOptions(merge: true));
      debugPrint('✅ [approve] Wrote athleteAssignments for $athleteUid → $coachUid');

      // 2) Best-effort: delete the request (don’t crash if blocked)
      try {
        await db.collection('accessRequests').doc(requestId).delete();
        debugPrint('🧹 [approve] Deleted accessRequests/$requestId');
      } catch (e) {
        debugPrint('⚠️ [approve] Could not delete accessRequests/$requestId: $e');
        // Optional: mark approved if delete not permitted
        try {
          await db.collection('accessRequests').doc(requestId).set({
            'status': 'approved',
            'approvedAt': FieldValue.serverTimestamp(),
            'approvedBy': athleteUid,
          }, SetOptions(merge: true));
          debugPrint('ℹ️ [approve] Marked request approved instead of delete.');
        } catch (e2) {
          debugPrint('⚠️ [approve] Also could not mark approved: $e2');
        }
      }
    } catch (e) {
      debugPrint('❌ [approve] Error: $e');
    }
  }




  Future<void> _reject(String requestId) async {
    await FirebaseFirestore.instance
        .collection('accessRequests')
        .doc(requestId)
        .delete();
  }

  Future<void> _addGymBuddyByUid(
      BuildContext context, {
        required String athleteUid,
        required String username,
        required String emailLower,
      }) async {
    try {
      final actorUid = UserContext.of(context, listen: false).actorUid;

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
            'displayName': username,    // placeholder until you add full name
            'email': emailLower,        // kept for reference; not shown in UI
            'addedAt': FieldValue.serverTimestamp(),
          }
        }
      }, SetOptions(merge: true));

      debugPrint('🤝 [addGymBuddyByUid] $athleteUid ($username) added for $actorUid');

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $username')),
      );
    } catch (e) {
      debugPrint('❌ addGymBuddyByUid error: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add gym buddy')),
      );
    }
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

  Future<void> _showAddGymBroPicker(BuildContext context) async {
    final controller = TextEditingController();
    String query = '';
    String? lastError;

    // Two prefix queries (usernameLower + emailLower), merged & de-duped
    Future<List<UserHit>> _runSearch(String q) async {
      final db = FirebaseFirestore.instance;
      final ql = q.trim().toLowerCase();
      if (ql.isEmpty) return [];

      try {
        final futures = <Future<QuerySnapshot>>[];

        // prefix search on usernameLower / emailLower / fullNameLower
        futures.add(
          db.collection('users_public')
              .orderBy('usernameLower')
              .startAt([ql]).endAt(['$ql\uf8ff']).limit(20).get(),
        );
        futures.add(
          db.collection('users_public')
              .orderBy('emailLower')
              .startAt([ql]).endAt(['$ql\uf8ff']).limit(20).get(),
        );
        futures.add(
          db.collection('users_public')
              .orderBy('fullNameLower')
              .startAt([ql]).endAt(['$ql\uf8ff']).limit(20).get(),
        );

        // exact email match if it looks like an email
        final isEmail = q.contains('@');
        if (isEmail) {
          futures.add(
            db.collection('users_public')
                .where('emailLower', isEqualTo: ql)
                .limit(5)
                .get(),
          );
        }

        final snaps = await Future.wait(futures);

        final byUid = <String, UserHit>{};

        for (final snap in snaps) {
          for (final d in snap.docs) {
            final m = d.data() as Map<String, dynamic>;
            byUid[d.id] = UserHit(
              d.id,
              (m['username'] ?? '').toString(),
              (m['emailLower'] ?? '').toString(),
              (m['photoURL'] as String?),
            );


          }
        }

        // also allow direct UID hit (if they pasted a UID)
        if (!byUid.containsKey(ql)) {
          final direct = await db.collection('users_public').doc(ql).get();
          if (direct.exists) {
            final m = direct.data() as Map<String, dynamic>;
            byUid[direct.id] = UserHit(
              direct.id,
              (m['username'] ?? '').toString(),
              (m['emailLower'] ?? '').toString(),
              (m['photoURL'] as String?),
            );


          }
        }

        final list = byUid.values.toList()
          ..sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));

        lastError = null;
        return list;
      } catch (e) {
        debugPrint('❌ [AddGymBroPicker] search error: $e');
        lastError = e.toString();
        return [];
      }
    }


    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        List<UserHit> results = const [];
        bool loading = false;

        Future<void> _refresh(String text, void Function(void Function()) setState) async {
          setState(() => loading = true);
          final r = await _runSearch(text);
          if (!ctx.mounted) return;
          setState(() {
            results = r;
            loading = false;
          });
        }

        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('Add Gymbro (type username or email)'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'smallerthanu@email.com',
                        hintStyle: TextStyle(color: Colors.grey),
                      ),

                      onChanged: (t) {
                        query = t;
                        _refresh(t, setState);
                      },
                      onSubmitted: (t) async {
                        if (t.trim().contains('@')) {
                          Navigator.pop(ctx);
                          await _addGymBuddyByEmail(context, t.trim());
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    if (loading)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if ((results.isEmpty) && (query.trim().isNotEmpty))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          lastError == null
                              ? 'No matches. Tip: enter the full email to add directly.'
                              : 'Search error: $lastError',
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final u = results[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4), // small natural space
                              child: ListTile(
                                dense: true,
                                leading: (u.photoURL != null && u.photoURL!.isNotEmpty)
                                    ? CircleAvatar(
                                  radius: 12,
                                  backgroundImage: NetworkImage(u.photoURL!),
                                )
                                    : const Icon(Icons.person_outline, size: 18, color: Colors.cyanAccent),


                                title: Text(
                                  u.username.isNotEmpty ? u.username : '(no username)',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                subtitle: u.emailLower.isNotEmpty
                                    ? Text(u.emailLower, style: const TextStyle(fontSize: 12, color: Colors.white70))
                                    : null,
                                onTap: () async {
                                  Navigator.pop(ctx);
                                  await _addGymBuddyByUid(
                                    context,
                                    athleteUid: u.uid,
                                    username: u.username.isNotEmpty ? u.username : '(no username)',
                                    emailLower: u.emailLower,
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),

                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
                TextButton(
                  onPressed: () async {
                    final t = controller.text.trim();
                    if (t.isEmpty) return;
                    Navigator.pop(ctx);
                    if (t.contains('@')) {
                      await _addGymBuddyByEmail(context, t);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Please tap a user result (or enter full email).')),
                      );
                    }
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
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
        // ↓ Batch load users_public for all buddy UIDs (chunks of 10)
        Future<Map<String, Map<String, dynamic>>> _getPublicProfiles(Set<String> uids) async {
          final result = <String, Map<String, dynamic>>{};
          if (uids.isEmpty) return result;

          const chunk = 10;
          final ids = uids.toList();
          for (var i = 0; i < ids.length; i += chunk) {
            final slice = ids.sublist(i, (i + chunk).clamp(0, ids.length));
            final qs = await FirebaseFirestore.instance
                .collection('users_public')
                .where(FieldPath.documentId, whereIn: slice)
                .get();

            for (final d in qs.docs) {
              result[d.id] = d.data();
            }
            // Ensure all requested ids have an entry so we can safely fallback
            for (final id in slice) {
              result.putIfAbsent(id, () => const {});
            }
          }
          return result;
        }

// All buddy UIDs we’ll resolve to public profiles
        final buddyUids = entries.map((e) => e.key.toString()).toSet();


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
                  FutureBuilder<Map<String, Map<String, dynamic>>>(
                    future: _getPublicProfiles(buddyUids),
                    builder: (context, pubSnap) {
                      final publicByUid = pubSnap.data ?? const <String, Map<String, dynamic>>{};

                      // Build a sortable list combining entries + public profiles
                      final sorted = entries.map((e) {
                        final uid = e.key;
                        final v = Map<String, dynamic>.from(e.value ?? {});
                        final email = (v['email'] ?? '').toString();

                        final public = publicByUid[uid] ?? const {};
                        final rp = public['rePoints'];
                        final rePoints = (rp is num) ? rp.toDouble() : 0.0; // default 0 if missing

                        return {
                          'uid': uid,
                          'email': email,
                          'public': public,
                          'rePoints': rePoints,
                        };
                      }).toList()
                      // Sort: RE points desc; tie-break by username asc for stability
                        ..sort((a, b) {
                          final ar = (a['rePoints'] as double);
                          final br = (b['rePoints'] as double);
                          if (br.compareTo(ar) != 0) return br.compareTo(ar);

                          final au = ((a['public'] as Map)['username'] ?? '').toString();
                          final bu = ((b['public'] as Map)['username'] ?? '').toString();
                          return au.toLowerCase().compareTo(bu.toLowerCase());
                        });

                      return ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: sorted.length,
                        itemBuilder: (context, i) {
                          final item       = sorted[i];
                          final athleteUid = item['uid'] as String;
                          final email      = (item['email'] ?? '').toString();
                          final public     = item['public'] as Map<String, dynamic>;
                          final rePoints   = (item['rePoints'] as double);

// Pull public profile (username/fullName) with sensible fallbacks
                          final username = (public['username'] ?? '').toString().trim().isNotEmpty
                              ? public['username'].toString().trim()
                              : (email.isNotEmpty ? email : athleteUid);
                          final fullName = (public['fullName'] ?? '').toString().trim();

                          final rePointsStr = (rePoints > 0)
                              ? 'RE Pts: ${rePoints.toStringAsFixed(0)}'
                              : 'RE Pts: —';



                          return ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
                            minVerticalPadding: 0,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                            leading: const Icon(Icons.person_outline, size: 18, color: Colors.cyanAccent),
                            minLeadingWidth: 20,

                            // Line 1: username (fallback → email → uid)
                            title: Text(
                              username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),

                            // Line 2: full name • RE Points (placeholder)
                            subtitle: Text(
                              rePointsStr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: Colors.white70),
                            ),


                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ProfilePage(
                                    viewedUid: athleteUid,
                                    readOnly: true,
                                  ),
                                ),
                              );
                            },

                            trailing: Padding(
                              padding: const EdgeInsets.only(right: 0),
                              child: IconButton(
                                tooltip: 'Remove',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                iconSize: 16,
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.white70),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Remove Gym Buddy'),
                                      content: Text(
                                        'Are you sure you want to remove ${email.isNotEmpty ? email : athleteUid} from your gym buddies?',
                                      ),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove', style: TextStyle(color: Colors.red))),
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
              tooltip: 'Add Gymbro (username or email)',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () async {
                await _showAddGymBroPicker(context);
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

                        return ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
                          minVerticalPadding: 0,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),

                          leading: const Icon(
                            Icons.mail_outline,
                            color: Colors.cyanAccent,
                          ),

                          title: Text(
                            coachEmail.isNotEmpty ? coachEmail : 'Coach UID: $coachUid',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
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
