/// The support profile + DM override, as the app sees it.
///
/// `accessGrants/{uid}.profileAndDmOverride` is written only by a server-side
/// Admin script; the security rules forbid every client write and enforce
/// what it allows (firestore.rules `hasProfileDmOverride`). The app reads it
/// only to show the right controls:
///
///   * the holder may open any profile and sees Message beside the genuine
///     friendship control;
///   * everyone else's inbox includes a conversation the holder opened.
///
/// Nothing here is a security boundary. A read failure means "no override":
/// the ordinary, friend-only experience.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

class AccessGrantsRepository {
  AccessGrantsRepository({FirebaseFirestore? firestore})
      : _dbOverride = firestore;

  static const String collection = 'accessGrants';
  static const String field = 'profileAndDmOverride';

  final FirebaseFirestore? _dbOverride;
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;

  /// Every account holding the override (in practice, one support account).
  Stream<Set<String>> watchHolders() {
    return _db
        .collection(collection)
        .where(field, isEqualTo: true)
        .snapshots()
        .map((QuerySnapshot<Map<String, dynamic>> s) => <String>{
              for (final QueryDocumentSnapshot<Map<String, dynamic>> d
                  in s.docs)
                if (d.data()[field] == true) d.id,
            })
        .transform(StreamTransformer<Set<String>, Set<String>>.fromHandlers(
          handleError: (Object _, StackTrace __, EventSink<Set<String>> sink) =>
              sink.add(const <String>{}),
        ));
  }

  /// Whether [uid] holds the override; false on any failure.
  Stream<bool> watchHolds(String uid) =>
      watchHolders().map((Set<String> h) => h.contains(uid)).distinct();
}
