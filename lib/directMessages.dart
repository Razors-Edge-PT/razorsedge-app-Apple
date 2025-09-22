import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';


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
                    final convId  = convIdFor(uid, buddyUid);
                    final convRef = FirebaseFirestore.instance.collection('conversations').doc(convId);

                    // ⚡ Bootstrap/touch conversation without a transaction (snappier local echo)
                    final now = FieldValue.serverTimestamp();
                    try {
                      // If it exists, just touch updatedAt (won't overwrite lastMessage/participantState)
                      await convRef.update({'updatedAt': now});
                    } catch (_) {
                      // If missing, create with the same initial shape you had before
                      await convRef.set({
                        'participants': {uid: true, buddyUid: true},
                        'createdAt': now,
                        'updatedAt': now,
                        'lastMessage': null,
                        'participantState': {
                          uid: {'unreadCount': 0},
                          buddyUid: {'unreadCount': 0},
                        },
                      }, SetOptions(merge: false));
                    }

                    if (!context.mounted) return;
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => ConversationPage(
                          convId: convId,
                          otherUid: buddyUid,
                        ),
                      ),
                    );
                  }

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
                      style: TextStyle(
                        color: unreadCount > 0 ? Colors.white : Colors.white70, // 👈 bold white if unread
                        fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                      ),
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


class ConversationPage extends StatefulWidget {
  final String convId;
  final String otherUid;

  const ConversationPage({
    super.key,
    required this.convId,
    required this.otherUid,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final Map<String, DateTime> _pendingLatencyMarks = {};
  final Set<String> _localEchoPrinted = {};

  // Scrolling infra
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();

  bool _didInitialJump = false;
  String? _lastLatestMsgId; // for "auto-scroll on my new message"
  Timestamp? _initialLastReadAt;   // from my participantState at page open
  bool _gotInitialLastReadAt = false;

  // mark-as-read when near bottom
  Future<void> _markAsRead() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await FirebaseFirestore.instance
        .collection('conversations')
        .doc(widget.convId)
        .update({
      'participantState.$uid.unreadCount': 0,
      'participantState.$uid.lastReadAt': FieldValue.serverTimestamp(),
    });
  }

  // Helper: jump to index safely
  void _jumpToIndex(int index, {double alignment = 0.1}) {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.jumpTo(index: index, alignment: alignment);
  }

  // Helper: animate to bottom
  void _scrollToBottom({bool animated = true}) {
    if (!_itemScrollController.isAttached) return;
    if (animated) {
      _itemScrollController.scrollTo(
        index: _lastItemIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _itemScrollController.jumpTo(index: _lastItemIndex, alignment: 1.0);
    }
  }

  int _lastItemIndex = 0;

  // You already pass this from the composer
  void _markSendStart(String clientId, DateTime startedAt) {
    _pendingLatencyMarks[clientId] = startedAt;
  }

  @override
  void initState() {
    super.initState();

    // Listen for bottom reach (you already have this if you followed earlier steps)
    _itemPositionsListener.itemPositions.addListener(() {
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;

      final lastVisible = positions.where((p) => p.index == _lastItemIndex).toList();
      if (lastVisible.isNotEmpty) {
        final p = lastVisible.first;
        final visiblePortion = (p.itemTrailingEdge - p.itemLeadingEdge).clamp(0.0, 1.0);
        final isMostlyVisible = p.itemTrailingEdge >= 0.95 && visiblePortion >= 0.95;
        if (isMostlyVisible) {
          _markAsRead();
        }
      }
    });

    // 👇 One-time fetch of my lastReadAt from the conversation doc
    final uid = FirebaseAuth.instance.currentUser!.uid;
    FirebaseFirestore.instance
        .collection('conversations')
        .doc(widget.convId)
        .get()
        .then((snap) {
      final data = snap.data() as Map<String, dynamic>? ?? {};
      final myState = (data['participantState'] ?? {})[uid] as Map<String, dynamic>? ?? {};
      _initialLastReadAt = myState['lastReadAt'] as Timestamp?;
      if (mounted) setState(() => _gotInitialLastReadAt = true);
    }).catchError((_) {
      if (mounted) setState(() => _gotInitialLastReadAt = true);
    });
  }


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
                    .doc(widget.convId)
                    .collection('messages')
                    .snapshots(includeMetadataChanges: true),
                builder: (context, snapshot) {
                  if (!_gotInitialLastReadAt || snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // Sort by server sentAt then fallback localSentAt
                  final msgs = (snapshot.data?.docs ?? []).toList()
                    ..sort((a, b) {
                      int ts(QueryDocumentSnapshot q) {
                        final m = q.data() as Map<String, dynamic>;
                        final server = (m['sentAt'] as Timestamp?)?.millisecondsSinceEpoch;
                        final local  = (m['localSentAt'] as int?) ?? 0;
                        return server ?? local;
                      }
                      return ts(a).compareTo(ts(b));
                    });

                  _lastItemIndex = msgs.isEmpty ? 0 : msgs.length - 1;

                  // Compute "first unread" index based on the cached _initialLastReadAt
                  int firstUnreadIndex = -1;
                  if (msgs.isNotEmpty) {
                    for (var i = 0; i < msgs.length; i++) {
                      final m = msgs[i].data() as Map<String, dynamic>;
                      final sentAt = (m['sentAt'] as Timestamp?);
                      final unread = (_initialLastReadAt == null)
                          ? (sentAt != null) // if we’ve never read, consider server-timestamped items unread
                          : (sentAt != null && sentAt.toDate().isAfter(_initialLastReadAt!.toDate()));
                      if (unread) {
                        firstUnreadIndex = i;
                        break;
                      }
                    }
                  }

                  // One-time initial jump: to first unread, else bottom
                  if (!_didInitialJump && msgs.isNotEmpty) {
                    _didInitialJump = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (firstUnreadIndex != -1) {
                        _jumpToIndex(firstUnreadIndex, alignment: 0.1);
                      } else {
                        _jumpToIndex(_lastItemIndex, alignment: 1.0);
                      }
                    });
                  }

                  // Auto-scroll if a brand-new last message from ME appears
                  if (msgs.isNotEmpty) {
                    final last = msgs.last;
                    final lastData = last.data() as Map<String, dynamic>;
                    final lastFromSelf = (lastData['senderId']?.toString() ?? '') ==
                        FirebaseAuth.instance.currentUser!.uid;
                    if (lastFromSelf) {
                      final latestId = last.id;
                      if (latestId != _lastLatestMsgId) {
                        _lastLatestMsgId = latestId;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _scrollToBottom(animated: true);
                        });
                      }
                    }
                  }

