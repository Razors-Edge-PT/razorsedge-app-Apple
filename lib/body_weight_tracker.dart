import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class BodyWeightTracker extends StatefulWidget {
  final Function(String)? onWeightSaved; // Declare the callback parameter

  const BodyWeightTracker({this.onWeightSaved, super.key}); // Add it to the constructor

  @override
  State<BodyWeightTracker> createState() => _BodyWeightTrackerState();
}

class _BodyWeightTrackerState extends State<BodyWeightTracker> {
  final TextEditingController _weightController = TextEditingController();
  final List<double> _weights = [];

  @override
  void initState() {
    super.initState();
    _fetchWeights();
  }

  Future<void> _fetchWeights() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userId = user.uid;
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .get();

      _weights.clear();
      for (var doc in snapshot.docs) {
        final data = doc.data();
        _weights.add(data['weight']);
      }
      setState(() {});
    }
  }

  void _saveWeight(double weight, String unit) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final userId = user.uid;
      final weightData = {
        'weight': weight,
        'unit': unit,
        'timestamp': FieldValue.serverTimestamp(),
      };

      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('weights')
            .add(weightData);

        _weightController.clear();
        _fetchWeights();
        FocusScope.of(context).unfocus();

        // Call the callback to update the most recent weight
        if (widget.onWeightSaved != null) { // Use 'widget.onWeightSaved'
          widget.onWeightSaved!('${weight.toString()} $unit');
        }
      } catch (error) {
        print(error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Body Weight Tracker'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _weightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Weight (kg)',
              ),
            ),
            ElevatedButton(
              onPressed: () {
                String unit = 'kg';
                double weight = double.tryParse(_weightController.text) ?? 0.0;
                _saveWeight(weight, unit);
              },
              child: const Text('Save'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _weights.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text('${_weights[index]} Kg'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
