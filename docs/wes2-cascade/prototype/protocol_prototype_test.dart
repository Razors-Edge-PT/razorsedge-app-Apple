// ISOLATED PROTOCOL PROTOTYPE — NOT production code and NOT a production test.
//
// A pure-Dart specification model of the CORRECTED v6.1 rules (review points
// R1–R8). It exists to demonstrate that the corrected transitions actually
// resolve the reviewer's counterexamples before any production code is written.
// It imports nothing from lib/ and proves nothing about the real app.
//
// Production regressions for every case below are named in PLAN.md §15.
import 'package:flutter_test/flutter_test.dart';

// ── Document model ──────────────────────────────────────────────────────────

class SetM {
  SetM({this.id, this.w});
  final String? id;
  final double? w;
  SetM copy({String? id, double? w}) => SetM(id: id ?? this.id, w: w ?? this.w);
  @override
  String toString() => '${id ?? "-"}:${w ?? "-"}';
}

class RowM {
  RowM(this.ex, this.sets);
  final String ex;
  List<SetM> sets;
  String get hash => sets.map((s) => s.toString()).join(',');
  RowM copy() => RowM(ex, sets.map((s) => s.copy()).toList());
}

class LogEntry {
  LogEntry(this.rev, this.stream, this.seq, this.ex, this.kind,
      {this.pos, this.countBefore});
  final int rev, seq;
  final String stream, ex, kind; // kind: field | removeSet | insertSet | rowReplace
  final int? pos, countBefore;
}

class Applied {
  Applied(this.era, this.seq);
  final String era;
  int seq;
}

class Receipts {
  Receipts(this.epoch);
  final String epoch;
  int rev = 0;
  int floor = 0;
  final Map<String, Applied> applied = {};
  final Map<String, String> rowHash = {};
  final Map<String, int> breaks = {};
  final List<LogEntry> log = [];
}

class Doc {
  bool exists = false;
  List<RowM> rows = [];
  Receipts? r;
  RowM? row(String ex) {
    for (final x in rows) {
      if (x.ex == ex) return x;
    }
    return null;
  }

  Doc clone() {
    final d = Doc()
      ..exists = exists
      ..rows = rows.map((x) => x.copy()).toList();
    d.r = r;
    return d;
  }
}

// ── Operations ──────────────────────────────────────────────────────────────

class Op {
  Op({
    required this.stream,
    required this.era,
    required this.seq,
    required this.kind,
    required this.ex,
    this.pos,
    this.setId,
    this.value,
    this.preRowHash,
    this.frameRev = 0,
    this.frameEpoch,
    this.bootstrapId,
    List<int>? frameOps,
    this.removed,
    this.snapshot,
    this.createsRow = false,
  }) : frameOps = frameOps ?? <int>[];

  final String stream, era, kind, ex;
  final int seq;
  int? pos;
  String? setId, preRowHash, frameEpoch, bootstrapId;
  double? value;
  int frameRev;
  List<int> frameOps;
  SetM? removed, snapshot;
  bool createsRow;

  /// Durable evidence that a remote attempt was started for THIS op version.
  /// Set inside the claim transaction, before the network call; never cleared.
  bool everAttempted = false;

  bool get destructive =>
      kind == 'removeSet' || kind == 'deleteExercise' || kind == 'deleteAll';
  bool get idempotentByValue => kind == 'field' || kind == 'setId';
}

class Outcome {
  Outcome.applied(this.doc)
      : kind = 'applied',
        reason = null;
  Outcome.already(this.doc)
      : kind = 'alreadyApplied',
        reason = null;
  Outcome.conflict(this.reason, this.doc) : kind = 'conflict';
  final String kind;
  final String? reason;
  final Doc doc;
  @override
  String toString() => reason == null ? kind : '$kind($reason)';
}

// ── Target resolution (R4: history before any positional shortcut) ──────────

class Target {
  Target.at(this.index)
      : ok = true,
        reason = null;
  Target.no(this.reason)
      : ok = false,
        index = -1;
  final bool ok;
  final int index;
  final String? reason;
}

