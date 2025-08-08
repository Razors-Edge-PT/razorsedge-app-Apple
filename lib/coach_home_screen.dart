import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'request_access_screen.dart';

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
      // ✅ Super admin override: Load ALL users
      if (userContext.isSuperAdmin) {
        debugPrint('👑 SuperAdmin branch hit for ${userContext.actorUid}');
        final query = await FirebaseFirestore.instance.collection('users').get();
        debugPrint('👑 Loaded ${query.docs.length} users for super admin');
        setState(() {
          _athletes = {
            for (var doc in query.docs)
              doc.id: {
                'displayName': doc.data()['displayName'] ?? '',
                'email': doc.data()['email'] ?? '',
              }
          };
        });
        return; // 👈 Skip regular coach logic
      }

      debugPrint('👤 Coach branch hit for ${userContext.actorUid}');
      // ✅ Normal coach logic
      final doc = await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(userContext.actorUid)
          .get();

      if (doc.exists && doc.data() != null) {
        setState(() {
          _athletes = Map<String, dynamic>.from(doc.data()!['athletes'] ?? {});
        });
      } else {
        debugPrint("ℹ️ No athlete data found for coach ${userContext.actorUid}");
      }
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
    final coachUid = context.read<UserContext>().actorUid;
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: email.trim().toLowerCase())
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No user found for $email')),
        );
        return;
      }

      final doc = q.docs.first;
      final athleteUid = doc.id;
      final data = doc.data();
      final displayName = (data['displayName'] ?? '') as String;
      final normalizedEmail = (data['email'] ?? email).toString();

      await FirebaseFirestore.instance
          .collection('coachAssignments')
          .doc(coachUid)
          .set({
        'athletes': {
          athleteUid: {
            'email': normalizedEmail,
            'displayName': displayName,
          },
        }
      }, SetOptions(merge: true));

      setState(() {
        _athletes[athleteUid] = {
          'email': normalizedEmail,
          'displayName': displayName,
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $normalizedEmail')),
      );
    } catch (e) {
      debugPrint('❌ Failed to add athlete: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add athlete')),
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
                  final coachController = TextEditingController(text: 'B3dWiljf4ISavFufZ0xN6o9LsD93'); // Campbell default
                  final emailController = TextEditingController();

                  final result = await showDialog<Map<String, String>?>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Seed athlete to coach'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(
                            controller: coachController,
                            decoration: const InputDecoration(labelText: 'Coach UID'),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: emailController,
                            decoration: const InputDecoration(labelText: 'Athlete email'),
                            keyboardType: TextInputType.emailAddress,
                            autofocus: true,
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, {
                            'coachUid': coachController.text,
                            'email': emailController.text,
                          }),
                          child: const Text('Add'),
                        ),
                      ],
                    ),
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

                return ListTile(
                  title: Text(
                    _athletes[uid]?['email'] ?? uid,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: (_athletes[uid]?['displayName'] ?? '').isNotEmpty
                      ? Text(_athletes[uid]?['displayName'])
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isSelected) const Icon(Icons.check, color: Colors.green),
                      // ---------- Added: remove athlete button ----------
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeAthlete(uid),
                        tooltip: 'Remove athlete',
                      ),
                    ],
                  ),
                  onTap: () {
                    userContext.switchAthlete(uid);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text("Switched to athlete: ${_athletes[uid]?['email'] ?? uid}"),
                    ));
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
