import 'dart:async';
import 'package:flutter/material.dart';

/// Animating "Wait for it..." ellipsis shown during the loading phase.
/// Matches the same behavior as the original WES WaitForIt widget.
class Wes2WaitForIt extends StatefulWidget {
  const Wes2WaitForIt({super.key});

  @override
  State<Wes2WaitForIt> createState() => _Wes2WaitForItState();
}

class _Wes2WaitForItState extends State<Wes2WaitForIt> {
  int _dots = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _dots = (_dots + 1) % 4);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      'Wait for it${'.' * _dots}',
      style: const TextStyle(color: Colors.white, fontSize: 14),
    );
  }
}

/// Shown when a day loads successfully but has no exercises.
class Wes2EmptyState extends StatelessWidget {
  const Wes2EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No exercises planned yet, add some to get started',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
      ),
    );
  }
}
