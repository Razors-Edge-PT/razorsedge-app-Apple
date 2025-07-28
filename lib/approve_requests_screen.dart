import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';

class ApproveRequestsScreen extends StatelessWidget {
  const ApproveRequestsScreen({super.key});

  Future<void> _approve(String requestId, String coachUid, String athleteUid) async {
    final batch = FirebaseFirestore.instance.batch();

    // 🔓 Grant access: coachAssignments
    final coachRef = FirebaseFirestore.instance
        .collection('coachAssignments')
        .doc(coachUid);
    batch.set(coachRef, {
      'athletes.$athleteUid': {
        'approvedAt': FieldValue.serverTimestamp(),
      }
    }, SetOptions(merge: true));

    // Optional mirror: athleteAssignments (if needed later)
    final athleteRef = FirebaseFirestore.instance
        .collection('athleteAssignments')
        .doc(athleteUid);
    batch.set(athleteRef, {
      'coaches.$coachUid': {
        'approvedAt': FieldValue.serverTimestamp(),
      }
    }, SetOptions(merge: true));

    // 🧹 Delete the original request
    final requestRef = FirebaseFirestore.instance
        .collection('accessRequests')
        .doc(requestId);
    batch.delete(requestRef);

    await batch.commit();
  }

  Future<void> _reject(String requestId) async {
    await FirebaseFirestore.instance
        .collection('accessRequests')
        .doc(requestId)
        .delete();
  }

  @override
  Widget build(BuildContext context) {
    final userContext = UserContext.of(context);
    final athleteUid = userContext.actorUid;

    return Scaffold(
      appBar: AppBar(title: const Text("Coach Access Requests")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('accessRequests')
            .where('athleteUid', isEqualTo: athleteUid)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final requests = snapshot.data!.docs;

          if (requests.isEmpty) {
            return const Center(child: Text("No pending access requests."));
          }

          return ListView(
            children: requests.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final coachUid = data['coachUid'] ?? 'unknown';
              final createdAt = data['createdAt']?.toDate();

              return ListTile(
                title: Text("Coach UID: $coachUid"),
                subtitle: Text("Requested on: ${createdAt ?? 'N/A'}"),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () async {
                        await _approve(doc.id, coachUid, athleteUid);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text("Approved access for $coachUid"),
                        ));
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.clear, color: Colors.red),
                      onPressed: () async {
                        await _reject(doc.id);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text("Rejected access for $coachUid"),
                        ));
                      },
                    ),
                  ],
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
