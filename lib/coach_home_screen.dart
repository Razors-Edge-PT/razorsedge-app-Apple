import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'request_access_screen.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

String emailHash(String email) {
  final lower = email.trim().toLowerCase();
  return sha256.convert(utf8.encode(lower)).toString();
}

Future<void> upsertUserLookup() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || user.email == null) return;

  final hash = emailHash(user.email!);
  await FirebaseFirestore.instance
      .collection('user_lookup')
      .doc(hash)
      .set({
    'uid': user.uid,
    'displayName': user.displayName ?? '', // ✅ store here
  }, SetOptions(merge: true));
  debugPrint('✅ [upsertUserLookup] Lookup saved for ${user.email}');
}


class CoachHomeScreen extends StatefulWidget {
  const CoachHomeScreen({super.key});

  @override
  State<CoachHomeScreen> createState() => _CoachHomeScreenState();
}

class _CoachHomeScreenState extends State<CoachHomeScreen> {
  Map<String, dynamic> _athletes = {};
  String _search = '';

  @override
  void initState() {
    super.initState();

    // Delay provider access until after first build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userContext = Provider.of<UserContext?>(context, listen: false);

      if (userContext == null) {
        debugPrint("⚠️ UserContext is null — maybe not initialized yet.");
        return;
      }

      if (!userContext.isCoach) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Access denied — only coaches can open this screen."),
        ));
        Navigator.pop(context);
        return;
      }

      _loadAthletes(userContext);
    });
  }




  Future<void> _loadAthletes(UserContext userContext) async {
    try {
      if (userContext.isSuperAdmin) {
        final query = await FirebaseFirestore.instance.collection('users').get();
        setState(() {
          _athletes = {
            for (var doc in query.docs)
              doc.id: {
                'username'    : (doc.data()['username'] ?? '') as String,
                'displayName' : (doc.data()['displayName'] ?? '') as String,
                'email'       : (doc.data()['email'] ?? '') as String,
              }
          };
        });
        return;
      }

      final coachUid = userContext.actorUid;
      debugPrint('👤 Coach branch hit for $coachUid');

      final Map<String, dynamic> athletes = {};

      // 1) athleteAssignments
      final q1 = await FirebaseFirestore.instance
          .collection('athleteAssignments')
          .where('coaches.$coachUid.approved', isEqualTo: true)
          .get();

      for (final doc in q1.docs) {
        final athleteUid = doc.id;
        final u = await FirebaseFirestore.instance
            .collection('users')
            .doc(athleteUid)
            .get();
        final data = u.data() ?? {};
        athletes[athleteUid] = {
          'username'    : (data['username'] ?? '') as String,
          'displayName' : (data['displayName'] ?? '') as String,
          'email'       : (data['email'] ?? '') as String,
        };
      }

      // 2) coachAssignments (seeded)
      final doc2 = await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .get();

      if (doc2.exists) {
        final seeded = Map<String, dynamic>.from(doc2.data()?['athletes'] ?? {});
        for (final entry in seeded.entries) {
          final athleteUid = entry.key;
          athletes.putIfAbsent(athleteUid, () => {
            'username'    : (entry.value['username'] ?? '') as String,
            'displayName' : (entry.value['displayName'] ?? '') as String,
            'email'       : (entry.value['email'] ?? '') as String,
          });
        }
      }

      setState(() => _athletes = athletes);
      debugPrint('✅ Loaded ${athletes.length} athletes for coach $coachUid');
    } catch (e) {
      debugPrint("❌ Error loading athletes: $e");
    }
  }



  Future<void> _adminSeedAthleteToCoach({
    required String coachUid,
    required String athleteEmail,
  }) async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: athleteEmail.trim().toLowerCase())
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No user found for $athleteEmail')),
        );
        return;
      }

      final athleteDoc = q.docs.first;
      final athleteUid = athleteDoc.id;
      final email = (athleteDoc.data()['email'] ?? athleteEmail).toString();

      await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .set({
        'athletes': {
          athleteUid: {'email': email},
        }
      }, SetOptions(merge: true));