                  return ScrollablePositionedList.builder(
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _itemPositionsListener,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final qDoc = msgs[i];
                      final raw  = qDoc.data();
                      if (raw is! Map<String, dynamic>) return const SizedBox.shrink();
                      final data = raw;

                      final uid = FirebaseAuth.instance.currentUser!.uid;
                      final fromSelf = (data['senderId']?.toString() ?? '') == uid;

                      // Latency prints (local-echo + server-ack)
                      final clientId = (data['clientId'] ?? '').toString();
                      if (clientId.isNotEmpty && _pendingLatencyMarks.containsKey(clientId)) {
                        final started = _pendingLatencyMarks[clientId]!;
                        final now = DateTime.now();

                        if (!_localEchoPrinted.contains(clientId)) {
                          final localMs = now.difference(started).inMilliseconds;
                          _localEchoPrinted.add(clientId);
                          // ignore: avoid_print
                          print('⚡ [DM] local-echo: ${localMs} ms (clientId=$clientId)');
                        }

                        if (!qDoc.metadata.hasPendingWrites) {
                          final serverMs = now.difference(started).inMilliseconds;
                          _pendingLatencyMarks.remove(clientId);
                          _localEchoPrinted.remove(clientId);
                          // ignore: avoid_print
                          print('✅ [DM] server-ack: ${serverMs} ms (clientId=$clientId)');
                        }
                      }

                      final type = (data['type'] ?? 'text') as String;

                      return Align(
                        alignment: fromSelf ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: fromSelf ? Colors.cyanAccent.shade700 : Colors.blueGrey.shade700,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: (type == 'image' && (data['imageUrl'] ?? '').toString().isNotEmpty)
                              ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              data['imageUrl'],
                              fit: BoxFit.cover,
                            ),
                          )
                              : Text(
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

            // Composer (unchanged)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: _MessageComposer(
                  convId: widget.convId,
                  otherUid: widget.otherUid,
                  onClientSend: _markSendStart,
                ),
              ),
            ),
          ],
        )
    );
  }
}



class _MessageComposer extends StatefulWidget {
  final String convId;
  final String otherUid;
  final void Function(String clientId, DateTime startedAt)? onClientSend;

  const _MessageComposer({
    super.key,
    required this.convId,
    required this.otherUid,
    this.onClientSend,
  });


  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _controller = TextEditingController();

  bool _sending = false;                 // 👈 prevents double-sends
  static const int _maxChars = 2000;     // 👈 matches Firestore rule cap

  Future<void> _sendMessage() async {
    if (_sending) return;

    // Trim + enforce rule-aligned cap (2000 code points)
    var text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text.runes.length > _maxChars) {
      final runes = text.runes.toList().sublist(0, _maxChars);
      text = String.fromCharCodes(runes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message truncated to 2000 characters.')),
        );
      }
    }

    _controller.clear();
    setState(() => _sending = true);

    try {
      final uid      = FirebaseAuth.instance.currentUser!.uid;
      final otherUid = widget.otherUid;
      final convRef  = FirebaseFirestore.instance.collection('conversations').doc(widget.convId);
      final msgRef   = convRef.collection('messages').doc();

      // Generate a clientId and mark start for latency
      final rnd = Random().nextInt(1 << 32);
      final clientId = '${DateTime.now().microsecondsSinceEpoch}_$rnd';
      widget.onClientSend?.call(clientId, DateTime.now());

      // 1) Message write (no transaction) → instant local echo
      await msgRef.set({
        'senderId': uid,
        'type': 'text',
        'text': text,
        'clientId': clientId,
        'localSentAt': DateTime.now().millisecondsSinceEpoch, // client-side sort
        'sentAt': FieldValue.serverTimestamp(),               // server time later
      });

      // 2) Best-effort conversation state update
      final now = FieldValue.serverTimestamp();
      await convRef.update({
        'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
        'updatedAt': now,
        'participantState.$uid.unreadCount': 0,
        'participantState.$uid.lastReadAt': now,
        'participantState.$otherUid.unreadCount': FieldValue.increment(1),
      }).catchError((_) async {
        // Bootstrap if convo missing (e.g., deep link)
        await convRef.set({
          'participants': {uid: true, otherUid: true},  // immutable per rules
          'createdAt': now,
          'updatedAt': now,
          'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
          'participantState': {
            uid: {'lastReadAt': now, 'unreadCount': 0},
            otherUid: {'lastReadAt': null, 'unreadCount': 1},
          },
        }, SetOptions(merge: true));
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
