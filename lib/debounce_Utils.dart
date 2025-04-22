import 'package:localtest222/debounce_utils.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Debouncer {
  final Duration delay;
  Timer? _timer;
  VoidCallback? _action;

  Debouncer({required this.delay});

  void run(VoidCallback action) {
    _action = action;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _action?.call();
    });
  }

  void cancel() {
    _timer?.cancel();
  }

}

Future<void> clearWorkoutDraftCache() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('workout_draft');
}

