import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Deterministic conversation id for a pair of users.
/// Ensures both users always open the same thread, no query needed.
String convIdFor(String a, String b) {
  final list = [a, b]..sort();
  return '${list[0]}_${list[1]}';
}

class BuddyPickerPage extends StatelessWidget {
  const BuddyPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("New Message"),
        backgroundColor: Colors.blueGrey.shade900,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('buddyAssignments')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: Text("No gym buddies yet"));
          }

          final data = snap.data!.data() as Map<String, dynamic>? ?? {};
          final buddies = Map<String, dynamic>.from(data['athletes'] ?? {});
          if (buddies.isEmpty) {
            return const Center(child: Text("No gym buddies yet"));
          }

          return ListView(
            children: buddies.entries.map((entry) {
              final buddyUid = entry.key; // 👈 this IS the other user’s uid
              final buddyData = entry.value as Map<String, dynamic>? ?? {};
              final displayName =
              (buddyData['displayName'] ?? buddyData['email'] ?? buddyUid).toString();

              return ListTile(
                leading: const CircleAvatar(
                  radius: 20,
                  backgroundImage: AssetImage('assets/InApp/Placeholder_profilepic.png'),
                ),
                title: Text(displayName, style: const TextStyle(fontWeight: FontWeight.bold)),
                onTap: () async {
                  final convId = convIdFor(uid, buddyUid);
                  final convRef =
                  FirebaseFirestore.instance.collection('conversations').doc(convId);

                  // Bootstrap the conversation if it doesn't exist yet (no indexes needed)
                  await FirebaseFirestore.instance.runTransaction((tx) async {
                    final snap = await tx.get(convRef);
                    final now = FieldValue.serverTimestamp();
                    if (!snap.exists) {
                      tx.set(convRef, {
                        'participants': {uid: true, buddyUid: true},
                        'createdAt': now,
                        'updatedAt': now,
                        'lastMessage': null,
                        'participantState': {
                          uid: {'unreadCount': 0},
                          buddyUid: {'unreadCount': 0},
                        },
                      });
                    } else {
                      tx.update(convRef, {'updatedAt': now});
                    }
                  });

                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => ConversationPage(
                        convId: convId,
                        otherUid: buddyUid,
                      ),
                    ),
                  );
                },
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class DirectMessages extends StatelessWidget {
  const DirectMessages({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Messages"),
        backgroundColor: Colors.blueGrey.shade900,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.cyanAccent),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BuddyPickerPage()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        // NO orderBy here → avoids composite index requirement.
        stream: FirebaseFirestore.instance
            .collection('conversations')
            .where('participants.$uid', isEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text("No conversations yet"));
          }

          // Sort client-side by updatedAt desc
          docs.sort((a, b) {
            final ad = (a.data() as Map<String, dynamic>)['updatedAt'] as Timestamp?;
            final bd = (b.data() as Map<String, dynamic>)['updatedAt'] as Timestamp?;
            final at = ad?.toDate().millisecondsSinceEpoch ?? 0;
            final bt = bd?.toDate().millisecondsSinceEpoch ?? 0;
            return bt.compareTo(at);
          });

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final data = docs[i].data() as Map<String, dynamic>;
              final convId = docs[i].id;

              final participants = Map<String, dynamic>.from(data['participants'] ?? {});
              final otherUid =
              participants.keys.firstWhere((k) => k != uid, orElse: () => uid);

              final lastMsg = (data['lastMessage']?['text'] ?? '') as String;
              final updatedAt = (data['updatedAt'] as Timestamp?)?.toDate();
              final state = data['participantState']?[uid];
              final unreadCount =
              (state != null && state['unreadCount'] is int) ? state['unreadCount'] as int : 0;

              return FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance.collection('users_public').doc(otherUid).get(),
                builder: (context, userSnap) {
                  final userData = userSnap.data?.data() as Map<String, dynamic>? ?? {};
                  final username = (userData['username'] ?? otherUid).toString(); // fallback to uid if missing

                  return ListTile(
                    leading: const CircleAvatar(
                      radius: 20,
                      backgroundImage: AssetImage('assets/InApp/Placeholder_profilepic.png'),
                    ),
                    title: Text(
                      username, // 👈 show username instead of "Conversation"
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      lastMsg,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (updatedAt != null)
                          Text(
                            "${updatedAt.hour}:${updatedAt.minute.toString().padLeft(2, '0')}",
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        if (unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              unreadCount.toString(),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ConversationPage(
                            convId: convId,
                            otherUid: otherUid,
                          ),
                        ),
                      );
                    },
                  );
                },
              );

            },
          );
        },
      ),
    );
  }
}

class ConversationPage extends StatelessWidget {
  final String convId;
  final String otherUid;

  const ConversationPage({
    super.key,
    required this.convId,
    required this.otherUid,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Chat"),
        backgroundColor: Colors.blueGrey.shade900,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('conversations')
                  .doc(convId)
                  .collection('messages')
                  .orderBy('sentAt', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final msgs = snapshot.data?.docs ?? [];
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final data = msgs[i].data() as Map<String, dynamic>;
                    final fromSelf = data['senderId'] == uid;

                    return Align(
                      alignment:
                      fromSelf ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: fromSelf
                              ? Colors.cyanAccent.shade700
                              : Colors.blueGrey.shade700,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          (data['text'] ?? '').toString(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // Safe composer
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: _MessageComposer(
                convId: convId,
                otherUid: otherUid,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageComposer extends StatefulWidget {
  final String convId;
  final String otherUid;

  const _MessageComposer({
    super.key,
    required this.convId,
    required this.otherUid,
  });

  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _controller = TextEditingController();

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final otherUid = widget.otherUid;

    final convRef =
    FirebaseFirestore.instance.collection('conversations').doc(widget.convId);
    final msgRef = convRef.collection('messages').doc();

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final convSnap = await tx.get(convRef);
      final now = FieldValue.serverTimestamp();

      // Write message
      tx.set(msgRef, {
        'senderId': uid,
        'text': text,
        'sentAt': now,
        'type': 'text',
      });

      if (convSnap.exists) {
        tx.update(convRef, {
          'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
          'updatedAt': now,
          'participantState.$uid.unreadCount': 0,
          'participantState.$otherUid.unreadCount': FieldValue.increment(1),
        });
      } else {
        // Bootstrap if someone deep-linked without BuddyPicker
        tx.set(convRef, {
          'participants': {uid: true, otherUid: true},
          'createdAt': now,
          'updatedAt': now,
          'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
          'participantState': {
            uid: {'lastReadAt': now, 'unreadCount': 0},
            otherUid: {'lastReadAt': null, 'unreadCount': 1},
          },
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(
              hintText: "Type a message…",
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.send, color: Colors.cyanAccent),
          onPressed: _sendMessage,
        ),
      ],
    );
  }
}