Target resolveTarget(Doc doc, Op op) {
  final row = doc.row(op.ex);
  if (row == null) return Target.no('targetMissing');

  // 1. Identity always wins and never consults content.
  if (op.setId != null) {
    final i = row.sets.indexWhere((s) => s.id == op.setId);
    return i == -1 ? Target.no('targetMissing') : Target.at(i);
  }

  final rec = doc.r;
  if (rec == null) {
    // Pre-bootstrap: no protocol history exists for this document at all.
    // Whole-row equality is the ONLY evidence available here (documented
    // residual: an unlogged A→B→A by an old build is indistinguishable).
    return row.hash == op.preRowHash
        ? Target.at(op.pos!)
        : Target.no('rowChangedUnidentifiable');
  }

  // 2. Receipts exist ⇒ history is authoritative. Equality never overrides it.
  if (op.frameRev < rec.floor) return Target.no('historyUnavailable');
  if ((rec.breaks[op.ex] ?? -1) > op.frameRev) return Target.no('historyBroken');
  if ((rec.rowHash[op.ex] ?? '') != row.hash) return Target.no('unloggedWrite');

  final entries = rec.log
      .where((e) => e.ex == op.ex && e.rev > op.frameRev)
      .toList()
    ..sort((a, b) => a.rev.compareTo(b.rev));
  if (entries.any((e) => e.kind == 'rowReplace')) {
    return Target.no('rowReplaced');
  }

  final int n = entries.isNotEmpty && entries.first.countBefore != null
      ? entries.first.countBefore!
      : row.sets.length;
  List<String> serverTokens = [for (int i = 0; i < n; i++) 'T$i'];
  List<String> frameTokens = List<String>.from(serverTokens);

  for (final e in entries) {
    final bool own = e.stream == op.stream && e.seq < op.seq;
    if (e.kind == 'removeSet') {
      if (e.pos! >= serverTokens.length) return Target.no('logInconsistent');
      final tok = serverTokens.removeAt(e.pos!);
      if (own) frameTokens.remove(tok);
    } else if (e.kind == 'insertSet') {
      final tok = 'N${e.rev}';
      serverTokens.insert(e.pos!.clamp(0, serverTokens.length), tok);
      if (own) frameTokens.insert(e.pos!.clamp(0, frameTokens.length), tok);
    }
  }
  if (serverTokens.length != row.sets.length) {
    return Target.no('logInconsistent');
  }
  if (op.pos! >= frameTokens.length) return Target.no('targetRemoved');
  final token = frameTokens[op.pos!];
  final idx = serverTokens.indexOf(token);
  return idx == -1 ? Target.no('targetRemoved') : Target.at(idx);
}

// ── Commit-side resolution (full prerequisites) ─────────────────────────────

