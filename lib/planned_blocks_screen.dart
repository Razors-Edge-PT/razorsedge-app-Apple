import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PlannedBlocksScreen extends StatefulWidget {
  const PlannedBlocksScreen({Key? key}) : super(key: key);

  @override
  State<PlannedBlocksScreen> createState() => _PlannedBlocksScreenState();
}

class _PlannedBlocksScreenState extends State<PlannedBlocksScreen> {
  final userId = FirebaseAuth.instance.currentUser!.uid;

  Future<void> _setBlockAsActive(String blockId) async {
    final blocksRef = FirebaseFirestore.instance.collection('planned_blocks').doc(userId).collection('blocks');
    final activeBlocks = await blocksRef.where('isActive', isEqualTo: true).get();

    for (var doc in activeBlocks.docs) {
      await doc.reference.update({'isActive': false});
    }

    await blocksRef.doc(blockId).update({'isActive': true});
    setState(() {});
  }

  Future<void> _deleteBlock(String blockId) async {
    await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .delete();
  }

  @override
  Widget build(BuildContext context) {
    final blocksRef = FirebaseFirestore.instance.collection('planned_blocks').doc(userId).collection('blocks');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planned Blocks'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: blocksRef.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final blocks = snapshot.data!.docs;

          if (blocks.isEmpty) {
            return const Center(child: Text('No planned blocks found.'));
          }

          return ListView.builder(
            itemCount: blocks.length,
            itemBuilder: (context, index) {
              final doc = blocks[index];
              final data = doc.data() as Map<String, dynamic>;
              final blockId = doc.id;
              final blockName = data['blockName'] ?? 'Untitled Block';
              final isActive = data['isActive'] ?? false;
              final start = (data['startDate'] as Timestamp).toDate();
              final end = (data['endDate'] as Timestamp).toDate();

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: ListTile(
                  title: Text(blockName),
                  subtitle: Text('From ${start.toLocal().toString().split(" ")[0]} to ${end.toLocal().toString().split(" ")[0]}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive)
                        const Chip(label: Text('Active', style: TextStyle(color: Colors.white)), backgroundColor: Colors.green),
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        onPressed: () => _setBlockAsActive(blockId),
                        tooltip: 'Set Active',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteBlock(blockId),
                        tooltip: 'Delete Block',
                      ),
                    ],
                  ),
                  onTap: () {
                    // Navigate to block editor screen with blockId
                    Navigator.pushNamed(context, '/block_builder', arguments: {'blockId': blockId});
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
