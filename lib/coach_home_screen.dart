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
      // ✅ Admin override: Load ALL users
      if (userContext.isAdmin) {
        final query = await FirebaseFirestore.instance.collection('users').get();
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



  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.maybeOf(context);

    if (userContext == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final filteredUids = _athletes.keys
        .where((uid) => uid.toLowerCase().contains(_search.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Coach Dashboard"),
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
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
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