Outcome resolveForCommit(Doc doc, Op op) {
  final rec = doc.r;

  // Replay evidence: stream lineage (era) + monotonic seq.
  final ap = rec?.applied[op.stream];
  if (ap != null && ap.era == op.era && ap.seq >= op.seq) {
    return Outcome.already(doc);
  }

  // R3: epoch / bootstrap lifecycle.
  if (op.frameEpoch != null) {
    if (!doc.exists || rec == null || rec.epoch != op.frameEpoch) {
      return Outcome.conflict('documentReset', doc);
    }
  } else {
    final bool noReceipts = !doc.exists || rec == null;
    if (noReceipts && op.everAttempted && (op.createsRow || op.destructive)) {
      // Missing receipts are NOT proof that the earlier attempt never applied.
      return Outcome.conflict('uncertainFirstWrite', doc);
    }
  }

  // Dependencies (commit-side only — see resolveForDisplay for U-2).
  if (op.frameOps.isNotEmpty && (ap == null || ap.seq < op.frameOps.reduce((a, b) => a > b ? a : b))) {
    return Outcome.conflict('dependencyNotApplied', doc);
  }

  final out = doc.clone();
  // Snapshot every row BEFORE mutating, so an unlogged foreign write to the
  // target row itself is detected too (not only to its neighbours).
  final Map<String, String> preHash = {
    for (final x in out.rows) x.ex: x.hash,
  };
  RowM? row = out.row(op.ex);

  if (row == null) {
    if (!op.createsRow) return Outcome.conflict('targetMissing', out);
    row = RowM(op.ex, [SetM(w: op.value)]);
    out.rows.add(row);
    out.exists = true;
  } else {
    final t = resolveTarget(out, op);
    if (!t.ok) return Outcome.conflict(t.reason!, out);
    if (op.kind == 'field') {
      row.sets[t.index] = row.sets[t.index].copy(w: op.value);
    } else if (op.kind == 'removeSet') {
      // Destructive ops validate what they remove.
      if (row.sets[t.index].toString() != op.removed.toString()) {
        return Outcome.conflict('removedContentChanged', out);
      }
      row.sets.removeAt(t.index);
    } else if (op.kind == 'restoreSet') {
      row.sets.insert(op.pos!.clamp(0, row.sets.length), op.snapshot!);
    }
  }

  // Receipts update, with non-protocol write detection on EVERY commit path
  // (R4): compare each row against the recorded hash BEFORE refreshing it.
  final Receipts nr = out.r ?? Receipts(op.bootstrapId ?? 'epoch-${op.seq}');
  nr.rev += 1;
  if (out.r != null) {
    // The break is stamped with the NEW rev, so every operation whose frame
    // predates it is fenced; operations authored afterwards are unaffected.
    for (final entry in preHash.entries) {
      final prev = nr.rowHash[entry.key];
      if (prev != null && prev != entry.value) {
        nr.breaks[entry.key] = nr.rev;
      }
    }
  }
  final String kind = op.kind == 'field'
      ? 'field'
      : (op.kind == 'removeSet'
          ? 'removeSet'
          : (op.kind == 'restoreSet' ? 'insertSet' : 'rowReplace'));
  nr.log.add(LogEntry(nr.rev, op.stream, op.seq, op.ex, kind,
      pos: op.pos, countBefore: null));
  for (final x in out.rows) {
    nr.rowHash[x.ex] = x.hash;
  }
  nr.applied[op.stream] = Applied(op.era, op.seq);
  out.r = nr;
  return Outcome.applied(out);
}

/// R7: display eligibility asks ONLY whether this op's own target is safe.
/// Commit prerequisites (checkpoint, epoch, dependencies) are irrelevant here.
bool showsInCascade(Doc base, Op op) => resolveTarget(base, op).ok;

// ── Outbox rules (R2, R6) ───────────────────────────────────────────────────

class Outbox {
  final List<Op> ops = [];
  int nextSeq = 1;

  Op add(Op Function(int seq) build) {
    final op = build(nextSeq++);
    ops.add(op);
    return op;
  }

  /// R6: replacement is authored against the frame of the op it replaces.
  /// R2: only an op with no attempt evidence may be replaced.
  Op? coalesce(Op existing, double newValue) {
    if (existing.everAttempted) return null;
    ops.remove(existing);
    final replacement = Op(
      stream: existing.stream,
      era: existing.era,
      seq: nextSeq++,
      kind: existing.kind,
      ex: existing.ex,
      pos: existing.pos,
      setId: existing.setId,
      value: newValue,
      preRowHash: existing.preRowHash,
      frameRev: existing.frameRev,
      frameEpoch: existing.frameEpoch,
      bootstrapId: existing.bootstrapId,
      frameOps: List<int>.from(existing.frameOps), // NOT the replaced seq
      createsRow: existing.createsRow,
    );
    ops.add(replacement);
    return replacement;
  }

  /// R2: cancellation is only legal with durable evidence of no attempt, and
  /// the test happens in the same transaction that would claim the row.
  bool cancelIfNeverAttempted(Op op) {
    if (op.everAttempted) return false;
    return ops.remove(op);
  }

  Op claim() {
    final op = ops.first;
    op.everAttempted = true; // durable, before the network call
    return op;
  }
}

// ── Structural-undo lifetime (R1) ───────────────────────────────────────────

class UndoRecord {
  UndoRecord(this.id, this.sessionId, this.state, {this.published = false});
  final String id, sessionId;
  String state; // preparing | live | restoring | discarding
  bool published;
  bool holdsReleased = false;
  bool republished = false;
}

