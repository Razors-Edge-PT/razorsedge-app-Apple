import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'approve_requests_screen.dart';
import 'directMessages.dart';
import 'profile_page.dart';
import 'user_context.dart';

/// AppBar for HomeScreen2. Extracted from home_screen_2.dart as a
/// PreferredSizeWidget so the parent stays a slim shell.
///
/// Owns only AppBar-specific state: avatar local-cache persistence.
/// All other state (display name, streams) is read from context.
class HomeV2AppBar extends StatefulWidget implements PreferredSizeWidget {
  /// The scaffold key from the parent, used to open the drawer.
  final GlobalKey<ScaffoldState> scaffoldKey;

  /// Best-available display name for the acting user (from controller).
  /// Shows '...' when null.
  final String? displayName;

  const HomeV2AppBar({
    super.key,
    required this.scaffoldKey,
    required this.displayName,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<HomeV2AppBar> createState() => _HomeV2AppBarState();
}

class _HomeV2AppBarState extends State<HomeV2AppBar> {
  bool _avatarPersistInProgress = false;
  String? _avatarLastUrlSaved;

  Future<void> _persistAvatarLocalIfNeeded(
    BuildContext ctx, {
    required String uid,
    required String photoURL,
  }) async {
    if (_avatarPersistInProgress) return;
    final uc = ctx.read<UserContext>();

    if (uc.localPhotoPath != null) {
      final f = File(uc.localPhotoPath!);
      if (f.existsSync() && await f.length() > 0) return;
    }
    if (_avatarLastUrlSaved == photoURL) return;

    _avatarPersistInProgress = true;
    try {
      final file = await DefaultCacheManager().getSingleFile(photoURL);
      if (!file.existsSync()) return;

      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/avatar_$uid.jpg');
      try {
        if (dest.existsSync()) await dest.delete();
      } catch (_) {}
      await file.copy(dest.path);

      _avatarLastUrlSaved = photoURL;
      uc.setLocalPhotoPath(dest.path);
    } catch (_) {
      // fallback stays as NetworkImage
    } finally {
      _avatarPersistInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uc = context.watch<UserContext>();
    final dmUid = uc.currentUid;

    return AppBar(
      title: null,
      automaticallyImplyLeading: false,
      actions: [
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 15),

                // Logged-in / impersonated user banner
                Padding(
                  padding: const EdgeInsets.only(right: 1.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 95,
                        child: Text(
                          widget.displayName ?? '...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            overflow: TextOverflow.ellipsis,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),

                // Profile picture
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      final userContext = context.read<UserContext>();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChangeNotifierProvider<UserContext>.value(
                            value: userContext,
                            child: const ProfilePage(),
                          ),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2.0),
                      child: Builder(
                        builder: (context) {
                          final uc = context.watch<UserContext>();
                          final actingUid = uc.actingAsUid;

                          ImageProvider? localAvatar;
                          if (uc.localPhotoPath != null) {
                            final f = File(uc.localPhotoPath!);
                            if (f.existsSync()) localAvatar = FileImage(f);
                          }

                          if (localAvatar != null) {
                            return CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.grey.shade300,
                              backgroundImage: localAvatar,
                            );
                          }

                          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                            stream: FirebaseFirestore.instance
                                .collection('users_public')
                                .doc(actingUid)
                                .snapshots(),
                            builder: (context, snap) {
                              final uc = context.watch<UserContext>();
                              final uid = actingUid;

                              String? photoURL;
                              if (snap.hasData && snap.data!.data() != null) {
                                final m = snap.data!.data()!;
                                final v = m['photoURL'];
                                if (v is String && v.isNotEmpty) photoURL = v;
                              }

                              if ((uc.localPhotoPath == null ||
                                      !(File(uc.localPhotoPath!).existsSync())) &&
                                  photoURL != null) {
                                _persistAvatarLocalIfNeeded(context,
                                    uid: uid, photoURL: photoURL);
                              }

                              ImageProvider? provider;
                              if (uc.localPhotoPath != null) {
                                final f = File(uc.localPhotoPath!);
                                if (f.existsSync()) provider = FileImage(f);
                              }
                              provider ??=
                                  (photoURL != null ? NetworkImage(photoURL) : null);

                              return CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.grey.shade300,
                                backgroundImage: provider,
                                child: provider == null
                                    ? ClipOval(
                                        child: Image.asset(
                                          'assets/InApp/Placeholder_profilepic.png',
                                          fit: BoxFit.cover,
                                          width: 36,
                                          height: 36,
                                        ),
                                      )
                                    : null,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 1),

                // Buddy invite notifications
                Builder(
                  builder: (context) {
                    final userCtx = context.watch<UserContext>();
                    final String invitesUid = userCtx.actingAsUid;

                    return StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(invitesUid)
                          .collection('buddyInvites')
                          .where('status', isEqualTo: 'pending')
                          .snapshots(),
                      builder: (context, snapshot) {
                        final int buddyCount =
                            snapshot.hasData ? snapshot.data!.docs.length : 0;

                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            IconButton(
                              icon: Icon(Icons.person_add_alt_1,
                                  size: 24,
                                  color: Theme.of(context).colorScheme.secondary),
                              onPressed: () {
                                if (!snapshot.hasData ||
                                    snapshot.data!.docs.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('No buddy requests.')),
                                  );
                                  return;
                                }

                                showDialog(
                                  context: context,
                                  builder: (ctx) {
                                    return AlertDialog(
                                      title: const Text('Buddy Requests'),
                                      content: SizedBox(
                                        width: 310,
                                        child: ListView.builder(
                                          shrinkWrap: true,
                                          itemCount: snapshot.data!.docs.length,
                                          itemBuilder: (_, i) {
                                            final doc = snapshot.data!.docs[i];
                                            final data = doc.data()
                                                as Map<String, dynamic>;
                                            final fromUid =
                                                data['fromUid'] ?? '';
                                            final fromName =
                                                data['fromDisplayName'] ??
                                                    'Someone';

                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '$fromName added you!',
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold),
                                                ),
                                                const SizedBox(height: 6),
                                                Row(
                                                  children: [
                                                    TextButton(
                                                      onPressed: () async {
                                                        await acceptBuddyInvite(
                                                          ownerUid: fromUid,
                                                          buddyUid: invitesUid,
                                                        );
                                                        if (ctx.mounted) {
                                                          Navigator.pop(ctx);
                                                        }
                                                      },
                                                      child: const Text('Accept'),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    TextButton(
                                                      onPressed: () async {
                                                        await denyBuddyInvite(
                                                          ownerUid: fromUid,
                                                          buddyUid: invitesUid,
                                                        );
                                                        if (ctx.mounted) {
                                                          Navigator.pop(ctx);
                                                        }
                                                      },
                                                      child: const Text('Deny'),
                                                    ),
                                                  ],
                                                ),
                                                const Divider(),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                            if (buddyCount > 0)
                              Positioned(
                                right: 6,
                                top: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '$buddyCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),

                // DM badge
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(dmUid)
                      .collection('conversations')
                      .where('participants.$dmUid', isEqualTo: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return IconButton(
                        icon: Icon(Icons.message_outlined,
                            size: 26,
                            color: Theme.of(context).colorScheme.secondary),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const DirectMessages(),
                            ),
                          );
                        },
                      );
                    }

                    int unreadCount = 0;
                    final me = FirebaseAuth.instance.currentUser?.uid;

                    if (snapshot.hasData && me != null) {
                      for (var doc in snapshot.data!.docs) {
                        final data = doc.data();
                        final state = data['participantState']?[me];
                        final count =
                            (state is Map && state['unreadCount'] is int)
                                ? state['unreadCount'] as int
                                : 0;
                        unreadCount += count;
                      }
                    }

                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        IconButton(
                          icon: Icon(Icons.message_outlined,
                              size: 26,
                              color: Theme.of(context).colorScheme.secondary),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const DirectMessages(),
                              ),
                            );
                          },
                        ),
                        if (unreadCount > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                unreadCount.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),

                const SizedBox(width: 1),

                // App logo
                Image.asset(
                  'assets/InApp/transparent_good_lift_logo_inApp.png',
                  height: 36,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 2),

                // Menu icon
                GestureDetector(
                  onTap: () => widget.scaffoldKey.currentState?.openDrawer(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3.0),
                    child: Icon(Icons.menu, size: 28, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
