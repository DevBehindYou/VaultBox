import "dart:async";

import "../../domain/entities/activity.dart";
import "../../domain/repositories/activity_repository.dart";
import "../../domain/repositories/clock.dart";
import "../../domain/repositories/id_generator.dart";
import "../files/storage_gate.dart";

/// The server's notebook: what happened, who is connected, what is moving.
///
/// The app reads it later (it runs in another engine, so the database is the
/// meeting point). Writing is strictly best-effort and never blocks a request:
/// every write goes through one queue that swallows its own failures, so a full
/// disk or a locked database can cost a line of history but never a download.
///
/// Nothing sensitive is ever recorded: no passwords, no tokens, no file bytes,
/// and file names but not full paths.
final class ActivityLog {
  ActivityLog({
    required ActivityRepository repository,
    required Clock clock,
    required IdGenerator ids,
    this.progressEvery = const Duration(seconds: 1),
    this.clientEvery = const Duration(seconds: 30),
    this.maxTrackedClients = 500,
  }) : _repository = repository,
       _clock = clock,
       _ids = ids;

  /// Records nothing. For tests and callers that don't care about history.
  ActivityLog.none()
    : _repository = null,
      _clock = null,
      _ids = null,
      progressEvery = Duration.zero,
      clientEvery = Duration.zero,
      maxTrackedClients = 0;

  final ActivityRepository? _repository;
  final Clock? _clock;
  final IdGenerator? _ids;

  /// At most one progress write per transfer per this long.
  final Duration progressEvery;

  /// At most one "still here" write per client per this long.
  final Duration clientEvery;
  final int maxTrackedClients;

  final Map<String, DateTime> _lastSeen = <String, DateTime>{};
  final Map<String, DateTime> _lastEvent = <String, DateTime>{};
  Future<void> _tail = Future<void>.value();

  bool get isRecording => _repository != null;

  /// Completes when everything queued so far has been written (or has failed).
  Future<void> flush() => _tail;

  void _enqueue(Future<void> Function(ActivityRepository repository) job) {
    final ActivityRepository? repository = _repository;
    if (repository == null) return;
    _tail = _tail.then((_) => job(repository)).catchError((Object _) {});
  }

  // ---------------------------------------------------------------- events

  /// Notes something that happened. Give [throttleKey] for things an attacker
  /// could repeat thousands of times (refused sign-ins): only one event per key
  /// per [throttleFor] is kept.
  void event(
    ActivityKind kind,
    String message, {
    ActivitySeverity severity = ActivitySeverity.info,
    String? actor,
    String? address,
    String? throttleKey,
    Duration throttleFor = const Duration(minutes: 1),
  }) {
    final Clock? clock = _clock;
    final IdGenerator? ids = _ids;
    if (clock == null || ids == null) return;
    final DateTime now = clock.now();
    if (throttleKey != null) {
      final DateTime? last = _lastEvent[throttleKey];
      if (last != null && now.difference(last) < throttleFor) return;
      if (_lastEvent.length >= maxTrackedClients) _lastEvent.clear();
      _lastEvent[throttleKey] = now;
    }
    final ActivityEvent event = ActivityEvent(
      id: ids.newId(),
      at: now,
      kind: kind,
      message: message,
      severity: severity,
      actor: actor,
      address: address,
    );
    _enqueue((ActivityRepository repository) => repository.addEvent(event));
  }

  // --------------------------------------------------------------- clients

  /// [actor] was active from [address]. Cheap to call on every request: only
  /// one write per [clientEvery] per client gets through.
  void seen({required String actor, required String address, required AccessVia via}) {
    final Clock? clock = _clock;
    if (clock == null) return;
    final DateTime now = clock.now();
    final String key = "$actor|$address";
    final DateTime? last = _lastSeen[key];
    if (last != null && now.difference(last) < clientEvery) return;
    if (_lastSeen.length >= maxTrackedClients) _lastSeen.clear();
    _lastSeen[key] = now;

    final ClientRecord client = ClientRecord(actor: actor, address: address, via: via, firstSeenAt: now, lastSeenAt: now);
    _enqueue((ActivityRepository repository) => repository.touchClient(client));
  }

  // ------------------------------------------------------------- transfers