// ✅ Debug print to confirm assignment
      print('✅ [ADMIN SEED] Athlete "$email" ($athleteUid) assigned to coach "$coachUid"');
      if (mounted) {
        setState(() {
          if (context.read<UserContext>().actorUid == coachUid) {
            _athletes[athleteUid] = {'email': email};
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $email to coach $coachUid')),
        );
      }
    } catch (e) {
      debugPrint('❌ Admin seed failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add athlete')),
        );
      }
    }
  }


  // ---------- Added: helper to add athlete by email ----------
  Future<void> _addAthleteByEmail(BuildContext context, String email) async {
    final trimmed = email.trim().toLowerCase();
    if (trimmed.isEmpty) return;

    try {
      final coachUid = UserContext.of(context, listen: false).actorUid;

      // Resolve athlete via hashed email
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
      final athleteName = (data['displayName'] ?? '') as String;

      if (athleteUid == coachUid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You can't add yourself.")),
        );
        return;
      }

      // Create/refresh a PENDING access request (idempotent key)
      final user = FirebaseAuth.instance.currentUser!;
      final coachName = user.displayName ?? '';
      final coachEmail = user.email ?? '';

      final requestId = '${coachUid}__${athleteUid}'; // deterministic
      await FirebaseFirestore.instance
          .collection('accessRequests')
          .doc(requestId)
          .set({
        'coachUid': coachUid,
        'coachName': coachName,
        'coachEmail': coachEmail,
        'athleteUid': athleteUid,
        'athleteDisplayName': athleteName,
        'athleteEmail': trimmed,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('📨 [addAthleteByEmail] Created access request $requestId → $trimmed');

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request sent to $trimmed')),
      );
    } catch (e) {
      debugPrint('❌ addAthleteByEmail error: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send request')),
      );
    }
  }


  // ---------- Added: helper to remove athlete ----------
  Future<void> _removeAthlete(String uid) async {
    final coachUid = context.read<UserContext>().actorUid;
    try {
      await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .update({'athletes.$uid': FieldValue.delete()});

      setState(() {
        _athletes.remove(uid);
      });
    } catch (e) {
      debugPrint('❌ Failed to remove athlete: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to remove athlete')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.maybeOf(context);

    if (userContext == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // ---------- Updated: better search across uid/email/displayName ----------
    final filteredUids = _athletes.keys.where((uid) {
      final email = (_athletes[uid]?['email'] ?? '') as String;
      final name = (_athletes[uid]?['displayName'] ?? '') as String;
      final q = _search.toLowerCase();
      return uid.toLowerCase().contains(q) ||
          email.toLowerCase().contains(q) ||
          name.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Coach Dashboard"),
          actions: [
            // Coach path: add by email (will fail if rules block coach from writing 'athletes')
            IconButton(
              tooltip: 'Add athlete by email',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () async {
                final controller = TextEditingController();
                final email = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Add athlete by email'),
                    content: TextField(
                      controller: controller,
                      decoration: const InputDecoration(hintText: 'athlete@email.com'),
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
                  await _addAthleteByEmail(context, email);
                }
              },
            ),

            // Super-admin-only: seed any athlete to any coach
            if (userContext.isSuperAdmin)
              IconButton(
                tooltip: 'Seed athlete to coach (admin)',
                icon: const Icon(Icons.admin_panel_settings),
                onPressed: () async {
                  final coachSearchController = TextEditingController();
                  final athleteEmailController = TextEditingController();
                  String? selectedCoachUid;
                  String? selectedCoachName;
                  List<Map<String, String>> results = [];
                  bool isSearching = false;

                  Future<void> _search(String q) async {
                    final query = q.trim();
                    results = [];
                    if (query.isEmpty) return;

                    isSearching = true;
                    try {
                      final merged = <Map<String, String>>[];
                      final seen = <String>{};

                      String safe(Object? v) => (v ?? '').toString();

                      // 0) If it looks like an email, try your user_lookup first (exact match)
                      if (query.contains('@')) {
                        final lu = await FirebaseFirestore.instance
                            .collection('user_lookup')
                            .doc(query.toLowerCase())
                            .get();

                        if (lu.exists) {
                          final data = lu.data() as Map<String, dynamic>;
                          final uid = safe(data['uid']);
                          if (uid.isNotEmpty && seen.add(uid)) {
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      }

                      // 1) Name search (case-sensitive, no lowercased field required)
                      try {
                        final byName = await FirebaseFirestore.instance
                            .collection('users')
                            .orderBy('displayName')                  // no displayNameLower needed
                            .startAt([query])                        // prefix match (case sensitive)
                            .endAt(['$query\uf8ff'])
                            .limit(10)
                            .get();

                        for (final d in byName.docs) {
                          final uid = d.id;
                          if (seen.add(uid)) {
                            final data = d.data() as Map<String, dynamic>;
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      } on FirebaseException catch (e) {
                        // If you see "requires an index", create it in Firestore console.
                        debugPrint('🔎 byName search failed: ${e.message}');
                      }

                      // 2) Email prefix search (no emailLower needed)
                      try {
                        final byEmail = await FirebaseFirestore.instance
                            .collection('users')
                            .orderBy('email')
                            .startAt([query])
                            .endAt(['$query\uf8ff'])
                            .limit(10)
                            .get();

                        for (final d in byEmail.docs) {
                          final uid = d.id;
                          if (seen.add(uid)) {
                            final data = d.data() as Map<String, dynamic>;
                            merged.add({
                              'uid': uid,
                              'name': safe(data['displayName']),
                              'email': safe(data['email']),
                            });
                          }
                        }
                      } on FirebaseException catch (e) {
                        debugPrint('🔎 byEmail search failed: ${e.message}');
                      }

                      results = merged;
                      debugPrint('🔍 coach search "${query}": ${results.length} result(s)');
                    } catch (e, st) {
                      debugPrint('❌ coach search error: $e\n$st');
                      results = [];
                    } finally {
                      isSearching = false;
                    }
                  }

                  final result = await showDialog<Map<String, String>?>(
                    context: context, // ✅ pass the BuildContext you already have
                    builder: (ctx) {
                      return StatefulBuilder(
                        builder: (ctx, setLocalState) {
                          Future<void> handleSearch(String v) async {
                            await _search(v);
                            setLocalState(() {}); // refresh list
                          }

                          return AlertDialog(
                            title: const Text('Seed athlete to coach'),
                            content: SingleChildScrollView( // ✅ prevents overflow
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 400,  // cap total dialog height
                                  minWidth: 320,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Coach search field
                                    TextField(
                                      controller: coachSearchController,
                                      decoration: const InputDecoration(
                                        labelText: 'Coach name or email',
                                        hintText: 'Type to search…',
                                      ),
                                      onChanged: (v) => handleSearch(v),
                                      autofocus: true,
                                    ),

                                    if (selectedCoachUid != null) ...[
                                      const SizedBox(height: 6),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          'Selected UID: $selectedCoachUid',
                                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ],

                                    const SizedBox(height: 8),

                                    // Results list
                                    Flexible( // ✅ results take remaining space, scroll inside
                                      child: isSearching
                                          ? const Center(child: Padding(
                                        padding: EdgeInsets.all(12),
                                        child: CircularProgressIndicator(),
                                      ))
                                          : ListView.builder(
                                        shrinkWrap: true,
                                        itemCount: results.length,
                                        itemBuilder: (_, i) {
                                          final r = results[i];
                                          final name = (r['name']?.isNotEmpty ?? false) ? r['name']! : '(no name)';
                                          final email = r['email'] ?? '';
                                          final uid = r['uid'] ?? '';
                                          return ListTile(
                                            dense: true,
                                            title: Text(name),
                                            subtitle: Text('$email\n$uid'),
                                            isThreeLine: true,
                                            onTap: () {
                                              selectedCoachUid = uid;
                                              selectedCoachName = name;
                                              coachSearchController.text = name.isNotEmpty ? name : email;
                                              setLocalState(() {});
                                            },
                                          );
                                        },
                                      ),
                                    ),

                                    const SizedBox(height: 8),

                                    TextField(
                                      controller: athleteEmailController,
                                      decoration: const InputDecoration(labelText: 'Athlete email'),
                                      keyboardType: TextInputType.emailAddress,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                              TextButton(
                                onPressed: (selectedCoachUid != null && athleteEmailController.text.trim().isNotEmpty)
                                    ? () => Navigator.pop(ctx, {
                                  'coachUid': selectedCoachUid!,
                                  'coachName': selectedCoachName ?? '',
                                  'email': athleteEmailController.text.trim(),
                                })
                                    : null,
                                child: const Text('Add'),
                              ),
                            ],
                          );

                        },
                      );
                    },
                  );

                  if (result != null) {
                    final coachUid = (result['coachUid'] ?? '').trim();
                    final athleteEmail = (result['email'] ?? '').trim();
                    if (coachUid.isNotEmpty && athleteEmail.isNotEmpty) {
                      await _adminSeedAthleteToCoach(
                        coachUid: coachUid,
                        athleteEmail: athleteEmail,
                      );
                    }
                  }
                },
              ),
          ]

      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search athletes',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() => _search = value);
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filteredUids.length,
              itemBuilder: (context, index) {
                final uid = filteredUids[index];
                final isSelected = uid == userContext.actingAsUid;
                final a = _athletes[uid] ?? {};

                String? pick(dynamic v) {
                  final s = (v ?? '').toString().trim();
                  return s.isEmpty ? null : s;
                }

                final titleText =
                    pick(a['username']) ??
                        pick(a['displayName']) ??
                        pick(a['email']) ??
                        uid;

                final emailText = pick(a['email']);
                final subtitleText = (emailText != null && emailText != titleText)
                    ? emailText
                    : null;

                return ListTile(
                  title: Text(
                    titleText,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: subtitleText != null ? Text(subtitleText) : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isSelected) const Icon(Icons.check, color: Colors.green),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeAthlete(uid),
                        tooltip: 'Remove athlete',
                      ),
                    ],
                  ),
                  onTap: () {
                    userContext.switchAthlete(uid);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Switched to athlete: $titleText")),
                    );
                  },
                );
              },
            ),
          ),

          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: context.read<UserContext>(),
                  child: const RequestAccessScreen(),
                ),
              ));
            },
            icon: const Icon(Icons.person_add),
            label: const Text("Request Access to Athlete"),
          ),
        ],
      ),
    );
  }
}
