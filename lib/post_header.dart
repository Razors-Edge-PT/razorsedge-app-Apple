import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class _UserPublicData {
  final String display;
  final String? photoURL;
  const _UserPublicData({required this.display, this.photoURL});
}

/// Session-scoped cache: uid → Future<_UserPublicData>.
/// putIfAbsent ensures exactly one Firestore read per uid per process lifetime.
/// Safe for coach mode: keyed by uid so different athletes never collide.
class _UserPublicCache {
  static final Map<String, Future<_UserPublicData>> _futures = {};

  static Future<_UserPublicData> fetch(String uid) =>
      _futures.putIfAbsent(uid, () => _load(uid));

  static Future<_UserPublicData> _load(String uid) async {
    final snap = await FirebaseFirestore.instance
        .collection('users_public')
        .doc(uid)
        .get();
    final m = snap.data() ?? {};
    final u = (m['username'] ?? '').toString().trim();
    final dn = (m['displayName'] ?? '').toString().trim();
    final display = u.isNotEmpty ? u : (dn.isNotEmpty ? dn : '?');
    final p = (m['photoURL'] ?? '').toString().trim();
    return _UserPublicData(display: display, photoURL: p.isEmpty ? null : p);
  }
}

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

    return FutureBuilder<_UserPublicData>(
      future: _UserPublicCache.fetch(ownerUid),
      builder: (ctx, snap) {
        final String display = snap.data?.display ?? '...';
        final String? photoURL = snap.data?.photoURL;

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
