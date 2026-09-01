/// Wiring for WES2 durable saving.
///
/// One process-wide outbox and one engine. A second SQLite handle on the same
/// file would let two processors apply the same queued edit at once, so the
/// initialisation is idempotent and concurrent callers await the SAME future —
/// the convention `ProfileServices` already uses for the media outbox.
///
/// Deliberately independent of the profile/video services: workout saving must
/// keep working when set video or media upload cannot start.
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../WES2_repository.dart';
import 'wes2_mutation_outbox.dart';
import 'wes2_sync_engine.dart';

class Wes2SyncServices {
  Wes2SyncServices._({required this.outbox, required this.engine});

  static Wes2SyncServices? _instance;
  static Future<Wes2SyncServices>? _initialising;

  final Wes2MutationOutbox outbox;
  final Wes2SyncEngine engine;

  static bool get isReady => _instance != null;

  /// The engine, or null when it has not opened yet.
  ///
  /// Callers use this on the hot path (a field losing focus) and must not wait
  /// on SQLite there; [ensureInitialised] is kicked off at app start and again
  /// when WES2 opens, so by the time an athlete can type, this is non-null.
  static Wes2SyncEngine? get engineOrNull => _instance?.engine;

  /// Opens the outbox and starts the engine. Idempotent and concurrency-safe.
  static Future<Wes2SyncServices> ensureInitialised() {
    final Wes2SyncServices? existing = _instance;
    if (existing != null) return Future<Wes2SyncServices>.value(existing);
    final Future<Wes2SyncServices>? inFlight = _initialising;
    if (inFlight != null) return inFlight;
    final Future<Wes2SyncServices> started = _build();
    _initialising = started;
    return started;
  }

  static Future<Wes2SyncServices> _build() async {
    try {
      final Wes2MutationDatabase db = await Wes2MutationDatabase.open();
      final Wes2MutationOutbox outbox = Wes2MutationOutbox(db);
      final Wes2SyncEngine engine = Wes2SyncEngine(
        outbox: outbox,
        repository: FirestoreWes2Repository(),
        currentActorUid: () => FirebaseAuth.instance.currentUser?.uid,
      );
      final Wes2SyncServices services =
          Wes2SyncServices._(outbox: outbox, engine: engine);
      _instance = services;
      _initialising = null;
      // Anything left from a previous launch starts draining now — this is what
      // makes an edit logged offline yesterday reach Firestore today without
      // the athlete reopening the workout.
      await engine.start();
      unawaited(engine.process());
      return services;
    } catch (_) {
      // Let the next caller try again rather than caching the rejection: a
      // support directory that is not ready on a cold start must not disable
      // durable saving for the whole session.
      _initialising = null;
      rethrow;
    }
  }

  /// Runs one pass, ignoring any backoff. Safe to call from app start, resume,
  /// or after a successful load — the engine absorbs overlapping triggers.
  static Future<void> processNow() async {
    final Wes2SyncEngine? engine = _instance?.engine;
    if (engine == null) return;
    try {
      await engine.processNow();
    } catch (e) {
      debugPrint('[WES2SYNC] pass failed: $e');
    }
  }

  /// Returns parked rows to the queue and runs a pass. Explicit athlete
  /// action only — blocked rows are never retried in a loop.
  static Future<void> retryBlockedNow() async {
    final Wes2SyncEngine? engine = _instance?.engine;
    if (engine == null) return;
    try {
      await engine.retryBlocked();
    } catch (e) {
      debugPrint('[WES2SYNC] retry failed: $e');
    }
  }

  /// Opens the outbox if needed and then drains it. Used at app start, where
  /// nothing may be awaited on the first-frame path.
  static Future<void> initialiseAndDrain() async {
    try {
      await ensureInitialised();
      await processNow();
    } catch (e) {
      debugPrint('[WES2SYNC] could not start: $e');
    }
  }

  /// Test seam: installs an explicitly constructed pair.
  @visibleForTesting
  static void debugOverride({
    required Wes2MutationOutbox outbox,
    required Wes2SyncEngine engine,
  }) {
    _instance = Wes2SyncServices._(outbox: outbox, engine: engine);
    _initialising = null;
  }

  /// Test seam: forgets the singleton without closing the database, so one
  /// test's in-memory outbox never leaks into the next.
  @visibleForTesting
  static void debugReset() {
    _instance = null;
    _initialising = null;
  }
}