  /// Starts a record for one file moving. The returned [TransferMeter] counts
  /// the bytes and settles the record; [totalBytes] is the size it will reach,
  /// when known.
  TransferMeter transfer({
    required TransferDirection direction,
    required AccessVia via,
    required String actor,
    required String name,
    int? totalBytes,
  }) {
    final Clock? clock = _clock;
    final IdGenerator? ids = _ids;
    if (clock == null || ids == null) return TransferMeter._none();

    final DateTime now = clock.now();
    final TransferRecord record = TransferRecord(
      id: ids.newId(),
      direction: direction,
      via: via,
      actor: actor,
      name: name,
      startedAt: now,
      updatedAt: now,
      totalBytes: totalBytes != null && totalBytes >= 0 ? totalBytes : null,
    );
    _enqueue((ActivityRepository repository) => repository.beginTransfer(record));
    return TransferMeter._(this, record.id, clock);
  }

  // ----------------------------------------------------------- housekeeping

  /// Run when the server starts: transfers left "running" by a previous server
  /// are over, old history is dropped, and the start is noted.
  void serverStarted({Duration keep = const Duration(days: 30)}) {
    final Clock? clock = _clock;
    if (clock == null) return;
    final DateTime now = clock.now();
    _enqueue((ActivityRepository repository) async {
      await repository.interruptRunningTransfers(now);
      await repository.prune(before: now.subtract(keep));
    });
    event(ActivityKind.serverStarted, "The server started.");
  }
}

/// Counts the bytes of one transfer and settles its record exactly once.
final class TransferMeter {
  TransferMeter._(this._log, this._id, this._clock);

  /// A meter that records nothing.
  TransferMeter._none() : _log = null, _id = null, _clock = null;

  final ActivityLog? _log;
  final String? _id;
  final Clock? _clock;

  int _bytes = 0;
  bool _finished = false;
  DateTime? _lastWrite;

  int get bytes => _bytes;
  bool get isFinished => _finished;

  void _count(int length) {
    _bytes += length;
    final ActivityLog? log = _log;
    final String? id = _id;
    final Clock? clock = _clock;
    if (log == null || id == null || clock == null || _finished) return;
    final DateTime now = clock.now();
    final DateTime? last = _lastWrite;
    if (last != null && now.difference(last) < log.progressEvery) return;
    _lastWrite = now;
    final int bytes = _bytes;
    log._enqueue((ActivityRepository repository) => repository.updateTransferProgress(id, bytes: bytes, at: now));
  }

  /// Settles the record. Only the first call counts.
  void finish(TransferState state) {
    if (_finished) return;
    _finished = true;
    final ActivityLog? log = _log;
    final String? id = _id;
    final Clock? clock = _clock;
    if (log == null || id == null || clock == null) return;
    final DateTime now = clock.now();
    final int bytes = _bytes;
    log._enqueue((ActivityRepository repository) => repository.finishTransfer(id, state: state, bytes: bytes, at: now));
  }

  /// [source] as it flows to a client. The transfer is completed when the
  /// stream ends, failed if it errors, and interrupted if the client stops
  /// listening before then (it went away).
  Stream<List<int>> watchDownload(Stream<List<int>> source) {
    StreamSubscription<List<int>>? subscription;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          (List<int> chunk) {
            _count(chunk.length);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace trace) {
            finish(TransferState.failed);
            controller.addError(error, trace);
          },
          onDone: () {
            finish(TransferState.completed);
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        finish(TransferState.interrupted);
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Runs [receive] over [source], counting what flows through, and settles the
  /// record from how it ends: completed if [receive] returns, otherwise the
  /// state [stateFor] gives for the error (which is rethrown).
  Future<T> upload<T>(
    Stream<List<int>> source,
    Future<T> Function(Stream<List<int>> counted) receive, {
    TransferState Function(Object error) stateFor = stateForError,
  }) async {
    final Stream<List<int>> counted = source.map((List<int> chunk) {
      _count(chunk.length);
      return chunk;
    });
    try {
      final T result = await receive(counted);
      finish(TransferState.completed);
      return result;
    } on Object catch (error) {
      finish(stateFor(error));
      rethrow;
    }
  }
}

/// How a failure should read in the transfer list: a client that went away is
/// "interrupted"; anything else is "failed".
TransferState stateForError(Object error) {
  if (error is StorageFault && error.kind == FaultKind.interrupted) return TransferState.interrupted;
  return TransferState.failed;
}
