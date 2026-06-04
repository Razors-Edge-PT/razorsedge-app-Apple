import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kLastAuthBreadcrumb = 'goodlift_last_auth_breadcrumb';

/// Writes a timestamped auth diagnostic entry to SharedPreferences and
/// debugPrint. Safe to call from any isolate; swallows all errors so it
/// never disrupts app flow.
Future<void> writeAuthBreadcrumb(String message) async {
  try {
    final ts = DateTime.now().toIso8601String();
    final entry = '$ts | $message';
    debugPrint('[AUTHBC] $entry');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastAuthBreadcrumb, entry);
  } catch (_) {}
}

/// Returns the most recently written breadcrumb, or null if none.
Future<String?> readAuthBreadcrumb() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastAuthBreadcrumb);
  } catch (_) {
    return null;
  }
}
