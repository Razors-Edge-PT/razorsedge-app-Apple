/// Recovering from a stored download URL that has stopped working.
///
/// ── Why a stored URL goes bad ───────────────────────────────────────────────
/// A Firebase download URL embeds an access token. That token can be REVOKED —
/// from the console, by a security response, or by any metadata rewrite that
/// rolls it — and the URL sitting in the post document keeps pointing at it.
/// The object is still there and the user is still allowed to see it; the
/// string just no longer opens it. Storage will mint a fresh URL for the same
/// object on request, so the honest response is to ask for one and try again.
///
/// ── Why exactly once ────────────────────────────────────────────────────────
/// A refresh that can itself fail is a retry loop waiting to happen, and a loop
/// against Storage is a bill. So a refresh is attempted at most ONCE per load
/// attempt, only when there is a `storagePath` to look the object up by, and
/// only when the fresh URL actually differs from the one that just failed —
/// retrying an identical URL cannot produce a different answer.
///
/// ── Why it does not touch cache identity ────────────────────────────────────
/// The key stays exactly what it was: owner + object path + variant (see
/// media_identity.dart). The URL is the transport; the key is the identity.
/// That separation is the whole point — a token that rotates or is revoked
/// changes the URL and nothing else, so the refreshed fetch writes to and reads
/// from the same cache entry the original attempt would have.
library;

import 'dart:async';

import 'package:firebase_storage/firebase_storage.dart';

/// Looks up a fresh download URL for a Storage object, or null.
typedef FreshUrlLookup = Future<String?> Function(String storagePath);

/// True when [error] looks like "you are not allowed to open this URL" rather
/// than "this object does not exist".
///
/// The distinction decides whether a refresh is worth attempting at all. A 404
/// or `object-not-found` means the bytes are gone and a new URL would point at
/// the same absence, so those go straight to a clear error state.
bool isAuthorizationFailure(Object error) {
  final String text = error.toString().toLowerCase();

  // Genuinely missing beats everything: never spend a Storage call on it.
  if (text.contains('404') ||
      text.contains('object-not-found') ||
      text.contains('not found')) {
    return false;
  }

  if (error is FirebaseException) {
    final String code = error.code.toLowerCase();
    return code.contains('unauthorized') ||
        code.contains('unauthenticated') ||
        code.contains('permission');
  }

  // flutter_cache_manager throws HttpExceptionWithStatus, whose statusCode is
  // read here by duck typing rather than by importing the package's internals.
  try {
    final Object? status = (error as dynamic).statusCode as Object?;
    if (status is int) return status == 401 || status == 403;
  } catch (_) {
    // No statusCode on this error; fall through to the message.
  }

  return text.contains('401') ||
      text.contains('403') ||
      text.contains('unauthorized') ||
      text.contains('permission denied') ||
      text.contains('forbidden');
}

/// Asks Storage for a fresh download URL.
///
/// Injectable so the recovery path is testable without a live Firebase app —
/// the production implementation is one call, and everything interesting about
/// this feature is in when it is invoked rather than in what it does.
class StorageUrlRefresher {
  StorageUrlRefresher({FreshUrlLookup? lookup}) : _injected = lookup;

  final FreshUrlLookup? _injected;

  static Future<String?> _live(String storagePath) async {
    try {
      return await FirebaseStorage.instance.ref(storagePath).getDownloadURL();
    } catch (_) {
      // Offline, revoked, or the object really is gone. The caller already has
      // a failure to report; this one adds nothing.
      return null;
    }
  }

  /// A fresh URL for [storagePath], or null when there is nothing better to
  /// offer. Never throws.
  Future<String?> freshUrl(String storagePath) async {
    if (storagePath.trim().isEmpty) return null;
    try {
      return await (_injected ?? _live)(storagePath);
    } catch (_) {
      return null;
    }
  }

  /// A fresh URL that is actually DIFFERENT from [current], or null.
  ///
  /// Returning null for an identical URL is what stops a pointless second
  /// attempt: the same string will fail the same way.
  Future<String?> replacementFor(String storagePath, String current) async {
    final String? fresh = await freshUrl(storagePath);
    if (fresh == null) return null;
    final String trimmed = fresh.trim();
    if (trimmed.isEmpty || trimmed == current.trim()) return null;
    return trimmed;
  }
}

/// The refresher the app uses. Replaceable for tests.
StorageUrlRefresher profileUrlRefresher = StorageUrlRefresher();

/// Resets [profileUrlRefresher] to the default. For tests.
void resetProfileUrlRefresher() => profileUrlRefresher = StorageUrlRefresher();
