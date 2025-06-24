import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

class PlannedBlocksScreen extends StatefulWidget {
  const PlannedBlocksScreen({super.key});

  @override
  State<PlannedBlocksScreen> createState() => _PlannedBlocksScreenState();
}

class _PlannedBlocksScreenState extends State<PlannedBlocksScreen> {
  final userId = FirebaseAuth.instance.currentUser!.uid;

  Future<void> _setBlockAsActive(String blockId) async {
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks');

    // load the block you want to activate
    final newActiveSnap = await blocksRef.doc(blockId).get();
    final newName = (newActiveSnap.data()?['name'] as String?) ?? 'Unnamed Block';

    // find any other active ones
    final activeQuery = await blocksRef.where('isActive', isEqualTo: true).get();
    final others = activeQuery.docs.where((d) => d.id != blockId).toList();

    if (others.isNotEmpty) {
      final oldName = (others.first.data()['name'] as String?) ?? 'Unnamed Block';
      final shouldOverride = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Override Active Block?'),
          content: Text(
              '“$oldName” is currently active.\n\n'
                  'Activate “$newName” instead?'
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('Yes')),
          ],
        ),
      );
      if (shouldOverride != true) return;

      // batch‐deactivate the old one(s)
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in others) {
        batch.update(doc.reference, {'isActive': false});
      }
      await batch.commit();
    }

    // now activate the new one
    await blocksRef.doc(blockId).update({'isActive': true});
    setState(() { /* so your UI re‐reads the stream */ });
  }

  Future<void> _deleteBlock(String blockId) async {
    await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .delete();
  }

  void _createNewBlock() {
    Navigator.pushNamed(
      context,
      '/block_builder',
      arguments: {'newBlock': true}, // ✅ prevents draft from loading
    );
  }

  void _editBlock(String blockId) {
    Navigator.pushNamed(
      context,
      '/block_builder',
      arguments: {'blockId': blockId},
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocksRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks');

    return Scaffold(
      appBar: AppBar(title: const Text('Planned Blocks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewBlock,
        icon: const Icon(Icons.add),
        label: const Text('New Block'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: blocksRef.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final rawDocs = snapshot.data!.docs;

          if (rawDocs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('No planned blocks yet.'),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _createNewBlock,
                    icon: const Icon(Icons.add),
                    label: const Text('Create Block'),
                  )
                ],
              ),
            );
          }

          final blocks = rawDocs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            data['id'] = doc.id;
            return data;
          }).toList();

          // ✅ Sort active blocks first
          blocks.sort((a, b) {
            final aActive = a['isActive'] == true;
            final bActive = b['isActive'] == true;
            return (bActive ? 1 : 0).compareTo(aActive ? 1 : 0);
          });

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: blocks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final block = blocks[index];
              final blockId = block['id'];

              final blockName = block['name'] ?? 'Untitled Block';

              final isActive = block['isActive'] ?? false;

              String dateRange = 'No dates';
              try {
                final start = (block['startDate'] as Timestamp).toDate();
                final end = (block['endDate'] as Timestamp).toDate();
                dateRange =
                    '${DateFormat('dd MMM').format(start)} → ${DateFormat('dd MMM yyyy').format(end)}';
              } catch (_) {}

              final exercises = (block['exercises'] as List?)?.length ?? 0;

              return Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  onTap: () => _editBlock(blockId),
                  title: Text(
                    blockName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dateRange),
                      if (exercises > 0)
                        Text('$exercises exercises',
                            style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                  leading: CircleAvatar(
                    backgroundColor: isActive ? Colors.green : Colors.grey[300],
                    child: Icon(
                      isActive ? Icons.check : Icons.fitness_center,
                      color: Colors.white,
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'activate') {
                        await _setBlockAsActive(blockId);
                      } else if (value == 'delete') {
                        await _deleteBlock(blockId);
                      }
                    },
                    itemBuilder: (context) => [
                      if (!isActive)
                        const PopupMenuItem(
                          value: 'activate',
                          child: Text('Set Active'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