/// Recovery separates "currently executing" from "Undo still available".
void recover(List<UndoRecord> records, String session, Set<String> active) {
  for (final r in records) {
    if (active.contains(r.id)) continue; // an operation is mid-flight
    switch (r.state) {
      case 'preparing':
        r.holdsReleased = true;
        r.state = 'rolledBack';
        break;
      case 'live':
        if (r.sessionId == session) {
          // The opportunity belongs to this session and is still offered.
          if (!r.published) {
            r.republished = true; // rebuild the screen from durable state
            r.published = true;
          }
        } else {
          r.holdsReleased = true; // unused opportunity from a dead process
          r.state = 'discarded';
        }
        break;
      case 'restoring':
        r.state = 'done';
        break;
    }
  }
}

// ── Shadow write guard (R8) ─────────────────────────────────────────────────

class Shadow {
  int rev = 0;
  int lastLoadGen = 0;
  int commitCounter = 0;
  String content = '';
}

bool acceptShadowWrite(Shadow s, {required int rev, required int loadGen,
    required int commitCounterAtStart, required String content}) {
  if (s.commitCounter != commitCounterAtStart) return false;
  if (rev < s.rev) return false;
  if (rev == s.rev && loadGen <= s.lastLoadGen) return false;
  s.rev = rev;
  s.lastLoadGen = loadGen;
  s.content = content;
  return true;
}

// ── Migration authorisation (R5) ────────────────────────────────────────────

/// Auto-conversion needs independent PRE-state evidence, never the post-state.
bool mayAutoConvert({required RowM serverRow, required String framePreHash,
    String? setId}) {
  if (setId != null) return serverRow.sets.any((s) => s.id == setId);
  return serverRow.hash == framePreHash;
}

// ── Demonstrations ──────────────────────────────────────────────────────────

Doc seed(List<SetM> sets, {Receipts? r, String ex = 'bench'}) {
  final d = Doc()
    ..exists = true
    ..rows = [RowM(ex, sets)];
  if (r != null) {
    d.r = r;
    r.rowHash[ex] = d.row(ex)!.hash;
  }
  return d;
}

