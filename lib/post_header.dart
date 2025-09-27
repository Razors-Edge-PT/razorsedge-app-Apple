import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PostHeader extends StatelessWidget {
  final String ownerUid;
  final DateTime createdAt;

  const PostHeader({super.key, required this.ownerUid, required this.createdAt});

  String _timeAgo(Duration d) {
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final ago = _timeAgo(now.difference(createdAt));

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users_public').doc(ownerUid).get(),
      builder: (ctx, snap) {
        String? photoURL;
        String display = ownerUid;
        if (snap.hasData && snap.data!.data() != null) {
          final m = snap.data!.data()!;
          final u = (m['username'] ?? '').toString().trim();
          final dn = (m['displayName'] ?? '').toString().trim();
          if (u.isNotEmpty) display = u; else if (dn.isNotEmpty) display = dn;
          final p = (m['photoURL'] ?? '').toString().trim();
          if (p.isNotEmpty) photoURL = p;
        }

        return Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: (photoURL != null && photoURL!.isNotEmpty) ? NetworkImage(photoURL!) : null,
              child: (photoURL == null || photoURL!.isEmpty) ? const Icon(Icons.person, size: 16) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text('· $ago', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        );
      },
    );
  }
}
