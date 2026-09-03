import 'dart:async';

import 'package:flutter/foundation.dart';

/// Outcome of one WES2 "Completed?" / "Mark as not done" attempt. Exposed so
/// production logging and tests can assert which branch ran without
/// reimplementing the logic.
enum Wes2DoneAction {
  /// The focused field's ordinary save became durable, then Done was applied.
  committed,

  /// A toggle for this exercise was already in flight; the repeat tap was
  /// absorbed by the guard.
  skippedAlreadyRunning,

  /// The commit step threw. The guard is released, so the button still works.
  failed,
}

/// Tracks the in-flight LOCAL durability writes for one WES2 screen.
///
/// A "durable write" here is the SQLite outbox insert, never the network. The
/// set exists so a deliberate action — leaving the screen, or marking an
/// exercise done — can wait for what the athlete just typed to be on disk
/// before the field widgets that hold that text are torn down.
///
/// Extracted from `Wes2Screen` unchanged so the Done path and the exit path
/// share ONE barrier: a mutation started by a focus-loss listener is visible to
/// whichever of them is waiting.
class Wes2DurableWriteBarrier {
  final Set<Future<void>> _writes = <Future<void>>{};

  /// Number of writes currently in flight (visible for assertions/testing).
  int get pending => _writes.length;

  /// Registers [write] for the barrier and awaits it.
  ///
  /// Registration is synchronous with the call, which is the property the Done
  /// sequencing depends on: by the time a focus-loss listener returns, the
  /// mutation it started is already in the set that [settle] will wait for.
  Future<void> track(Future<void> write) async {
    _writes.add(write);
    try {
      await write;
    } finally {
      _writes.remove(write);
    }
  }

  /// Waits for every in-flight local write. Never waits on the network.
  ///
  /// Bounded: a storage stall can slow the barrier but can never trap the
  /// athlete, and the queued row survives either way.
  Future<void> settle({Duration timeout = const Duration(seconds: 3)}) async {
    if (_writes.isEmpty) return;
    await Future.wait<void>(List<Future<void>>.from(_writes))
        .timeout(timeout, onTimeout: () => const <void>[]);
  }
}

/// Coordinates the single authoritative WES2 "mark done" sequence.
///
/// ── The defect this exists for ─────────────────────────────────────────────
/// The ordinary save path for an execution value is: type → controller holds
/// the actual → the field loses focus → `onFieldUnfocused` → a durable
/// `Wes2Mutation.fieldPatch`. Done had no relationship with that path, so:
///
///   RIR field focused, athlete types 0, taps "Completed?" immediately
///     → the card's ExpansionTile is re-keyed on `isMarkedDone`
///     → every `Wes2SetRow` state is disposed
///     → `dispose()` removes the focus listeners BEFORE the nodes unfocus
///     → the RIR field patch is never created at all
///     → the Done mutation lands on a row already in `exercises[]`, which is a
///       surgical `isMarkedDone` patch, so the typed RIR is simply gone.
///
/// ── What this does, and what it deliberately does not ──────────────────────
/// It does NOT make Done save anything. Done stays a completion checkmark that
/// carries a boolean; it never reads a hint, never infers a missing value and
/// never repairs a field. All this does is let the EXISTING field-save
/// lifecycle finish first:
///
///   1. `dropFocus` releases the primary focus while the row is still mounted.
///   2. One event-loop turn is yielded. `FocusManager` notifies focus-loss
///      listeners from a MICROTASK (`_markNeedsUpdate` →
///      `scheduleMicrotask(applyFocusChangesIfNeeded)`), so the listener has
///      not run yet when `unfocus()` returns; a turn of the loop is the
///      deterministic point after which it has.
///   3. `awaitDurableWrites` waits for the SQLite insert that listener started.
///      `Wes2DurableWriteBarrier.track` registers synchronously, so the barrier
///      cannot miss a mutation the listener has already begun.
///   4. Only then is Done applied and queued — after the field mutation, in the
///      durable outbox, in that order.
///
/// The network is never waited on, so the checkmark still appears immediately.
///
/// The per-exercise guard absorbs a repeated tap while a toggle is in flight,
/// so a double tap cannot interleave two sequences for the same card.
class Wes2DoneCoordinator {
  final Set<String> _inFlight = <String>{};

  /// True while a toggle for [exerciseId] is running (visible for testing).
  bool isBusy(String exerciseId) => _inFlight.contains(exerciseId);

  /// Runs the ordering contract described on this class for one exercise.
  ///
  /// [commitDone] is the caller's ordinary Done work — toggle the controller,
  /// queue `Wes2Mutation.markDone` — and is invoked only after the barrier has
  /// settled.
  Future<Wes2DoneAction> toggleMarkedDone({
    required String exerciseId,
    required VoidCallback dropFocus,
    required Future<void> Function() commitDone,
    Future<void> Function()? awaitDurableWrites,
  }) async {
    if (!_inFlight.add(exerciseId)) {
      return Wes2DoneAction.skippedAlreadyRunning;
    }
    try {
      // Step 1 — release focus while the field widget is still mounted, so its
      // existing listener runs. A no-op when nothing is focused, which is why
      // Done with no active field generates no field mutation at all.
      dropFocus();

      // Step 2 — yield one event-loop turn so the queued focus-loss microtask
      // has reached the listener before the barrier is read.
      await Future<void>.delayed(Duration.zero);

      // Step 3 — LOCAL durability only. Failure here must not block the
      // checkmark; the row is already queued or was never created.
      if (awaitDurableWrites != null) {
        try {
          await awaitDurableWrites();
        } catch (e) {
          debugPrint('[WES2] durable-write barrier failed before Done: $e');
        }
      }

      // Step 4 — the field mutation is on disk. Done may go now.
      await commitDone();
      return Wes2DoneAction.committed;
    } catch (e, st) {
      debugPrint('[WES2] Wes2DoneCoordinator toggle failed: $e\n$st');
      return Wes2DoneAction.failed;
    } finally {
      _inFlight.remove(exerciseId);
    }
  }
}