void main() {
  test('R1 a live Undo opportunity survives ordinary maintenance', () {
    final rec = UndoRecord('u1', 'session-A', 'live', published: true);
    recover([rec], 'session-A', <String>{}); // operation finished, not active
    expect(rec.state, 'live');
    expect(rec.holdsReleased, isFalse); // footage still held for app-bar Undo

    final stale = UndoRecord('u2', 'session-OLD', 'live', published: true);
    recover([stale], 'session-A', <String>{});
    expect(stale.state, 'discarded');
    expect(stale.holdsReleased, isTrue);
  });

  test('R1 exception after the durable transition republishes from state', () {
    final rec = UndoRecord('u3', 'session-A', 'live', published: false);
    recover([rec], 'session-A', <String>{});
    expect(rec.republished, isTrue);
    expect(rec.state, 'live');
    expect(rec.holdsReleased, isFalse);
  });

  test('R2 an attempted removal cannot be cancelled locally', () {
    final box = Outbox();
    final removal = box.add((s) => Op(
        stream: 'i|a', era: 'e1', seq: s, kind: 'removeSet', ex: 'bench',
        pos: 1, removed: SetM(w: 60), preRowHash: '-:50.0,-:60.0,-:70.0'));
    box.claim(); // response lost after a successful commit
    expect(box.cancelIfNeverAttempted(removal), isFalse,
        reason: 'pending+backoff is not proof the commit never landed');

    // Server did commit; the queue retries and the checkpoint absorbs it.
    var doc = seed([SetM(w: 50), SetM(w: 70)], r: Receipts('E')
      ..rev = 1
      ..applied['i|a'] = Applied('e1', removal.seq));
    expect(resolveForCommit(doc, removal).kind, 'alreadyApplied');

    // Undo therefore queues a durable restore, which reaches the server.
    final restore = box.add((s) => Op(
        stream: 'i|a', era: 'e1', seq: s, kind: 'restoreSet', ex: 'bench',
        pos: 1, snapshot: SetM(w: 60), frameRev: 1, frameEpoch: 'E'));
    final out = resolveForCommit(doc, restore);
    expect(out.kind, 'applied');
    expect(out.doc.row('bench')!.hash, '-:50.0,-:60.0,-:70.0');
  });

  test('R3 an uncertain first write does not recreate a deleted document', () {
    final op = Op(
        stream: 'i|a', era: 'e1', seq: 1, kind: 'field', ex: 'bench',
        value: 100, createsRow: true, bootstrapId: 'boot-1');
    final fresh = Doc(); // nothing on the server yet
    expect(resolveForCommit(fresh, op).kind, 'applied',
        reason: 'ordinary first creation still works');

    op.everAttempted = true; // the attempt happened; the response was lost
    final deleted = Doc(); // planner reset removed the document afterwards
    final out = resolveForCommit(deleted, op);
    expect(out.kind, 'conflict');
    expect(out.reason, 'uncertainFirstWrite');
  });

  test('R3 a restored outbox rotates its era instead of being swallowed', () {
    // Server already applied seq 5 for this stream; the restored database
    // starts again at nextSeq 1 with the SAME installation id.
    final rec = Receipts('E')
      ..rev = 5
      ..applied['i|a'] = Applied('era-1', 5);
    final doc = seed([SetM(w: 50)], r: rec);

    final stale = Op(stream: 'i|a', era: 'era-1', seq: 1, kind: 'field',
        ex: 'bench', pos: 0, value: 80, frameRev: 5, frameEpoch: 'E',
        preRowHash: '-:50.0');
    expect(resolveForCommit(doc, stale).kind, 'alreadyApplied',
        reason: 'this is exactly the silent-loss hazard');

    // Detection at first contact: applied.seq >= our nextSeq under the same
    // era ⇒ rotate the era before writing anything.
    final rotated = Op(stream: 'i|a', era: 'era-2', seq: 1, kind: 'field',
        ex: 'bench', pos: 0, value: 80, frameRev: 5, frameEpoch: 'E',
        preRowHash: '-:50.0');
    final out = resolveForCommit(doc, rotated);
    expect(out.kind, 'applied');
    expect(out.doc.row('bench')!.sets[0].w, 80);
  });

  test('R4 an identical row does not override known replacement history', () {
    final rec = Receipts('E')..rev = 1..floor = 0;
    final doc = seed([SetM(w: 50), SetM(w: 60)], r: rec);
    // Another protocol client removed B and inserted a different set that now
    // holds the same number, so the row content is back to its old shape.
    rec.log.add(LogEntry(2, 'other', 7, 'bench', 'removeSet',
        pos: 1, countBefore: 2));
    rec.log.add(LogEntry(3, 'other', 8, 'bench', 'insertSet', pos: 1));
    rec.rev = 3;
    rec.rowHash['bench'] = doc.row('bench')!.hash;

    final edit = Op(stream: 'i|a', era: 'e1', seq: 1, kind: 'field',
        ex: 'bench', pos: 1, value: 80, frameRev: 1, frameEpoch: 'E',
        preRowHash: '-:50.0,-:60.0');
    expect(edit.preRowHash, doc.row('bench')!.hash,
        reason: 'the tempting fast path really does match');
    final out = resolveForCommit(doc, edit);
    expect(out.kind, 'conflict');
    expect(out.reason, 'targetRemoved');
  });

  test('R4 an identified write records the unlogged change as a break', () {
    final rec = Receipts('E')..rev = 1;
    final doc = seed([SetM(id: 'sA', w: 50)], r: rec);
    doc.rows.add(RowM('squat', [SetM(w: 100)]));
    rec.rowHash['squat'] = '-:100.0';
    // An old build changes squat without logging anything.
    doc.row('squat')!.sets[0] = SetM(w: 105);

    final byId = Op(stream: 'i|a', era: 'e1', seq: 1, kind: 'field',
        ex: 'bench', setId: 'sA', value: 55, frameRev: 1, frameEpoch: 'E');
    final out = resolveForCommit(doc, byId);
    expect(out.kind, 'applied');
    expect(out.doc.r!.breaks['squat'], isNotNull,
        reason: 'the identified write must not hide the foreign change');

    final idless = Op(stream: 'i|a', era: 'e1', seq: 2, kind: 'field',
        ex: 'squat', pos: 0, value: 110, frameRev: 1, frameEpoch: 'E',
        preRowHash: '-:100.0');
    final out2 = resolveForCommit(out.doc, idless);
    expect(out2.kind, 'conflict');
    expect(out2.reason, 'historyBroken');
  });

  test('R5 migration refuses a target that was replaced', () {
    // Legacy intent: edit B (position 1) to 80; draft says [50,80,70].
    // Server meanwhile: B removed, D=65 inserted at the same position.
    final server = RowM('bench', [SetM(w: 50), SetM(w: 65), SetM(w: 70)]);
    expect(
        mayAutoConvert(
            serverRow: server, framePreHash: '-:50.0,-:60.0,-:70.0'),
        isFalse);
    // The post-state coincidence that fooled the old rule:
    final applied = RowM('bench', [SetM(w: 50), SetM(w: 80), SetM(w: 70)]);
    expect(applied.hash, '-:50.0,-:80.0,-:70.0',
        reason: 'equals the draft, yet the write would have hit D');
  });

  test('R6 coalescing rebuilds the frame of the op it replaces', () {
    final box = Outbox();
    final first = box.add((s) => Op(
        stream: 'i|a', era: 'e1', seq: s, kind: 'field', ex: 'bench', pos: 0,
        value: 50, frameRev: 1, frameEpoch: 'E', preRowHash: '-:40.0'));
    // The 55 is typed against the optimistic frame that contains `first`.
    final second = box.coalesce(first, 55)!;
    expect(second.frameOps, isEmpty,
        reason: 'the replaced op must not remain a dependency');
    expect(second.preRowHash, '-:40.0');

    final rec = Receipts('E')..rev = 1;
    final doc = seed([SetM(w: 40)], r: rec);
    final out = resolveForCommit(doc, second);
    expect(out.kind, 'applied');
    expect(out.doc.row('bench')!.sets[0].w, 55);
  });

  test('R6 an attempted op is appended, never replaced', () {
    final box = Outbox();
    final first = box.add((s) => Op(
        stream: 'i|a', era: 'e1', seq: s, kind: 'field', ex: 'bench', pos: 0,
        value: 50, frameRev: 1, frameEpoch: 'E', preRowHash: '-:40.0'));
    box.claim();
    expect(box.coalesce(first, 55), isNull);
  });

  test('R7 a blocked earlier op does not demote a safely identified entry', () {
    final rec = Receipts('E')..rev = 2;
    final doc = seed([SetM(id: 'sA', w: 50), SetM(id: 'sC', w: 70)], r: rec);

    final blocked = Op(stream: 'i|a', era: 'e1', seq: 1, kind: 'field',
        ex: 'bench', setId: 'sB', value: 80, frameRev: 1, frameEpoch: 'E');
    expect(resolveForCommit(doc, blocked).reason, 'targetMissing');
    expect(showsInCascade(doc, blocked), isFalse);

    final later = Op(stream: 'i|a', era: 'e1', seq: 2, kind: 'field',
        ex: 'bench', setId: 'sC', value: 55, frameRev: 1, frameEpoch: 'E',
        frameOps: [1]);
    expect(resolveForCommit(doc, later).reason, 'dependencyNotApplied',
        reason: 'the server still waits behind the head of the day');
    expect(showsInCascade(doc, later), isTrue,
        reason: 'C=55 stays an ordinary actual and drives hints');
  });

  test('R8 an out-of-order load cannot overwrite a newer shadow', () {
    final s = Shadow();
    // L1 starts first (gen 1) and reads rev 4; L2 starts (gen 2), reads rev 5
    // and finishes first. No local confirmation happens in between.
    expect(
        acceptShadowWrite(s,
            rev: 5, loadGen: 2, commitCounterAtStart: 0, content: 'newer'),
        isTrue);
    expect(
        acceptShadowWrite(s,
            rev: 4, loadGen: 1, commitCounterAtStart: 0, content: 'older'),
        isFalse);
    expect(s.content, 'newer');
    expect(s.rev, 5);
  });
}
