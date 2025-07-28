import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';

class RequestAccessScreen extends StatefulWidget {
  const RequestAccessScreen({super.key});

  @override
  State<RequestAccessScreen> createState() => _RequestAccessScreenState();
}

class _RequestAccessScreenState extends State<RequestAccessScreen> {
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _feedback;

  Future<void> _submitRequest() async {
    final userContext = context.read<UserContext>();
    final coachUid = userContext.actorUid;
    final athleteUid = _controller.text.trim();

    if (athleteUid.isEmpty || athleteUid.length < 6) {
      setState(() => _feedback = "Please enter a valid athlete UID.");
      return;
    }

    setState(() {
      _isSubmitting = true;
      _feedback = null;
    });

    try {
      await FirebaseFirestore.instance.collection('accessRequests').add({
        'coachUid': coachUid,
        'athleteUid': athleteUid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _feedback = "Request sent to $athleteUid ✅";
        _controller.clear();
      });
    } catch (e) {
      setState(() => _feedback = "Error sending request: $e");
    } finally {
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Request Athlete Access")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text("Enter the UID of the athlete you'd like access to:"),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: "Athlete UID",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_feedback != null)
              Text(
                _feedback!,
                style: TextStyle(
                  color: _feedback!.startsWith("Error") ? Colors.red : Colors.green,
                  fontWeight: FontWeight.bold,
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: Text(_isSubmitting ? "Sending..." : "Submit Request"),
              onPressed: _isSubmitting ? null : _submitRequest,
            ),
          ],
        ),
      ),
    );
  }
}
